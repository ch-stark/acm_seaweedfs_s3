# SeaweedFS on OpenShift 4.22 + ACM Observability

Date: 2026-10-27

## Overview

This tutorial deploys SeaweedFS as an S3-compatible object store on an OpenShift 4.22 hub cluster, then points ACM Observability at it as the long-term metrics store.

Thanos, the metrics engine inside ACM Observability, keeps its metrics and metadata in object storage. ACM supports the multicluster observability operator on user-provided S3-compatible storage, so SeaweedFS is a valid backend ([ACM Observability docs](https://docs.redhat.com/en/documentation/red_hat_advanced_cluster_management_for_kubernetes/2.15/html-single/observability)). Red Hat only fully tests and supports OpenShift Data Foundation, so treat SeaweedFS as a best-effort option, not a Red Hat-supported storage product.

The flow has two parts:

1. Install SeaweedFS (master, volume, filer and S3 gateway) with its Helm chart and the OpenShift overrides, then create a bucket and an access key.
2. Install ACM, create the `thanos-object-storage` secret that points at the SeaweedFS S3 endpoint, and create the `MultiClusterObservability` resource.

OpenShift 4.22 runs Kubernetes 1.35 ([release notes](https://docs.redhat.com/en/documentation/openshift_container_platform/4.22/html/release_notes/ocp-4-22-release-notes)).

## Prerequisites

You need a running OpenShift 4.22 cluster with cluster-admin rights. ACM 2.16 lists OpenShift 4.22 as a supported hub platform ([ACM 2.16 support matrix](https://access.redhat.com/articles/7136928)). This tutorial installs everything on that one hub cluster.

| Requirement | Detail |
| --- | --- |
| Cluster | OpenShift 4.22, hub cluster, cluster-admin |
| ACM version | 2.16 (released with multicluster engine 2.11) |
| CLI tools | `oc`, `helm` 3, optionally `aws` CLI for bucket tests |
| Storage class | A default block storage class with dynamic provisioning, not local volumes |
| Capacity for Observability | About 2.7 CPU cores and 12 GiB memory of requests (2701 mCPU, 11972 Mi), before SeaweedFS |
| Registry access | Pull access to `registry.redhat.io` and Docker Hub or your mirror for the SeaweedFS image |

Two rules from the ACM docs shape the design:

- Do not use the local storage operator or a local-volume storage class for the Observability persistent volumes. A pod that moves to another node loses access to its data.
- Use a separate bucket for each hub cluster. Two hubs writing to one path corrupt data and halt the Thanos Compactor.

Check your access and default storage class before you start:

```bash
oc whoami
oc get storageclass
helm version
sudo pip install --user --force-reinstall awscli
```

The ACM page cited here is the 2.15 version, the newest Observability page I could open. The enablement steps below match it; check the 2.16 docs for any changes before production use.




## Part 1: Install SeaweedFS on OpenShift 4.22

The SeaweedFS Helm chart ships an OpenShift values file that avoids `hostPath` volumes and root-owned processes, which OpenShift's restricted security policy blocks ([SeaweedFS Kubernetes deployment wiki](https://gitea.mediatoday.ru/viaprog/seaweedfs/wiki/Deployment-to-Kubernetes-and-Minikube)). The chart deploys a master, volume servers and a filer, plus an S3 gateway when enabled.

### 1. Add the Helm repository

```bash
helm repo add seaweedfs https://seaweedfs.github.io/seaweedfs/helm
helm repo update
```

### 2. Write a values file for the S3 gateway

Create `seaweedfs-s3-values.yaml`. It turns on the standalone S3 gateway with authentication and creates the bucket that Thanos will use. Confirm the key names against `helm show values seaweedfs/seaweedfs` for the chart version you install.

```yaml
s3:
  enabled: true
  enableAuth: true
  createBuckets:
    - name: acm-observability
      anonymousRead: false
```

Set storage sizes and the storage class for the master and volume servers in a second values file or in this one. Use a block storage class that your cluster provisions dynamically.

### 3. Install the chart with the OpenShift overrides

Pass the OpenShift values file first, then yours, so your settings win:

```bash
helm install seaweedfs seaweedfs/seaweedfs \
  -n seaweedfs --create-namespace \
  -f https://raw.githubusercontent.com/seaweedfs/seaweedfs/master/k8s/charts/seaweedfs/openshift-values.yaml \
  -f seaweedfs-s3-values.yaml
```

The values file lives on the `master` branch and can change. For a repeatable install, download a copy, review it, and pin your chart version with `--version`.

### 4. Wait for the pods

```bash
oc -n seaweedfs get pods -w
```

You should see `seaweedfs-master-*`, `seaweedfs-volume-*`, `seaweedfs-filer-*` and `seaweedfs-s3-*` pods reach `Running`. If a pod stays in `CreateContainerConfigError` or fails with a permission error, run `oc -n seaweedfs describe pod <name>` and check which security context constraint (SCC) it was admitted under. The OpenShift values file is meant to make the pods fit the restricted SCC.

### 5. Get the S3 credentials

With `s3.enableAuth: true`, the chart stores the S3 identity configuration in a secret named `seaweedfs-s3-secret` ([example from a MinIO migration guide](https://itnext.io/minio-alternative-seaweedfs-41fe42c3f7be)). Read it and note the access key and secret key of the admin identity:

```bash
oc -n seaweedfs get secret seaweedfs-s3-secret -o jsonpath='{.data}' | jq 'map_values(@base64d)'
```

The secret holds a JSON S3 configuration. Use the `accessKey` and `secretKey` of an identity that has the `Admin` or read/write actions. If you prefer your own credentials, create that secret yourself and reference it with `s3.existingConfigSecret`; check the chart README for the exact key name the secret must contain. SeaweedFS serves S3 without authentication when no credentials are configured, so never skip this step.

### 6. Test the S3 endpoint

The S3 service listens on port 8333 and is named after the release, here `seaweedfs-s3` ([FOSSA's SeaweedFS guide](https://docs.fossa.com/docs/seaweedfs-migration) uses the same `<release>-s3:8333` pattern). Port-forward and list the buckets:

```bash
oc -n seaweedfs port-forward svc/seaweedfs-s3 8333:8333 &

export AWS_ACCESS_KEY_ID=<access key>
export AWS_SECRET_ACCESS_KEY=<secret key>

aws s3 --endpoint-url http://localhost:8333 ls
```

The `acm-observability` bucket should appear. If it does not, create it:

```bash
aws s3 --endpoint-url http://localhost:8333 mb s3://acm-observability
```

The in-cluster S3 address for later is `seaweedfs-s3.seaweedfs.svc.cluster.local:8333`. ACM's Thanos pods run in the same cluster, so you do not need an OpenShift route for this tutorial.

## Part 2: Install ACM and enable Observability

ACM enables the multicluster observability operator by default when you install it. You still have to configure it by supplying object storage and creating a `MultiClusterObservability` resource.

### 1. Install the ACM operator

Use the OpenShift console (Operators > OperatorHub > Advanced Cluster Management for Kubernetes) or apply these manifests. The channel name follows the ACM release; confirm it in OperatorHub before applying.

```yaml
apiVersion: v1
kind: Namespace
metadata:
  name: open-cluster-management
---
apiVersion: operators.coreos.com/v1
kind: OperatorGroup
metadata:
  name: acm-operator-group
  namespace: open-cluster-management
spec:
  targetNamespaces:
    - open-cluster-management
---
apiVersion: operators.coreos.com/v1alpha1
kind: Subscription
metadata:
  name: advanced-cluster-management
  namespace: open-cluster-management
spec:
  channel: release-2.16
  installPlanApproval: Automatic
  name: advanced-cluster-management
  source: redhat-operators
  sourceNamespace: openshift-marketplace
```

```bash
oc apply -f acm-subscription.yaml
oc -n open-cluster-management get csv -w
```

When the ClusterServiceVersion shows `Succeeded`, create the hub:

```yaml
apiVersion: operator.open-cluster-management.io/v1
kind: MultiClusterHub
metadata:
  name: multiclusterhub
  namespace: open-cluster-management
spec: {}
```

```bash
oc apply -f multiclusterhub.yaml
oc -n open-cluster-management get multiclusterhub -w
```

Wait for the status to read `Running`. This takes several minutes.

### 2. Create the Observability namespace and pull secret

```bash
oc create namespace open-cluster-management-observability

DOCKER_CONFIG_JSON=`oc extract secret/multiclusterhub-operator-pull-secret -n open-cluster-management --to=-`

oc create secret generic multiclusterhub-operator-pull-secret \
  -n open-cluster-management-observability \
  --from-literal=.dockerconfigjson="$DOCKER_CONFIG_JSON" \
  --type=kubernetes.io/dockerconfigjson
```

If `multiclusterhub-operator-pull-secret` does not exist in `open-cluster-management`, extract `secret/pull-secret` from the `openshift-config` namespace instead. These are the documented steps.

### 3. Create the `thanos-object-storage` secret for SeaweedFS

This secret tells Thanos where the bucket is. For S3-compatible storage the format is `type: s3` with bucket, endpoint, access key and secret key. The endpoint is written without a protocol, and `insecure: true` selects plain HTTP.

```yaml
apiVersion: v1
kind: Secret
metadata:
  name: thanos-object-storage
  namespace: open-cluster-management-observability
type: Opaque
stringData:
  thanos.yaml: |
    type: s3
    config:
      bucket: acm-observability
      endpoint: seaweedfs-s3.seaweedfs.svc.cluster.local:8333
      insecure: true
      access_key: <SEAWEEDFS_ACCESS_KEY>
      secret_key: <SEAWEEDFS_SECRET_KEY>
```

```bash
oc apply -f thanos-object-storage.yaml
```

Traffic stays inside the cluster in this setup, so plain HTTP works. For HTTPS, set `insecure: false` and add a CA through the `tlsSecretName` and `tlsSecretMountPath` fields described in the ACM docs.

### 4. Create the MultiClusterObservability resource

The default resource points at the secret you just created. Add a `storageClass` if you do not want the platform default.

```yaml
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
    # storageClass: <your-block-storage-class>
```

```bash
oc apply -f multiclusterobservability_cr.yaml
```

The operator now deploys Thanos, Grafana, Alertmanager and the Observatorium API in `open-cluster-management-observability`, and it pushes a metrics collector to every managed cluster, including the hub if it manages itself as `local-cluster`.

## Verification

Observability is working when the Thanos pods run, Grafana shows data, and TSDB blocks land in the SeaweedFS bucket.

1. Check that the core workloads are up. The ACM docs list these as the expected set: `observability-thanos-query` (deployment), and the `observability-thanos-compact`, `observability-thanos-receive-default`, `observability-thanos-rule` and `observability-thanos-store-shard-x` stateful sets.

    ```bash
    oc -n open-cluster-management-observability get pods
    oc -n open-cluster-management-observability get pvc
    ```

2. Confirm Thanos can reach the bucket by checking the store pods:

    ```bash
    oc -n open-cluster-management-observability get pods -l app.kubernetes.io/name=thanos-store
    ```

3. Open Grafana from the Grafana link in the ACM console header, on the Overview or Clusters page. Dashboards such as Alert Analysis, Clusters by Alert and Alerts by Cluster appear once Observability is on.

4. Wait for the first block upload, then list the bucket. The Thanos receiver uploads TSDB blocks to object storage roughly every 2 hours, so the bucket stays empty at first.

    ```bash
    aws s3 --endpoint-url http://localhost:8333 ls s3://acm-observability/ --recursive | head
    ```

    Keep the port-forward from Part 1 running, or restart it.

5. Check the Thanos Compactor, which ACM watches with four default alerts: `ACMThanosCompactHalted`, `ACMThanosCompactHighCompactionFailures`, `ACMThanosCompactBucketHighOperationFailures` and `ACMThanosCompactHasNotRun`. In Grafana Explore, query `ALERTS` to see whether any fired.

To keep a managed cluster out of data collection, add the label `observability: disabled` to its `ManagedCluster` resource.

## Troubleshooting and hardening

| Symptom | Likely cause | Fix |
| --- | --- | --- |
| Thanos pods crash-loop with bucket errors | Wrong endpoint, bucket name or keys in `thanos-object-storage` | Decode the secret, fix `thanos.yaml`, then delete the failing pods |
| `AccessDenied` or `SignatureDoesNotMatch` | The S3 identity lacks read/write rights, or keys were copied wrongly | Re-read `seaweedfs-s3-secret` in the `seaweedfs` namespace and compare with the secret in ACM |
| Endpoint rejected | Protocol included in `endpoint` | Write `host:port` only, with no `http://` |
| SeaweedFS pods fail admission on OpenShift | Chart ran without the OpenShift overrides | Reinstall with the `openshift-values.yaml` file, then check the SCC in `oc describe pod` |
| Metrics vanish after a node restart | PVs on local volumes | Move the Observability PVs to a block storage class that follows pods across nodes |
| Compactor halted or compaction errors | Two hubs share a bucket, or the bucket is unreachable | Give each hub its own bucket and check the `ACMThanos*` alerts |

If S3 requests fail only with SeaweedFS, run `oc -n seaweedfs logs deploy/seaweedfs-s3` while the Thanos pods retry; the gateway logs the rejected request.

Before production use:

- Run SeaweedFS with replicated masters and enough volume servers, and set a replication setting in the chart that fits your failure domains. This tutorial's defaults are for a lab.
- Switch the S3 endpoint to HTTPS and pass the CA through `tlsSecretName`, as described in the ACM docs.
- Back up the SeaweedFS volumes. ACM's support covers the Observability operator against S3-compatible storage, but problems rooted in the third-party store go through its own support channel.
- Size the Observability PVs in the `MultiClusterObservability` resource when you first create it. You can grow them later only if your storage class supports volume expansion.
- Tune retention under `spec.advanced.retentionConfig` once you know how many managed clusters send metrics.

## Sources

- [ACM 2.15 Observability documentation](https://docs.redhat.com/en/documentation/red_hat_advanced_cluster_management_for_kubernetes/2.15/html-single/observability): secret formats, MultiClusterObservability resource, verification, capacity, support statement.
- [ACM 2.16 support matrix](https://access.redhat.com/articles/7136928): OpenShift 4.22 hub support.
- [OpenShift Container Platform 4.22 release notes](https://docs.redhat.com/en/documentation/openshift_container_platform/4.22/html/release_notes/ocp-4-22-release-notes): Kubernetes 1.35.
- [SeaweedFS Kubernetes deployment wiki](https://gitea.mediatoday.ru/viaprog/seaweedfs/wiki/Deployment-to-Kubernetes-and-Minikube): Helm install and OpenShift overrides (a mirror of the upstream wiki).
- [FOSSA SeaweedFS guide](https://docs.fossa.com/docs/seaweedfs-migration) and [MinIO alternative: SeaweedFS](https://itnext.io/minio-alternative-seaweedfs-41fe42c3f7be): chart values for S3 auth and buckets, S3 service naming, credentials secret.

I could not open the SeaweedFS `openshift-values.yaml` file itself, so the SeaweedFS chart keys and the ACM 2.16 channel name are the two items to check against `helm show values` and OperatorHub before you run this in production.
