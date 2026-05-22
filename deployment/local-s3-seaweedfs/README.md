# Local S3 with SeaweedFS

**Scenario:** wire Kamiwaza's Skills Library / context object storage to an in-cluster SeaweedFS instance instead of AWS S3 (or another managed S3 endpoint). Reuses the **`ghcr.io/kamiwaza-internal/containers/images/seaweedfs:v4.15`** image already shipped inside the Kamiwaza extensions bundle for the Milvus extension, but stands up a **dedicated** SeaweedFS instance so Skills Library and Milvus do not share storage.

**Tags:** #deployment #storage #s3 #seaweedfs #helm-values

## What you get

- Deployment **`seaweed-s3`** running `weed server -s3` in all-in-one mode (master + volume + filer + S3 gateway) in namespace **`kamiwaza-system`**.
- Service **`seaweed-s3.kamiwaza-system.svc.cluster.local:8333`** speaking the S3 API.
- A pre-created bucket (default **`kz-workroom`**) materialized by a one-shot exec.
- Secret **`core-s3`** in namespace **`kamiwaza`** with the credentials the umbrella chart reads via `core.context.objectStorage.credentialsSecretRef`.
- Values fragment **`core-values-snippet.yaml`** to merge into the Deploy repo's `cluster/values/overrides.yaml`. Sets `endpointUrl` so core's S3 client targets the in-cluster Service.

## When to use this

Pick this scenario when:

- Native Azure Blob is not an option (the umbrella chart does not speak Blob as of 0.13.0).
- You do not have a managed S3-compatible endpoint to point at.
- You can tolerate single-node, single-replica object storage (this is **not** a multi-AZ resilient backend — it's a pragmatic local lane).

Use a managed S3 endpoint (or the **`security/`**-tier object storage scenario) for multi-node or production deployments.

## Why this isn't `helmfile`-driven yet

The release-0.13.0 bundle on disk references a `KAMIWAZA_LOCAL_S3_ENABLED=true` flag in `cluster/values/overrides-seaweedfs.yaml`, but there is **no actual `seaweedfs/seaweedfs` Helm release in the chart graph** — `/opt/kamiwaza/charts/` has no `seaweedfs` subchart and `helmfile.yaml` has no entry that toggles on that flag. The doc is forward-looking and the wiring hasn't shipped. Until it does, deploy SeaweedFS as raw manifests alongside the Kamiwaza chart and point the chart's `endpointUrl` at it. Once the helmfile release lands, this scenario will collapse to "set `KAMIWAZA_LOCAL_S3_ENABLED=true` and put creds in `overrides-seaweedfs.yaml`."

## Prerequisites

- A Kamiwaza install via **[Kamiwaza Deploy](https://github.com/kamiwaza/deploy)** at **`release-0.13.0`** or newer (chart honors `core.context.objectStorage.endpointUrl` — see `charts/core/values.yaml`).
- The Kamiwaza extensions bundle has been loaded (the seaweed image lands in containerd as a side-effect; verify with `sudo podman exec <kind-node> crictl images | grep seaweed`).
- Cluster default StorageClass supports `ReadWriteOnce` PVC binding. On Kind, that's `standard` (rancher.io/local-path) — adjust `storageClassName` in `seaweedfs.yaml` if yours differs.

## Steps

### 1. Generate credentials and apply manifests

```bash
ACCESS_KEY=$(LC_ALL=C tr -dc 'A-Z0-9' </dev/urandom | head -c 20)
SECRET_KEY=$(openssl rand -base64 32 | tr '+/' '-_' | tr -d '=')

# Save somewhere safe — you'll need both values again for the consumer-side
# secret in step 3.
printf '%s\n' "$ACCESS_KEY" | sudo tee /etc/kamiwaza-extras/seaweed-access >/dev/null
printf '%s\n' "$SECRET_KEY" | sudo tee /etc/kamiwaza-extras/seaweed-secret >/dev/null
sudo chmod 600 /etc/kamiwaza-extras/seaweed-*

ACCESS_KEY="$ACCESS_KEY" SECRET_KEY="$SECRET_KEY" \
  envsubst < seaweedfs.yaml | kubectl apply -f -

kubectl -n kamiwaza-system rollout status deploy/seaweed-s3 --timeout=120s
```

### 2. Create the bucket inside SeaweedFS

`weed shell` is bundled in the image; pipe a command in non-interactively.

```bash
kubectl -n kamiwaza-system exec deploy/seaweed-s3 -- sh -c \
  'echo "s3.bucket.create -name kz-workroom" | weed shell -filer=localhost:8888 -master=localhost:9333'

# Confirm
kubectl -n kamiwaza-system exec deploy/seaweed-s3 -- sh -c \
  'echo "s3.bucket.list" | weed shell -filer=localhost:8888 -master=localhost:9333'
```

### 3. Create the consumer-side `core-s3` secret

```bash
ACCESS_KEY=$(sudo cat /etc/kamiwaza-extras/seaweed-access)
SECRET_KEY=$(sudo cat /etc/kamiwaza-extras/seaweed-secret)

ACCESS_KEY="$ACCESS_KEY" SECRET_KEY="$SECRET_KEY" \
  envsubst < core-s3-secret.yaml | kubectl apply -f -
```

### 4. Wire it into `cluster/values/overrides.yaml`

Copy the `core:` block from **`core-values-snippet.yaml`** into your deploy repo's `cluster/values/overrides.yaml` (or replace the existing `core.context.objectStorage` block).

### 5. Apply the new override

You have two paths. Both end with a fresh `core-scheduler` pod and a fresh `core-raycluster-head` pod consuming `CONTEXT_SERVICE_S3_ENDPOINT_URL`.

**Path A — full reinstall (clean, long-running):** re-run `install-prod.sh` with the updated `overrides.yaml`. Takes ~10 min and rolls every component. Recommended if you can afford the downtime, since it keeps Helm state and on-disk overrides consistent.

```bash
sudo -E /opt/kamiwaza/scripts/install-prod.sh \
  --offline \
  --domain "${DOMAIN}" \
  --admin-password "${ADMIN_PASSWORD}" \
  # ...the rest of your usual flags
```

**Path B — patch in place (fast, no re-roll of other components):** patch the consumed ConfigMap and roll the two S3-reading pods. Use this when the cluster is already running and a full reinstall is overkill. **Caveat:** `helm upgrade kamiwaza ...` standalone fails on 0.13.0 because the `network` subchart depends on an upstream Traefik chart (`traefik.github.io/charts` v37.4.0) that the install-prod.sh bundle fetches at build time but isn't reproducible from a vanilla `helm dependency build`. Re-running `install-prod.sh` (Path A) is the only Helm-clean way to apply this. The ConfigMap patch persists between Helm releases as long as you also keep `overrides.yaml` in sync.

```bash
kubectl -n kamiwaza patch configmap core-config --type=merge -p '{
  "data":{
    "CONTEXT_SERVICE_S3_ENDPOINT_URL":"http://seaweed-s3.kamiwaza-system.svc.cluster.local:8333",
    "CONTEXT_SERVICE_S3_DEFAULT_REGION":"us-east-1",
    "CONTEXT_SERVICE_S3_DEFAULT_BUCKET":"kz-workroom"
  }
}'

# core-scheduler reads its env on pod start.
kubectl -n kamiwaza rollout restart deployment/core-scheduler
kubectl -n kamiwaza rollout status   deployment/core-scheduler --timeout=120s

# The Ray Serve replicas (which serve /api/skills/import) inherit env from
# the head pod at worker-spawn time. Restart the head pod so the new env
# propagates to fresh workers.
kubectl -n kamiwaza delete pod -l ray.io/node-type=head
kubectl -n kamiwaza wait --for=condition=ready --timeout=120s pod -l ray.io/node-type=head
```

### 6. Bounce the consumers that depend on object storage

```bash
kubectl -n kamiwaza-extensions rollout restart deploy \
  -l extensions.kamiwaza.io/name=skills-library

# Optional — restart any other extension that talks to workroom storage.
```

## Verification

```bash
# SeaweedFS up
kubectl -n kamiwaza-system get pods,svc,pvc

# core-scheduler sees the new env (look for ENDPOINT_URL)
kubectl -n kamiwaza exec deploy/core-scheduler -c core -- \
  sh -c 'printenv | grep CONTEXT_SERVICE_S3_'

# End-to-end PutObject from inside the scheduler pod
kubectl -n kamiwaza exec deploy/core-scheduler -c core -- python3 -c '
import boto3, os
s3 = boto3.client("s3",
    endpoint_url=os.environ["CONTEXT_SERVICE_S3_ENDPOINT_URL"],
    aws_access_key_id=os.environ["CONTEXT_SERVICE_S3_ACCESS_KEY_ID"],
    aws_secret_access_key=os.environ["CONTEXT_SERVICE_S3_SECRET_ACCESS_KEY"],
    region_name=os.environ["CONTEXT_SERVICE_S3_DEFAULT_REGION"])
b = os.environ["CONTEXT_SERVICE_S3_DEFAULT_BUCKET"]
print("put:",  s3.put_object(Bucket=b, Key="context/raw/healthcheck.txt", Body=b"ok")["ResponseMetadata"]["HTTPStatusCode"])
print("get:",  s3.get_object(Bucket=b, Key="context/raw/healthcheck.txt")["Body"].read())
print("list:", [o["Key"] for o in s3.list_objects_v2(Bucket=b).get("Contents", [])])
'
```

Expected output:

```
put: 200
get: b'ok'
list: ['context/raw/healthcheck.txt']
```

From the UI: open Skills Library, log in. The "Workroom storage is unavailable" gate should clear. If it persists, hard-refresh (Cmd/Ctrl+Shift+R) — `LauncherAuthGuard.tsx` caches the previous probe result in component state until the session reloads.

## Files

| File                       | Purpose                                                                                  |
| -------------------------- | ---------------------------------------------------------------------------------------- |
| `README.md`                | This document.                                                                           |
| `seaweedfs.yaml`           | SeaweedFS Deployment + Service + PVC + admin-credentials Secret (envsubst placeholders). |
| `core-s3-secret.yaml`      | Consumer-side credential mirror in namespace `kamiwaza` (envsubst placeholders).         |
| `core-values-snippet.yaml` | `core.context.objectStorage` block for `cluster/values/overrides.yaml`.                  |

## Tradeoffs

- **Single replica, single node.** SeaweedFS runs as one Deployment with `Recreate` strategy and a single PVC. There is no replication and the data plane goes briefly offline on chart upgrades.
- **20 GiB default.** Bump the PVC `resources.requests.storage` in `seaweedfs.yaml` if you're going to push a lot of context. On Kind/local-path the PV materializes on the node's data disk; pick a size that fits.
- **Manual deploy, not Helm-managed.** Until the umbrella chart adds a `seaweedfs` subchart, this side-deploy lives outside Helm's view of the world. Re-running `install-prod.sh` won't touch it; that's a feature, not a bug. The consumer side (`core-s3` secret, `overrides.yaml`) is Helm-managed and *will* round-trip cleanly.
- **`kubectl patch` vs reinstall.** Path B in step 5 is a fast forward path but creates drift between Helm's recorded state and what's actually running. Either keep `overrides.yaml` in sync so the next `install-prod.sh` reconciles cleanly, or treat Path B as a one-shot.
- **Separate from Milvus.** The Milvus extension brings its own SeaweedFS via the Garden compose runtime; this scenario does not share that instance. Skills Library blast radius stays independent from the vector-DB blast radius.
- **Not Azure Blob.** Native Azure Blob is not supported by the chart as of 0.13.0; this scenario is the supported "BYO S3-compatible endpoint" path on Azure single-VM installs.
