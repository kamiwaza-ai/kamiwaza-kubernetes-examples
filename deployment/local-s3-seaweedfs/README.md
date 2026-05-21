# Local S3 with bundled SeaweedFS

**Scenario:** wire Kamiwaza's Skills Library / context object storage to an in-cluster SeaweedFS instance instead of AWS S3 (or another managed S3 endpoint). Reuses the **`ghcr.io/kamiwaza-internal/containers/images/seaweedfs:v4.15`** image already shipped inside the Kamiwaza extensions bundle for the Milvus extension; deploys a **separate** SeaweedFS instance so the Skills Library and Milvus do not share storage.

**Tags:** #deployment #storage #s3 #seaweedfs #helm-values

## What you get

- Helmfile release **`seaweedfs/seaweedfs`** running `weed server -s3` in all-in-one mode (master + volume + filer + S3 gateway) in namespace **`seaweedfs`**.
- A pre-created bucket (default **`kz-workroom`**) materialized by a post-install Job.
- Secret **`core-s3`** written into namespace **`kamiwaza`** with the credentials the umbrella chart reads via `core.context.objectStorage.credentialsSecretRef`.
- Values fragment **`core-values-snippet.yaml`** to merge into the Deploy repo's **`cluster/values/overrides.yaml`** (points `endpointUrl` at the in-cluster SeaweedFS Service).
- Values fragment **`overrides-seaweedfs-snippet.yaml`** to drop in as **`cluster/values/overrides-seaweedfs.yaml`** (carries the SeaweedFS S3 credentials).

## When to use this

Pick this scenario when:

- Native Azure Blob is not an option (the umbrella chart does not speak Blob as of 0.13.0).
- You do not have a managed S3-compatible endpoint to point at.
- You can tolerate single-node, single-replica object storage (this is **not** a multi-AZ resilient backend — it's a pragmatic local lane).

Use a managed S3 endpoint (or **`security/`**-tier object storage) for multi-node or production deployments.

## Prerequisites

- A Kamiwaza install via **[Kamiwaza Deploy](https://github.com/kamiwaza/deploy)**, version **`release-0.13.0`** or newer (chart honors `core.context.objectStorage.endpointUrl` — see `charts/core/values.yaml`).
- The bundled SeaweedFS chart at **`/opt/kamiwaza/charts/seaweedfs/`** and the helmfile entry that loads it (gated by `KAMIWAZA_LOCAL_S3_ENABLED=true`).
- Kind on Podman (the release path; image side-load uses `podman exec <node> ctr -n k8s.io images import`).
- The Kamiwaza extensions bundle tarball available — typically already extracted under **`/opt/kamiwaza/extensions-bundle/`** per the offline quickstart.

## Steps

### 1. Extract the extensions bundle (if not already done)

The bundle ships the SeaweedFS image. Per the quickstart, this happens once and is shared with the Extension Bundle Install step at the end of that runbook.

```bash
sudo mkdir -p /opt/kamiwaza/extensions-bundle
sudo tar -xzf ~/artifacts/<timestamp>/kamiwaza-extensions-bundle-*.tar.gz \
  -C /opt/kamiwaza/extensions-bundle

EXTENSIONS_BUNDLE_ROOT=$(sudo find /opt/kamiwaza/extensions-bundle \
  -maxdepth 1 -type d -name 'kamiwaza-extensions-bundle-*' | head -n1)
```

### 2. Side-load the SeaweedFS image into the Kind node

```bash
sudo /opt/kamiwaza/scripts/load-local-s3-image.sh \
  --bundle-root "${EXTENSIONS_BUNDLE_ROOT}"
```

The script is idempotent — re-running after the image is already in containerd is a no-op.

### 3. Drop in the SeaweedFS credentials overrides

The chart fails closed if either field is blank.

```bash
sudo install -m 0644 overrides-seaweedfs-snippet.yaml \
  /opt/kamiwaza/cluster/values/overrides-seaweedfs.yaml
sudo "${EDITOR:-vi}" /opt/kamiwaza/cluster/values/overrides-seaweedfs.yaml
```

Replace the placeholder strings with long random values. The same credentials get mirrored into the `kamiwaza/core-s3` secret automatically.

### 4. Merge the consumer-side overrides

Copy the **`core:`** block from **`core-values-snippet.yaml`** into **`cluster/values/overrides.yaml`** (or replace any existing `core.context.objectStorage` block). The key change vs. the AWS-S3 default is the new `endpointUrl` line pointing at the in-cluster Service.

### 5. Enable the helmfile release and install

```bash
export KAMIWAZA_LOCAL_S3_ENABLED=true

# Then run the normal install per the quickstart:
sudo -E /opt/kamiwaza/scripts/install-prod.sh \
  --offline \
  --domain "${DOMAIN}" \
  --admin-password "${ADMIN_PASSWORD}" \
  ...
```

When the flag is on, the helmfile adds the **`seaweedfs/seaweedfs`** release to the dependency graph and makes the **`kamiwaza/kamiwaza`** release `needs:` it — so the bucket and `core-s3` secret exist before core starts.

### 6. (Already-running cluster) Sync just the SeaweedFS release

If Kamiwaza is already installed and you're enabling the local-S3 lane after the fact:

```bash
cd /opt/kamiwaza/cluster
sudo -E KAMIWAZA_LOCAL_S3_ENABLED=true \
  /opt/kamiwaza/prereqs/bin/helmfile -e release \
  --selector name=seaweedfs sync

# Restart core-scheduler so it picks up the freshly created core-s3 secret.
kubectl -n kamiwaza rollout restart deployment/core-scheduler
```

## Verification

```bash
kubectl -n seaweedfs get pods
kubectl -n seaweedfs logs deploy/seaweedfs | tail -20
kubectl -n seaweedfs get jobs seaweedfs-bucket-init
kubectl -n kamiwaza get secret core-s3 -o jsonpath='{.metadata.name}{"\n"}'

# Confirm core is pointed at the in-cluster endpoint:
kubectl -n kamiwaza exec deploy/core-scheduler -- \
  printenv | grep CONTEXT_SERVICE_S3
```

End-to-end check (creates and lists a test object):

```bash
ACCESS_KEY=$(kubectl -n kamiwaza get secret core-s3 -o jsonpath='{.data.access_key_id}' | base64 -d)
SECRET_KEY=$(kubectl -n kamiwaza get secret core-s3 -o jsonpath='{.data.secret_access_key}' | base64 -d)

kubectl -n seaweedfs run --rm -i --tty s3-test --image=amazon/aws-cli --restart=Never -- \
  --endpoint-url http://seaweedfs-s3.seaweedfs.svc.cluster.local:8333 \
  --region us-east-1 \
  s3 ls s3://kz-workroom \
  | tee /dev/stderr
```

Set `AWS_ACCESS_KEY_ID` / `AWS_SECRET_ACCESS_KEY` via `--env` flags as appropriate for your `kubectl run` flavor.

## Files

| File                                  | Purpose                                                                                  |
| ------------------------------------- | ---------------------------------------------------------------------------------------- |
| `README.md`                           | This document.                                                                           |
| `core-values-snippet.yaml`            | Umbrella **`core.context.objectStorage`** overrides for `cluster/values/overrides.yaml`. |
| `overrides-seaweedfs-snippet.yaml`    | SeaweedFS credentials for `cluster/values/overrides-seaweedfs.yaml`.                     |

## Tradeoffs

- **Single replica, single node.** SeaweedFS runs as one Deployment with `Recreate` strategy and a single PVC. There is no replication and the data plane goes briefly offline on chart upgrades.
- **Image source.** Uses the bundled `seaweedfs:v4.15` image from `ghcr.io/kamiwaza-internal/containers/images/`. If you want a different SeaweedFS build, override `image.repository` / `image.tag` in `overrides-seaweedfs.yaml`.
- **Separate from Milvus.** The Milvus extension brings its own SeaweedFS via the Garden compose runtime; this scenario does not share that instance. The Skills Library blast radius stays independent from the vector-DB blast radius.
- **Not Azure Blob.** Native Azure Blob is not supported by the chart as of 0.13.0; this scenario is the supported "BYO S3-compatible endpoint" path on Azure single-VM installs.
