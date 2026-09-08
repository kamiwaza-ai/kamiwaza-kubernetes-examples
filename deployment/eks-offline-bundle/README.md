# Offline bundle → AWS EKS (relocate to ECR)

Deploy a Kamiwaza **offline release bundle** onto an existing **AWS EKS** cluster by
relocating the bundle's images and charts into **Amazon ECR**, then running the
bundle's offline Helmfile against the EKS context.

The offline bundle is built for an **air-gapped VM**: a `helm dt`
([Distribution Tooling for Helm](https://github.com/vmware-labs/distribution-tooling-for-helm))
**wrap** of every chart + image, which the VM installer unwraps into a local
plain-HTTP registry and deploys to a local k0s/kind cluster. EKS managed nodes
can't reach a VM-local registry, so this scenario **relocates the wrap to ECR**
(HTTPS; nodes authenticate via their node IAM role — no imagePullSecret) and points
the offline Helmfile at ECR. Verified against bundle `v0.13.3` (`2026-06-09.tar`).

> Scope: gets the **full `release` stack** up (offline only wires `release`, not
> `lite`). Tested on EKS 1.31, AL2023 managed nodes.

## Quick start

This folder is a self-contained, config-driven package — you fill in **two files**
and run **two `make` targets**:

```
eks-offline-bundle/
├── config.env.example  # template → copy to config.env (git-ignored): account, paths, admin pw
├── overrides.yaml      # platform config: domain + every image registry + tag  (commented)
├── manifests/          # namespaces + embedding-model DaemonSet (applied for you)
└── Makefile            # relocate / deploy / status / destroy / show-tags
```

```bash
cp config.env.example config.env       # then edit: AWS account/region, cluster, bundle paths, admin pw
aws eks update-kubeconfig --name <cluster> --region <region> --kubeconfig ~/.kube/eks.yaml
# edit overrides.yaml — set global.domain; image tags are pre-filled for this bundle
#   (for a different release: `make show-tags` prints the tags to drop in)

make relocate    # one time: push the bundle's images + charts + model image into ECR
make deploy      # stand up / update the platform   (idempotent; re-run any time)
make status      # health    •    make destroy     # tear down
```

**What's config vs. mechanism:**

- **`overrides.yaml`** (a Helm `--values` file) carries the entire **platform** config —
  `global.domain` and every umbrella image's `registry` (`${REGISTRY}`, filled from
  `config.env`) + `tag`. It's commented per component; you edit the domain and, per
  release, the image tags. No env-var image overrides, no editing the bundle's charts.
- **`config.env`** (git-ignored; from `config.env.example`) carries only operational
  facts — AWS account, cluster, bundle paths, admin password. Nothing version-specific
  except `KAMIWAZA_VERSION`.
- The **Makefile** handles the un-config-able bits with helmfile/kubectl: the fixed
  offline flags + `CHART_REF_*`, the 5 operator charts' registry (their offline
  override files — fixed infra), the helm-plain-HTTP→HTTPS shim, and ECR login.

**Generic to version & secrets:** nothing sensitive is committed (`config.env` is
git-ignored); a new release means refreshing image tags in `overrides.yaml`
(`make show-tags`) and `KAMIWAZA_VERSION` in `config.env`.

The sections below explain each mechanic / how to do it by hand.

## What the bundle contains

```
2026-06-09.tar
├── kamiwaza-helm.00.tar        # the wrap: <chart>.wrap (chart + images + Images.lock)
├── kamiwaza-helm.sha256/.asc   # checksum + detached GPG signature
├── kamiwaza-tools-rpm.pub.gpg  # signature pubkey
├── kamiwaza-prod-<sha>.rpm     # deploy code -> /opt/kamiwaza (charts, cluster/, ansible,
│                               #   bundled helm/helmfile/kind + helm-dt plugin)
└── kamiwaza-extensions-bundle-*.tar.gz   # extensions + offline-extension-catalog (optional)
```

## Prerequisites

| Requirement   | Notes                                                                                                                                                                                                                       |
| ------------- | --------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| EKS cluster   | Existing; managed nodes with the **EBS CSI driver** installed (the 0.13.3 PVCs are unqualified, so they need a default StorageClass — **`make deploy` creates a `gp3` default for you**, `manifests/10-storageclass.yaml`). |
| `aws` CLI     | Admin (or ECR `Create/Push` + EKS describe) in the cluster's account/region.                                                                                                                                                |
| Node IAM role | Must allow ECR pull (`AmazonEC2ContainerRegistryReadOnly` — included by the EKS managed node role).                                                                                                                         |
| `docker`      | helm-dt reads `~/.docker/config.json` for the push.                                                                                                                                                                         |
| Bundle        | Downloaded + extracted ([offline-bundle-download](../offline-bundle-download) fetches + verifies it); the prod RPM extracted to a work dir (`$WORK=.../opt/kamiwaza`).                                                      |

```bash
export REGION=us-east-1 ACCOUNT=<acct-id>
export ECR=$ACCOUNT.dkr.ecr.$REGION.amazonaws.com
export WORK=/path/to/extracted/opt/kamiwaza         # rpm2cpio kamiwaza-prod-*.rpm | cpio -idm
export PATH="$WORK/prereqs/bin:$PATH"               # bundled Helm 3 + helmfile (NOT system Helm 4)
helm plugin install "$WORK/prereqs/plugins/helm-dt" # helm dt

# Dedicated kubeconfig so you never deploy to the wrong cluster:
aws eks update-kubeconfig --name <cluster> --region $REGION --kubeconfig ~/.kube/eks.yaml
export KUBECONFIG=~/.kube/eks.yaml
kubectl config current-context   # confirm it is the EKS cluster

# Default StorageClass: `make deploy` applies manifests/10-storageclass.yaml (gp3,
# via the EBS CSI driver) and marks it default — you don't need to create it by hand.
```

## Step 1 — Verify + extract the wrap

```bash
cd <bundle-dir>
gpg --import kamiwaza-tools-rpm.pub.gpg
gpg --verify kamiwaza-helm.asc kamiwaza-helm.sha256        # Good signature
# the wrap may be chunked (kamiwaza-helm.NN.tar); reassemble + checksum:
cat kamiwaza-helm.*.tar > kamiwaza-helm.tar 2>/dev/null || cp kamiwaza-helm.00.tar kamiwaza-helm.tar
sha256sum -c kamiwaza-helm.sha256
mkdir -p wrap && tar -xf kamiwaza-helm.tar -C wrap         # wrap/kamiwaza-helm/*.wrap
```

## Step 2 — Pre-create ECR repositories

ECR requires repos to exist before push. helm-dt relocates **images** to
`$ECR/<last-2-path-segments>` (e.g. `ghcr.io/.../containers/images/cert-manager-controller`
→ `$ECR/images/cert-manager-controller`) and **charts** to `$ECR/<chart-name>`.
Enumerate both from the wraps:

```bash
cd <bundle-dir>
# image repos (last 2 path segments of every Images.lock entry):
for w in wrap/kamiwaza-helm/*.wrap; do
  top=$(tar -tf "$w" | head -1 | cut -d/ -f1)
  tar -xOf "$w" --occurrence=1 "$top/chart/Images.lock" 2>/dev/null \
    | awk '/^[[:space:]]+image:/{print $2}'
done | sed -E 's#:[^:/]+$##' | awk -F/ '{print $(NF-1)"/"$NF}' | sort -u > /tmp/repos.txt
# chart repos (one per wrap, = chart name):
for w in wrap/kamiwaza-helm/*.wrap; do tar -tf "$w" | head -1 | sed -E 's#-[0-9v].*##'; done | sort -u >> /tmp/repos.txt

sort -u /tmp/repos.txt | while read -r r; do
  aws ecr create-repository --repository-name "$r" --region $REGION >/dev/null 2>&1 \
    && echo "created $r" || echo "exists  $r"
done
```

## Step 3 — Relocate images + charts to ECR

```bash
aws ecr get-login-password --region $REGION | docker login --username AWS --password-stdin $ECR
aws ecr get-login-password --region $REGION | helm registry login --username AWS --password-stdin $ECR

cd <bundle-dir>
for w in wrap/kamiwaza-helm/*.wrap; do
  echo "=== $w ==="
  helm dt unwrap "$w" "$ECR" --yes      # HTTPS + authed (no --use-plain-http/--insecure)
  rm -rf /tmp/chart-*                   # helm-dt uncompresses each wrap to /tmp
done
```

The big `kamiwaza.wrap` (~9 GB) dominates. The ECR auth token lasts 12h; re-login and
re-run if a long push fails (helm-dt skips already-pushed layers).

## Step 4 — Point the offline config at ECR

```bash
# Rewrite the offline image overlays (default to host.docker.internal:5001):
grep -rl 'host.docker.internal:5001' "$WORK/cluster/values/" \
  | xargs sed -i "s#host\.docker\.internal:5001#$ECR#g"

# Chart sources -> ECR (offline Helmfile reads CHART_REF_*):
export CHART_REF_CERT_MANAGER=oci://$ECR/cert-manager
export CHART_REF_TRUST_MANAGER=oci://$ECR/trust-manager
export CHART_REF_KUBERAY_OPERATOR=oci://$ECR/kuberay-operator
export CHART_REF_METRICS_SERVER=oci://$ECR/metrics-server
export CHART_REF_EXTENSION_OPERATOR=oci://$ECR/extension-operator
export CHART_REF_KAMIWAZA=oci://$ECR/kamiwaza

# The offline Helmfile forces helmBinary=/tmp/helm-plain-http (plain HTTP, for a local
# registry). Shim it to the bundled Helm 3 so it speaks HTTPS to ECR:
printf '#!/usr/bin/env bash\nexec %s/prereqs/bin/helm "$@"\n' "$WORK" > /tmp/helm-plain-http
chmod +x /tmp/helm-plain-http
```

## Step 5 — Image tags + admin password (from config.env / overrides.yaml)

Kamiwaza-built images track `$KAMIWAZA_VERSION`; third-party tags are pinned in
`config.env` (`KEYCLOAK_TAG`, `POSTGRES_TAG`, …). `overrides.yaml` references those as
`${…}` placeholders and `make deploy` fills them with `envsubst` at sync time, so the
registry + tags bake into the umbrella's values. Tags **must** match what's in ECR
(`make show-tags` prints the bundle's pins).

`ADMIN_PASSWORD` is **not** read by the Helmfile — `make deploy` seeds it as the
`kamiwaza-user-admin` Secret (the same thing the VM installer does):

```bash
pwf=$(mktemp); printf '%s' "$ADMIN_PASSWORD" > "$pwf"
kubectl create secret generic kamiwaza-user-admin -n kamiwaza --from-file="password=$pwf" \
  --dry-run=client -o yaml \
  | kubectl label --local -f - --dry-run=client -o yaml \
      app.kubernetes.io/managed-by=kamiwaza-seed-job \
      app.kubernetes.io/component=user-secret kamiwaza.ai/username=admin \
  | kubectl apply -f -; rm -f "$pwf"
```

Sanity-check the rendered tags before the long sync:

```bash
set -a; source config.env; set +a; export KAMIWAZA_VERSION_SHORT="${KAMIWAZA_VERSION#release-}"
envsubst < overrides.yaml | grep -E '^\s+(registry|repository|tag):'   # all $REGISTRY/... + your pins
```

## Step 6 — Stage the bundled embedding model on every node

This is **offline**: `core-embedding`'s `download-model` init copies the **bundled**
GGUF from `file:///app/models/_bundled/<model>` into `/app/models` (no HuggingFace
download — the offline overlay points it at `file://` on a **hostPath
`/host/kamiwaza/models`**). On a VM the bundle's host-prep fills that path; on EKS it
starts empty, so the init fails (`curl (37) Could not open file`) and `core-scheduler`
times out waiting for embedding. The `make relocate` + `make deploy` flow handles this:

- `make relocate` bakes the bundled model (`$WORK/prereqs/models/*.gguf`) into a
  `model-stager` image **`FROM` the relocated `chainguard-base`** (already in ECR — so
  no Docker Hub / internet pull), and pushes it to ECR.
- `make deploy` applies `manifests/20-model-stager.yaml`, a DaemonSet that copies the
  GGUF onto every node's `/host/kamiwaza/models/_bundled/` (running as root so the
  embedding pod's non-root init can read it).

Equivalent by hand:

```bash
# build the stager FROM a bundle image (in ECR) — nothing online:
B=/tmp/model-stager; mkdir -p "$B"; cp "$WORK"/prereqs/models/*.gguf "$B"/
printf 'FROM %s/images/chainguard-base:%s\nCOPY *.gguf /staged/_bundled/\n' "$ECR" "$KAMIWAZA_VERSION" > "$B/Dockerfile"
aws ecr create-repository --repository-name model-stager --region $REGION >/dev/null 2>&1 || true
docker build -t $ECR/model-stager:latest "$B" && docker push $ECR/model-stager:latest
kubectl apply -f manifests/20-model-stager.yaml   # ${REGISTRY} → $ECR via envsubst
kubectl -n kamiwaza rollout status ds/kamiwaza-model-stager --timeout=120s
```

(If you deploy first and hit the crash-loop, apply this DaemonSet then
`kubectl -n kamiwaza delete pod -l app=core-embedding` to retry.)

## Step 7 — Deploy

```bash
cd "$WORK"
export DEPLOYMENT_MODE=offline                    # selects offline overlays + CHART_REF_*
export KAMIWAZA_K8S_RUNTIME=kind                  # least-bad runtime for an existing remote cluster
export KAMIWAZA_OFFLINE_ALLOW_EMPTY_CATALOG=true  # no extension catalog staged (see gotchas)

for ns in cert-manager kuberay metrics-server kamiwaza-system kamiwaza; do
  kubectl create namespace "$ns" --dry-run=client -o yaml | kubectl apply -f -
done

helmfile -f cluster/helmfile.yaml.gotmpl -e release sync --set "global.domain=${DOMAIN}"
```

Releases: cert-manager + trust-manager (`cert-manager`), kuberay-operator (`kuberay`),
metrics-server (`metrics-server`), extension-operator (`kamiwaza-system`), kamiwaza
umbrella (`kamiwaza`). The umbrella takes 20–40 min (Keycloak cold start).

## Step 8 — Verify + access

```bash
kubectl get pods -A | grep -Ev 'Running|Completed'    # drains to empty (ignore the model-stager DS)
kubectl -n kamiwaza get deploy,statefulset             # all Ready
helm -n kamiwaza status kamiwaza | grep STATUS         # STATUS: deployed
kubectl -n kamiwaza exec deploy/core-scheduler -c core-scheduler -- true 2>/dev/null  # scheduler up
```

The `network` chart exposes Traefik as a `LoadBalancer` on EKS — an AWS ELB is created:

```bash
ELB=$(kubectl -n kamiwaza get svc traefik -o jsonpath='{.status.loadBalancer.ingress[0].hostname}')
echo "https://$ELB  (send Host: kamiwaza.test)"
# point DNS / a hosts entry for kamiwaza.test at the ELB, or:
curl -k --resolve kamiwaza.test:443:$(dig +short "$ELB" | head -1) https://kamiwaza.test/
# the frontend Dashboard also answers directly on its NodePort service (port 3000).
```

## Gotchas (learned the hard way)

- **Embedding model is the _bundled_ GGUF, staged via node hostPath (offline).** The
  offline overlay points `core-embedding`'s `download-model` init at `file://` on a
  hostPath the VM host-prep fills but EKS leaves empty → crash-loop + `core-scheduler`
  "Embedding service not ready". The `model-stager` DaemonSet (Step 6) fills it; its
  image is built `FROM` the relocated `chainguard-base`, so it pulls **nothing** from
  Docker Hub. (Don't be tempted to switch it to the chart's default HuggingFace URL —
  that defeats the point of an offline install.)
- **Wrong cluster.** If you have a local k3s/kind kubeconfig as default, `kubectl` may
  point there. Use a dedicated `KUBECONFIG` and assert the context before deploying.
- **EKS ignores `desired_size`.** The `terraform-aws-modules/eks` node group ignores
  `desired_size`; scale with `aws eks update-nodegroup-config` (or the console). The full
  stack needs more than 2× m5.2xlarge.
- **Offline requires the extension catalog.** The `release` offline Helmfile fails unless
  `cluster/values/offline-extension-catalog.yaml` is staged (from the extensions bundle)
  **or** `KAMIWAZA_OFFLINE_ALLOW_EMPTY_CATALOG=true` (ships with no apps/tools).
- **`helmBinary: /tmp/helm-plain-http`.** Offline hardcodes a plain-HTTP helm wrapper —
  wrong for ECR's HTTPS. Shim it to real helm (Step 4).
- **ECR has no push-time repo creation.** Pre-create every repo (Step 2) or unwrap fails
  with `NAME_UNKNOWN`.
- **Relocation paths.** Images → `$ECR/images/<name>` (last 2 path segments); charts →
  `$ECR/<chart-name>`. Confirm with the `helm dt unwrap` output line per chart.
- **No imagePullSecret needed.** Nodes pull from ECR via the node IAM role.

## Uninstall

Three levels, smallest blast radius first. All are `make` targets (they reuse
`config.env`, so run them from this folder):

| Target             | Removes                                                                                                                                   | Keeps                                       |
| ------------------ | ----------------------------------------------------------------------------------------------------------------------------------------- | ------------------------------------------- |
| `make destroy`     | helm releases + the 6 namespaces → workloads, **PVCs (→ EBS volumes)**, the **Traefik ELB**, the admin secret, the model-stager DaemonSet | cluster, CRDs, gp3 StorageClass, ECR images |
| `make destroy-ecr` | the ~46 relocated **ECR repos** (images + charts + model-stager)                                                                          | everything else                             |
| `make purge`       | `destroy` + `destroy-ecr` + the operators' **CRDs** + the **gp3 StorageClass** we added                                                   | only the empty EKS cluster                  |

```bash
make destroy        # uninstall the platform (most common)
make purge          # full teardown: platform + CRDs + StorageClass + ECR
```

### What each step actually touches

- **`make destroy`** runs `helmfile … destroy` (uninstalls cert-manager, trust-manager,
  kuberay, metrics-server, extension-operator, kamiwaza) then deletes namespaces
  `kamiwaza`, `kamiwaza-extensions`, `kamiwaza-system`, `kuberay`, `metrics-server`,
  `cert-manager`. Deleting the namespaces also:

  - removes the platform **PVCs** — with `reclaimPolicy: Delete` the backing **EBS
    volumes are deleted** too (your platform data is gone — back up first if needed);
  - deletes the `traefik` Service, which **tears down the AWS ELB**;
  - removes the `kamiwaza-user-admin` secret and the `kamiwaza-model-stager` DaemonSet.
    > If a namespace hangs in `Terminating`, a CRD finalizer is usually waiting — run
    > `make purge` (it deletes the CRDs) or remove the stuck finalizer manually.

- **`make destroy-ecr`** enumerates the repos from the bundle's wraps (same list
  `make relocate` created) and `aws ecr delete-repository --force`s each, so you stop
  paying for ECR storage. Safe — it only deletes those specific repos.

- **`make purge`** additionally deletes the CRDs helm leaves behind
  (`*.cert-manager.io`, `bundles.trust.cert-manager.io`, `*.gateway.networking.k8s.io`,
  `*.ray.io`, `kamiwazaextensions.extensions.kamiwaza.io`) and the **gp3** StorageClass
  this guide added (EKS's original `gp2` is left untouched).

### The cluster itself

`make purge` leaves an empty EKS cluster. To remove the cluster, VPC, nodes, etc.,
use the Terraform that created it (out of scope for this folder):

```bash
cd <your-eks-terraform-dir> && terraform destroy   # or: eksctl delete cluster --name <cluster>
```
