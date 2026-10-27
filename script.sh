#!/usr/bin/env bash
# Installs SeaweedFS (S3) on OpenShift and enables ACM Observability on top of it.
# If ACM (MultiClusterHub) is already installed, the ACM install step is skipped.
#
# Requirements: oc (logged in as cluster-admin), helm 3, jq. Optional: aws CLI (bucket check).
# Usage:        ./setup-acm-observability-seaweedfs.sh
# Override any variable below via the environment, e.g.:
#               BUCKET=my-bucket STORAGE_CLASS=gp3-csi ./setup-acm-observability-seaweedfs.sh
set -euo pipefail

# ---------- settings ----------
SW_NS="${SW_NS:-seaweedfs}"
SW_RELEASE="${SW_RELEASE:-seaweedfs}"
SW_CHART_VERSION="${SW_CHART_VERSION:-}"          # empty = latest; pin for repeatable installs
BUCKET="${BUCKET:-acm-observability}"             # one dedicated bucket per hub cluster
STORAGE_CLASS="${STORAGE_CLASS:-}"                # empty = cluster default
S3_ACCESS_KEY="${S3_ACCESS_KEY:-}"                # empty = read from the chart-generated secret
S3_SECRET_KEY="${S3_SECRET_KEY:-}"
ACM_NS="${ACM_NS:-open-cluster-management}"
ACM_CHANNEL="${ACM_CHANNEL:-}"                    # empty = default channel from OperatorHub
OBS_NS="open-cluster-management-observability"
OPENSHIFT_VALUES_URL="https://raw.githubusercontent.com/seaweedfs/seaweedfs/master/k8s/charts/seaweedfs/openshift-values.yaml"
S3_SVC="${SW_RELEASE}-s3"
S3_ENDPOINT="${S3_SVC}.${SW_NS}.svc.cluster.local:8333"
WORKDIR="$(mktemp -d)"
trap 'rm -rf "$WORKDIR"' EXIT

log()  { printf '\n==> %s\n' "$*"; }
die()  { printf 'ERROR: %s\n' "$*" >&2; exit 1; }

# ---------- preflight ----------
log "Preflight checks"
for bin in oc helm jq; do command -v "$bin" >/dev/null || die "$bin not found in PATH"; done
oc whoami >/dev/null 2>&1 || die "not logged in to a cluster (run 'oc login')"
echo "Cluster user: $(oc whoami)"
echo "Server:       $(oc whoami --show-server)"

# ---------- 1. SeaweedFS ----------
log "Installing SeaweedFS in namespace '$SW_NS'"
oc get namespace "$SW_NS" >/dev/null 2>&1 || oc create namespace "$SW_NS"

cat > "$WORKDIR/seaweedfs-s3-values.yaml" <<EOF
s3:
  enabled: true
  enableAuth: true
  createBuckets:
    - name: ${BUCKET}
      anonymousRead: false
EOF

if [ -n "$STORAGE_CLASS" ]; then
  cat >> "$WORKDIR/seaweedfs-s3-values.yaml" <<EOF
master:
  data:
    type: persistentVolumeClaim
    size: 5Gi
    storageClass: ${STORAGE_CLASS}
volume:
  dataDirs:
    - name: data
      type: persistentVolumeClaim
      size: 50Gi
      storageClass: ${STORAGE_CLASS}
      maxVolumes: 0
EOF
fi

curl -fsSL "$OPENSHIFT_VALUES_URL" -o "$WORKDIR/openshift-values.yaml" \
  || die "could not download the SeaweedFS OpenShift values file"

helm repo add seaweedfs https://seaweedfs.github.io/seaweedfs/helm >/dev/null 2>&1 || true
helm repo update >/dev/null

HELM_ARGS=(upgrade --install "$SW_RELEASE" seaweedfs/seaweedfs -n "$SW_NS"
  -f "$WORKDIR/openshift-values.yaml" -f "$WORKDIR/seaweedfs-s3-values.yaml")
[ -n "$SW_CHART_VERSION" ] && HELM_ARGS+=(--version "$SW_CHART_VERSION")
helm "${HELM_ARGS[@]}"

log "Waiting for the SeaweedFS S3 gateway"
oc -n "$SW_NS" rollout status deploy/"$S3_SVC" --timeout=600s \
  || { oc -n "$SW_NS" get pods; die "S3 gateway did not become ready (check SCC / storage class)"; }
for sts in $(oc -n "$SW_NS" get statefulset -o name); do
  oc -n "$SW_NS" rollout status "$sts" --timeout=600s
done

# ---------- 2. S3 credentials ----------
if [ -z "$S3_ACCESS_KEY" ] || [ -z "$S3_SECRET_KEY" ]; then
  log "Reading S3 credentials from secret '${SW_RELEASE}-s3-secret'"
  SECRET_JSON="$(oc -n "$SW_NS" get secret "${SW_RELEASE}-s3-secret" -o json 2>/dev/null)" \
    || die "secret ${SW_RELEASE}-s3-secret not found; set S3_ACCESS_KEY and S3_SECRET_KEY and re-run"
  for key in $(jq -r '.data | keys[]' <<<"$SECRET_JSON"); do
    CONF="$(jq -r --arg k "$key" '.data[$k]' <<<"$SECRET_JSON" | base64 -d 2>/dev/null || true)"
    A="$(jq -r '[.identities[]? | select((.actions // []) | index("Admin"))][0].credentials[0].accessKey // empty' <<<"$CONF" 2>/dev/null || true)"
    S="$(jq -r '[.identities[]? | select((.actions // []) | index("Admin"))][0].credentials[0].secretKey // empty' <<<"$CONF" 2>/dev/null || true)"
    if [ -n "$A" ] && [ -n "$S" ]; then S3_ACCESS_KEY="$A"; S3_SECRET_KEY="$S"; break; fi
  done
  [ -n "$S3_ACCESS_KEY" ] && [ -n "$S3_SECRET_KEY" ] \
    || die "no admin credentials found in the secret; set S3_ACCESS_KEY and S3_SECRET_KEY and re-run"
fi
echo "Using S3 access key: ${S3_ACCESS_KEY}"

# ---------- 3. Bucket check (optional, needs aws CLI) ----------
if command -v aws >/dev/null; then
  log "Checking bucket '$BUCKET' through a temporary port-forward"
  oc -n "$SW_NS" port-forward "svc/${S3_SVC}" 18333:8333 >/dev/null 2>&1 &
  PF_PID=$!
  trap 'kill $PF_PID 2>/dev/null || true; rm -rf "$WORKDIR"' EXIT
  sleep 3
  export AWS_ACCESS_KEY_ID="$S3_ACCESS_KEY" AWS_SECRET_ACCESS_KEY="$S3_SECRET_KEY" AWS_DEFAULT_REGION=us-east-1
  if ! aws s3 --endpoint-url http://localhost:18333 ls "s3://${BUCKET}" >/dev/null 2>&1; then
    echo "Bucket not found, creating it"
    aws s3 --endpoint-url http://localhost:18333 mb "s3://${BUCKET}"
  else
    echo "Bucket exists"
  fi
  kill "$PF_PID" 2>/dev/null || true
else
  echo "aws CLI not found: relying on the chart's createBuckets hook to create '$BUCKET'"
fi

# ---------- 4. ACM (skipped if already installed) ----------
log "Checking for an existing ACM installation"
EXISTING_MCH="$(oc get multiclusterhub -A -o jsonpath='{.items[0].metadata.namespace}' 2>/dev/null || true)"
if [ -n "$EXISTING_MCH" ]; then
  ACM_NS="$EXISTING_MCH"
  echo "ACM already installed (MultiClusterHub in namespace '$ACM_NS'): skipping ACM install"
else
  log "Installing ACM in namespace '$ACM_NS'"
  if [ -z "$ACM_CHANNEL" ]; then
    ACM_CHANNEL="$(oc get packagemanifest advanced-cluster-management -n openshift-marketplace \
      -o jsonpath='{.status.defaultChannel}' 2>/dev/null || true)"
    [ -n "$ACM_CHANNEL" ] || die "could not detect the ACM channel; set ACM_CHANNEL (for example release-2.16)"
  fi
  echo "ACM channel: $ACM_CHANNEL"
  oc apply -f - <<EOF
apiVersion: v1
kind: Namespace
metadata:
  name: ${ACM_NS}
---
apiVersion: operators.coreos.com/v1
kind: OperatorGroup
metadata:
  name: acm-operator-group
  namespace: ${ACM_NS}
spec:
  targetNamespaces:
    - ${ACM_NS}
---
apiVersion: operators.coreos.com/v1alpha1
kind: Subscription
metadata:
  name: advanced-cluster-management
  namespace: ${ACM_NS}
spec:
  channel: ${ACM_CHANNEL}
  installPlanApproval: Automatic
  name: advanced-cluster-management
  source: redhat-operators
  sourceNamespace: openshift-marketplace
EOF
  log "Waiting for the ACM operator CRD"
  for i in $(seq 1 60); do
    oc get crd multiclusterhubs.operator.open-cluster-management.io >/dev/null 2>&1 && break
    sleep 10
  done
  oc get crd multiclusterhubs.operator.open-cluster-management.io >/dev/null 2>&1 \
    || die "ACM operator did not install in time (oc -n $ACM_NS get csv,installplan)"
  oc apply -f - <<EOF
apiVersion: operator.open-cluster-management.io/v1
kind: MultiClusterHub
metadata:
  name: multiclusterhub
  namespace: ${ACM_NS}
spec: {}
EOF
  log "Waiting for MultiClusterHub to reach Running (this takes several minutes)"
  for i in $(seq 1 90); do
    PHASE="$(oc -n "$ACM_NS" get multiclusterhub multiclusterhub -o jsonpath='{.status.phase}' 2>/dev/null || true)"
    echo "  phase: ${PHASE:-pending}"
    [ "$PHASE" = "Running" ] && break
    sleep 20
  done
  [ "${PHASE:-}" = "Running" ] || die "MultiClusterHub did not reach Running"
fi

# ---------- 5. Observability ----------
log "Preparing namespace '$OBS_NS'"
oc get namespace "$OBS_NS" >/dev/null 2>&1 || oc create namespace "$OBS_NS"

if ! oc -n "$OBS_NS" get secret multiclusterhub-operator-pull-secret >/dev/null 2>&1; then
  echo "Creating pull secret"
  if oc -n "$ACM_NS" get secret multiclusterhub-operator-pull-secret >/dev/null 2>&1; then
    DOCKER_CONFIG_JSON="$(oc extract secret/multiclusterhub-operator-pull-secret -n "$ACM_NS" --to=-)"
  else
    DOCKER_CONFIG_JSON="$(oc extract secret/pull-secret -n openshift-config --to=-)"
  fi
  oc create secret generic multiclusterhub-operator-pull-secret -n "$OBS_NS" \
    --from-literal=.dockerconfigjson="$DOCKER_CONFIG_JSON" \
    --type=kubernetes.io/dockerconfigjson
else
  echo "Pull secret already present"
fi

log "Creating secret 'thanos-object-storage' pointing at SeaweedFS"
cat > "$WORKDIR/thanos-object-storage.yaml" <<EOF
apiVersion: v1
kind: Secret
metadata:
  name: thanos-object-storage
  namespace: ${OBS_NS}
type: Opaque
stringData:
  thanos.yaml: |
    type: s3
    config:
      bucket: ${BUCKET}
      endpoint: ${S3_ENDPOINT}
      insecure: true
      access_key: ${S3_ACCESS_KEY}
      secret_key: ${S3_SECRET_KEY}
EOF
oc apply -f "$WORKDIR/thanos-object-storage.yaml"

log "Creating MultiClusterObservability"
SC_LINE=""
[ -n "$STORAGE_CLASS" ] && SC_LINE="    storageClass: ${STORAGE_CLASS}"
cat > "$WORKDIR/mco.yaml" <<EOF
apiVersion: observability.open-cluster-management.io/v1beta2
kind: MultiClusterObservability
metadata:
  name: observability
spec:
  observabilityAddonSpec: {}
  storageConfig:
    metricObjectStorage:
      name: thanos-object-storage
      key: thanos.yaml
${SC_LINE}
EOF
oc apply -f "$WORKDIR/mco.yaml"

log "Waiting for the Observability workloads"
for i in $(seq 1 60); do
  oc -n "$OBS_NS" get deploy observability-thanos-query >/dev/null 2>&1 && break
  sleep 10
done
oc -n "$OBS_NS" rollout status deploy/observability-thanos-query --timeout=900s || true
oc -n "$OBS_NS" get pods

cat <<EOF

Done.
  SeaweedFS S3 endpoint (in cluster): ${S3_ENDPOINT}
  Bucket:                             ${BUCKET}
  Grafana: use the Grafana link in the ACM console header (Overview or Clusters page).
  First TSDB blocks reach the bucket after roughly 2 hours.
EOF
