# Custom TLS trust + BYO ingress cert

**Scenario:** make Kamiwaza platform pods trust a custom / enterprise / corporate PKI
for **outbound** TLS (private Bedrock endpoints, internal HuggingFace mirrors, private
registries, private object stores) **with verification left ON**, and serve the
**inbound** ingress cert from a non-Kamiwaza CA — without `SSL_VERIFY=false`,
without `AUTH_GATEWAY_TLS_INSECURE`, and without rebuilding containers.

It uses **supported Helm values + a config-only ConfigMap-builder script** on the
trust side (no chart edits, no controller), and a manifest path for the ingress side
on 0.13.0. Driver: a private AWS Bedrock endpoint whose certificate is signed by a
corporate CA.

> **Two blockers often travel together for custom Bedrock endpoints.** The
> privately-signed cert (this recipe) is usually paired with a **custom AWS region**
> botocore doesn't know. The region half lives in
> [`bedrock-custom-region/`](bedrock-custom-region/). Apply **both** and the
> `SSL_VERIFY=False` stopgap is unnecessary — TLS verification stays ON.

**Tags:** #security #tls #pki #ca-trust #bedrock #helm-values #ingress

---

## Read this first: 0.13.0 offline reinstall prep

The RHEL9 offline test machine was validated with several live patches, including a
minor global DNS fail-fast patch for non-cluster DNS search suffixes. Before a new
0.13.0 offline install on that machine, reset the environment in this order so the
install and post-install re-patching are repeatable:

1. Confirm the intended IPv6 state before touching Podman. If IPv6 must be disabled,
   do **not** use the kernel-level `ipv6.disable=1` boot arg with Podman/netavark;
   it removes `/proc/sys/net/ipv6/...` and can break Kind container startup. Prefer
   sysctl-level disablement so the IPv6 sysctl tree still exists.
2. Run the production uninstall:

   ```bash
   /opt/kamiwaza/bin/uninstall-prod.sh
   ```

   This removes the `kamiwaza-prod` Kind cluster, including
   `kamiwaza-prod-control-plane`, plus scoped Kamiwaza/Kind containers, images,
   networks, volumes, model storage, and kubeconfig. It keeps the Podman package by
   default.
3. Before and after uninstall, confirm required offline inputs remain available:
   S3/offline bundle artifacts, `/opt/kamiwaza/prereqs`, and any install override
   files such as `/opt/kamiwaza/cluster/values/overrides.yaml`.
4. Reboot the host after uninstall so stale Podman tmpfs/`userdata/shm` mount state is
   fully cleared:

   ```bash
   sudo reboot
   ```

5. Reinstall 0.13.0 offline with the required overrides.
6. Apply the global DNS fail-fast patch at the end of this README, then apply the
   TLS trust / Kaizen follow-on patches needed for the customer scenario.

---

## Read this first: standalone scaling backport for live 0.13.0 prod

This is a **cluster-scaling patch**, not an extensions-only step.

For any live offline RHEL install already running `release/0.13.0`, use this
backport when you need the Kind pod ceiling raised to `1000`. `release/0.13.1`
already carries this change; this section is the standalone live backport path
for `0.13.0`.

**Pick the path that matches your cluster:**

- **Fresh install / can recreate** → apply the config patch below, then recreate.
  Both `maxPods` and the CIDR land together and persist across rebuilds.
- **Already running / can't recreate** → use the in-place patch further down.
  It survives restarts and reboots, but a later cluster recreate resets it — so
  fold the config patch in when you next rebuild.

Patch:

`/opt/kamiwaza/cluster/kind/generated-kamiwaza-prod.yaml`

Make the control-plane entry include:

```yaml
# Top-level Cluster field (sibling of `nodes:`), not under a node.
# Must be wide enough to carve one per-node block of the size implied by
# node-cidr-mask-size below. /16 ÷ /22 = 64 node blocks of 1022 IPs each —
# ample for the single-node prod box.
networking:
  podSubnet: "10.244.0.0/16"
nodes:
- role: control-plane
  kubeadmConfigPatches:
  - |
    kind: InitConfiguration
    nodeRegistration:
      kubeletExtraArgs:
        max-pods: "1000"
  - |
    kind: KubeletConfiguration
    maxPods: 1000
  # COMPANION PATCH — required, not optional. maxPods raises only the kubelet
  # ceiling; each node still gets a /24 pod CIDR (~254 usable IPs) by default,
  # so without this the node caps at ~254 pods regardless of maxPods=1000.
  # Widen the per-node pod CIDR to /22 (1022 usable IPs) so 1000 pods can
  # actually get an IP.
  - |
    kind: ClusterConfiguration
    controllerManager:
      extraArgs:
        # The 0.13.0 release pins kindest/node:v1.31.6, which kind renders as a
        # v1beta3 ClusterConfiguration — there extraArgs is a map[string]string.
        # The v1beta4 list-of-{name,value} form fails to unmarshal against it
        # ("cannot unmarshal array into ... map") and aborts control-plane init.
        node-cidr-mask-size: "22"
```

> **Why both halves are mandatory.** `maxPods` is a kubelet limit; the per-node
> pod CIDR is an IPAM limit. They are independent. On a default Kind cluster the
> control-plane node is handed `podCIDR: 10.244.0.0/24` — confirm yours with
> `kubectl get node -o jsonpath='{.items[0].spec.podCIDR}'`. A /24 is ~254
> usable addresses, so a node with `maxPods: 1000` but a /24 pod CIDR still
> stops scheduling new pods at ~254 (pods stuck `ContainerCreating`, kubelet/CNI
> logs show "failed to allocate for range 0: no IP addresses available"). The
> `node-cidr-mask-size: 22` patch above raises the per-node block to 1022 IPs so
> the kubelet ceiling is the real limit.

Then recreate the cluster so the patched config is actually used:

```bash
/opt/kamiwaza/bin/uninstall-prod.sh

# Expect "gone"
sudo podman inspect kamiwaza-prod-control-plane >/dev/null 2>&1 && echo still-present || echo gone

# Expect no kamiwaza-prod entry
sudo env "PATH=$PATH" KIND_EXPERIMENTAL_PROVIDER=podman \
  CONTAINER_HOST=unix:///run/podman/podman.sock \
  "$(command -v kind)" get clusters

/opt/kamiwaza/bin/install-prod.sh --offline
```

If the first check prints `still-present`, or the second still lists
`kamiwaza-prod`, stop and fully remove the old cluster before reinstalling.

**Already running and can't recreate?** Patch the live cluster in place. Both
halves land in a **single kubelet restart** — they reach the kubelet two
different ways:

- **maxPods** is a kubelet setting → edit the node's kubelet config. The new
  ceiling is picked up on kubelet restart; no node deletion needed.
- **per-node pod CIDR** is immutable on the Node object → set
  `node-cidr-mask-size` on the controller-manager, then delete the node so it
  re-registers under the new `/22`.

```bash
NODE=kamiwaza-prod-control-plane

# (1) kubelet ceiling — set maxPods in the node's kubelet config
sudo podman exec "$NODE" sh -lc "grep -q '^maxPods:' /var/lib/kubelet/config.yaml && sed -i 's/^maxPods:.*/maxPods: 1000/' /var/lib/kubelet/config.yaml || printf 'maxPods: 1000\n' >> /var/lib/kubelet/config.yaml"

# (2) per-node pod CIDR — set node-cidr-mask-size on the controller-manager
sudo podman exec "$NODE" sh -lc "grep -q -- '--node-cidr-mask-size=' /etc/kubernetes/manifests/kube-controller-manager.yaml && sed -i 's/--node-cidr-mask-size=.*/--node-cidr-mask-size=22/' /etc/kubernetes/manifests/kube-controller-manager.yaml || sed -i '/--cluster-cidr=/a\    - --node-cidr-mask-size=22' /etc/kubernetes/manifests/kube-controller-manager.yaml"

# Delete the node so it re-registers under the new /22, then bounce kubelet once
# — the single restart picks up BOTH the new maxPods and the re-registration.
sudo kubectl delete node "$NODE"
sudo podman exec "$NODE" systemctl restart kubelet
sudo kubectl wait --for=condition=Ready node/"$NODE" --timeout=180s
sudo kubectl -n kube-system rollout restart ds/kindnet
sudo kubectl -n kube-system rollout status ds/kindnet --timeout=120s || true
```

> On an already-running 0.13.0 node editing `config.yaml` is sufficient — kind
> sets no `--max-pods` kubelet flag by default, so nothing overrides it. Like
> the CIDR half, this survives restarts/reboots but a cluster **recreate** resets
> it, so fold the config patch above in when you next rebuild.

Verify **both** limits — the kubelet ceiling and the per-node IP block:

```bash
# (1) kubelet ceiling
kubectl get node -o jsonpath='{.items[0].status.allocatable.pods}{"\n"}'
# Expect: 1000

# (2) per-node pod CIDR — must be wider than /24 or you cap at ~254
kubectl get node -o jsonpath='{.items[0].spec.podCIDR}{"\n"}'
# Expect: a /22 (e.g. 10.244.0.0/22), NOT /24
```

If (1) shows `1000` but (2) still shows a `/24`, the `node-cidr-mask-size`
companion patch did not take effect (most often the v1beta4 `{name,value}` list
syntax was used against the v1beta3 ClusterConfiguration that kindest/node:v1.31.6
renders — which fails to unmarshal — or the node was not recreated).

---

## Compatibility / version pin

| Item | Status |
| --- | --- |
| Validated against | **Kamiwaza 0.13.0** |
| Kaizen sandbox trust validated against | **Kaizen controller 1.8.13** (distinct from the platform version) — sandboxes get the bundle via the [extension trust webhook](extensions/extension-trust-webhook/) |
| Outbound CA trust (this folder) | **Config-only on 0.13.0** — no trust-manager controller needed. Build the `kamiwaza-trust-bundle` ConfigMap with [`build-trust-bundle-configmap.sh`](build-trust-bundle-configmap.sh), then `core.trustManager.enabled` + `core.scheduler.extraEnv` mount it. |
| BYO ingress cert | **Manifest path on 0.13.0** — there is no native values knob, but the network subchart already manages a `default` TLSStore + wildcard Certificate, so the BYO manifests collide with Helm-owned resources. Read the [Helm-ownership caveat](ingress/#helm-ownership-on-0130) in `ingress/` before applying. **Not needed on later releases**, which serve a BYO ingress cert through a native values knob. |

> The trust bundle is **additive**: Mozilla public CAs **+** platform `root-ca` **+**
> your corporate CA(s). There is intentionally no "replace / drop public CAs" mode.

### What picks up new trust via this path

| Workload | Outbound trust | Notes |
| --- | --- | --- |
| `core-scheduler` | ✅ | bundle mounted at `/etc/ssl/certs/ca-certificates.crt` |
| Ray head + workers | ✅ | same mount; this is where Bedrock/LiteLLM runs |
| Declared extension pods | ✅ via the extension trust webhook | the [extension trust webhook](extensions/extension-trust-webhook/) injects the bundle mount + CA env into every declared extension pod automatically — see [`extensions/`](extensions/) |
| Kaizen spawned sandboxes | ✅ via the extension trust webhook | Kaizen adds a second boundary — the sandbox's CA file is owned by the sandbox-controller, not Helm — but it is closed by the [extension trust webhook](extensions/extension-trust-webhook/), which injects the same bundle mount + CA env into every spawned sandbox at pod-create (validated live, Kaizen 1.8.13). A live TLS probe from the sandbox to a corporate-CA endpoint is still the only proof the corporate CA (not the agent image's default bundle) is trusted |

> **Hostname caveat for Kaizen / custom endpoints:** this packet adds **CA
> trust**, not hostname rewrites. If a sandbox or extension is configured to
> call an HTTPS **IP literal** while the upstream presents a DNS wildcard cert,
> verification will still fail after the CA is trusted (first `unknown CA`,
> then `IP address mismatch`). See [`extensions/`](extensions/) for the generic
> extension trust pattern and the Kaizen-specific sandbox warning.

### Client-library consumption (with this recipe's env set, bundle at `/etc/ssl/certs/ca-certificates.crt`)

| Library | Honors | Covered by this recipe |
| --- | --- | --- |
| stdlib `ssl` / `aiohttp` | OS store + `SSL_CERT_FILE` | ✅ mount + `SSL_CERT_FILE` |
| `requests` | `REQUESTS_CA_BUNDLE` / `SSL_CERT_FILE` | ✅ chart sets `REQUESTS_CA_BUNDLE` |
| `httpx` ≥ 0.28 | **`SSL_CERT_FILE`** (else falls back to `certifi`) | ✅ `SSL_CERT_FILE` |
| **LiteLLM 1.83** incl. **Bedrock** (httpx-based) | **`SSL_CERT_FILE`** | ✅ `SSL_CERT_FILE` |
| `boto3` / `botocore` (direct, e.g. S3) | **`AWS_CA_BUNDLE`** only | ✅ `AWS_CA_BUNDLE` |

> **`SSL_CERT_FILE` is the key lever for the Bedrock/LiteLLM path** — not `AWS_CA_BUNDLE`.
> In litellm 1.83 the Bedrock call is **httpx-based, not boto3**: `get_ssl_verify()`
> returns `$SSL_CERT_FILE` when verification is on, and httpx 0.28
> (`create_ssl_context`) uses `$SSL_CERT_FILE` as the CA file when set, else `certifi`.
> `AWS_CA_BUNDLE` is set too, but it only covers any *direct* boto3 use (S3, STS).
>
> Because the bundle is **additive** (Mozilla + platform root + your CA), pointing
> `SSL_CERT_FILE` at it keeps public TLS working *and* adds your CA — `SSL_CERT_FILE`
> replaces certifi rather than augmenting it, so a non-additive file would break public TLS.

---

## Prerequisites

- Kamiwaza 0.13.x deployed; namespaces `kamiwaza`, `kamiwaza-system`,
  `kamiwaza-extensions` present.
- `openssl` + `kubectl` (with cluster access) on the operator host — the only deps
  of [`build-trust-bundle-configmap.sh`](build-trust-bundle-configmap.sh). No
  trust-manager controller, no extra cluster components.
- Access to Deploy values layering (`cluster/values/overrides.yaml`).
- Your enterprise **root + intermediate** CA chain as PEM (one file, concatenated is fine).

### Starting state: existing cluster vs fresh install

This recipe works on a cluster that is **already running** and on a **fresh install**.
Both paths must satisfy one ordering rule, then differ only in *when* you run the steps.

> **Ordering rule (both paths):** the `kamiwaza-trust-bundle` ConfigMap (built by
> [`build-trust-bundle-configmap.sh`](build-trust-bundle-configmap.sh)) must exist in
> the `kamiwaza` namespace **before** the `helmfile sync` that sets
> `core.trustManager.enabled: true`. The bundle volume is `optional: true`, so a sync
> run *before* the ConfigMap exists brings the scheduler/Ray pods up with **no CA file
> mounted** — silently. `verify.sh` (in-pod cert count) is the guard. If the mount is
> already enabled and you build/update the ConfigMap afterward, roll the pods (see
> [Recovery](#recovery--rollback-bad-ca)).

**Path 1 — cluster already running (the verified path).**

1. Provide your corporate CA PEM ([Step 1](#1-provide-your-corporate-ca)).
2. Run the build script ([Step 2](#2-build--apply-the-trust-bundle-configmap)). It
   harvests the public baseline from the running scheduler pod, adds the platform
   `root-ca` + your CA, dedupes, and writes the `kamiwaza-trust-bundle` ConfigMap to
   `kamiwaza` / `kamiwaza-system` / `kamiwaza-extensions`.
3. Merge the values snippet ([Step 3](#3-merge-the-values-snippet-into-clustervaluesoverridesyaml)).
4. `helmfile … sync` ([Step 4](#4-sync-and-wait-for-rollout)). The sync changes the
   scheduler/Ray **pod spec** (adds the mount + env), so the rollout it triggers brings
   pods up with the ConfigMap already mounted — no manual restart needed in the normal
   case. If a pod predates the ConfigMap, roll it (see [Recovery](#recovery--rollback-bad-ca)).

**Path 2 — fresh 0.13.0 install.** The build script harvests the public baseline from
a **running** platform pod by default, so on a brand-new cluster the platform must
either be up first, or you must feed the baseline from a file. Two clean orderings:

- **(a) Sync, then enable (simplest).** Run a normal install first
  (`make install` / `helmfile … sync`) to create the namespaces and platform, then
  follow Path 1 exactly: run the build script (it harvests the baseline from the now-
  running scheduler), then enable the mount. This is just "existing cluster" applied to
  a cluster you brought up a minute ago.
- **(b) Offline baseline, enable on first boot.** Pre-create the `kamiwaza` namespace
  (`kubectl create namespace kamiwaza`), run the build script with
  `--baseline-file <offline mozilla/system CA PEM>` so it needs **no running pod**, then
  merge the values snippet and run the first `make install` / `helmfile … sync`. Pods
  come up trusting your CA on first boot — no second sync, no rollout. Use this when you
  want the platform correct from the very first reconcile (e.g. air-gapped or GitOps
  bootstrap).

## What you get

| File | Purpose |
| --- | --- |
| [`build-trust-bundle-configmap.sh`](build-trust-bundle-configmap.sh) | **Config-only ConfigMap builder — the replacement for the trust-manager controller.** Assembles the additive PEM (public/Mozilla baseline + platform `root-ca` + your corporate CA(s), deduped by SHA-256) and `kubectl apply`s ConfigMap `kamiwaza-trust-bundle` (key `ca-certificates.crt`) into each target namespace. Needs only `openssl` + `kubectl`. |
| [`trust-bundle-values-snippet.yaml`](trust-bundle-values-snippet.yaml) | Helm values overlay: mounts the (script-built) `kamiwaza-trust-bundle` ConfigMap on scheduler + Ray and sets `SSL_CERT_FILE` (covers httpx/LiteLLM/Bedrock) + `AWS_CA_BUNDLE` (direct boto3), plus an optional certifi-overlay fallback. Disables the chart's inert Bundle CR (`ca.trustBundle.enabled: false`) since there is no controller to reconcile it. |
| [`org-ca-secret.template.yaml`](org-ca-secret.template.yaml) | Direct-apply `kamiwaza-org-ca` Secret template. |
| [`kustomization.yaml`](kustomization.yaml) | Local-secret-driven generator for the same Secret (keeps PEM out of hand-edited YAML). |
| [`org-ca.pem.example`](org-ca.pem.example) | Placeholder PEM. |
| [`demo-pki/`](demo-pki/) | **FAKE, throwaway** root+intermediate+leaf PKI and ready-to-apply Secret manifests, so the whole cycle (outbound trust **and** BYO ingress) runs with zero generation. Regenerable via `demo-pki/generate.sh`. Never use for anything real. |
| [`verify.sh`](verify.sh) | End-to-end verification (ConfigMap contents, namespace sync, pod env/mount, optional live TLS probe). |
| [`bedrock-custom-region/`](bedrock-custom-region/) | **Companion** — custom Bedrock **region** enablement. Declarative botocore hotfix so boto3 *accepts* a non-default region; pair with this recipe so no `SSL_VERIFY=False` is needed. |
| [`ingress/`](ingress/) | BYO ingress cert — manifest path required on 0.13.0 (not needed on later releases). |
| [`extensions/`](extensions/) | Extension / Kaizen follow-on. The [extension trust webhook](extensions/extension-trust-webhook/) injects the bundle mount + CA env into every declared extension pod **and** spawned sandbox pod automatically; plus Kaizen-specific remediation, the sandbox verification path, and the offline template livepatch. |

---

## Steps — outbound CA trust

### 1. Provide your corporate CA

The build script needs your **root + intermediate** CA chain. Give it a PEM file
(`--ca-file`, repeatable) **or** create the `kamiwaza-org-ca` Secret in `kamiwaza` and
let the script read it (all keys) when no `--ca-file` is passed. A single Secret can
carry root **and** intermediate(s).

> **Just want to see it work?** A committed, **fake** demo PKI lives in
> [`demo-pki/`](demo-pki/), so the whole cycle runs with **one command, no Secret**:
> ```bash
> security/tls-trust/build-trust-bundle-configmap.sh \
>   --ca-file security/tls-trust/demo-pki/ca-chain.pem
> ```
> `demo-pki/ca-chain.pem` is the fake root+intermediate. It is throwaway material —
> **never** use it for anything real. For a real deployment pass your own
> `--ca-file`, or create the `kamiwaza-org-ca` Secret with one of the options below.

```bash
# Option A (recommended): kustomize from a local PEM file (gitignored)
mkdir -p security/tls-trust/local-secrets
cp /path/to/root+intermediate.pem \
   security/tls-trust/local-secrets/org-ca.pem
kubectl apply -k security/tls-trust

# Option B: direct kubectl from a file
kubectl create secret generic kamiwaza-org-ca \
  --from-file=org-ca.pem=/path/to/root+intermediate.pem \
  -n kamiwaza

# Option C: edit + apply the explicit template
kubectl apply -f security/tls-trust/org-ca-secret.template.yaml
```

> If you use the Secret path, it **must** live in the `kamiwaza` namespace. The script
> reads it only when you do **not** pass `--ca-file`.

### 2. Build + apply the trust-bundle ConfigMap

Run the script. It assembles the additive PEM (public baseline + platform `root-ca` +
your CA, deduped by SHA-256 fingerprint) and `kubectl apply`s ConfigMap
`kamiwaza-trust-bundle` (key `ca-certificates.crt`) into `kamiwaza`,
`kamiwaza-system`, and `kamiwaza-extensions`.

```bash
# From a local CA PEM (root + intermediate):
security/tls-trust/build-trust-bundle-configmap.sh \
  --ca-file /path/to/root+intermediate.pem

# ...or rely on the kamiwaza-org-ca Secret created in Step 1 (omit --ca-file):
security/tls-trust/build-trust-bundle-configmap.sh

# Preview the assembled ConfigMap without applying:
security/tls-trust/build-trust-bundle-configmap.sh --ca-file /path/to/ca.pem --dry-run

# Kaizen follow-on: also write the ConfigMap to kamiwaza-sandboxes:
security/tls-trust/build-trust-bundle-configmap.sh --ca-file /path/to/ca.pem --include-sandboxes
```

By default the public baseline is **harvested from the running scheduler pod**
(`deploy/core-scheduler`, container `core`) — its image already ships the Mozilla set,
so this is air-gap-friendly. For a fully offline / deterministic run with no running
pod, pass `--baseline-file <mozilla/system CA PEM>`. The platform `root-ca` comes from
Secret `root-ca` (ns `kamiwaza`, key `ca.crt`) and is included by default.

> The script is **idempotent** — re-running it re-harvests, re-dedupes, and re-applies
> the ConfigMap, which is exactly what you do on CA rotation (then roll the pods; see
> [Recovery](#recovery--rollback-bad-ca)).

### 3. Merge the values snippet into `cluster/values/overrides.yaml`

Copy [`trust-bundle-values-snippet.yaml`](trust-bundle-values-snippet.yaml) into your
highest-priority values file. It sets:

- `ca.trustBundle.enabled: false`  ← no inert Bundle CR (there is no controller to
  reconcile it; the ConfigMap is produced by the build script)
- `core.trustManager.enabled: true`  ← mounts the script-built `kamiwaza-trust-bundle`
  ConfigMap on scheduler + Ray (a legacy misnomer — it only mounts a ConfigMap and
  needs **no** controller)
- `core.scheduler.extraEnv` → **`SSL_CERT_FILE`** (covers stdlib `ssl`, httpx, and the
  LiteLLM/Bedrock path) **+ `AWS_CA_BUNDLE`** (covers any direct boto3 use)

> The chart already sets `REQUESTS_CA_BUNDLE`; this recipe adds `SSL_CERT_FILE` and
> `AWS_CA_BUNDLE`. **`SSL_CERT_FILE` is what makes Bedrock/LiteLLM trust your CA** — it
> is honored by httpx 0.28 and litellm 1.83 (Bedrock is httpx-based). No code changes,
> no certifi edit needed.

> ⚠️ **Known footgun (do not "fix"):** `cluster/values/kamiwaza-base.yaml` sets a
> **top-level** `trustManager:` key that the `core` subchart never reads. The working
> key is **`core.trustManager.enabled`**. (Tracked separately — document, don't patch base.)

### 4. Redeploy so the mount lands, and wait for rollout

`core.trustManager.enabled: true` only takes effect on a redeploy. **Pick the path that
matches your cluster** — both are config-only, and neither needs the internet (the
`kamiwaza-trust-bundle` ConfigMap was already built by the script in Step 2 and does not
depend on this step):

**Dev / repo-driven cluster:**

```bash
helmfile -f cluster/helmfile.yaml.gotmpl -e full sync
kubectl -n kamiwaza rollout status deploy/core-scheduler
kubectl -n kamiwaza rollout status statefulset/core-raycluster-head   # name may vary
```

**Offline / air-gapped prod (`release/0.13.0`):** do **not** run a dev `helmfile sync` —
merge the snippet into the offline values layer (e.g.
`/opt/kamiwaza/cluster/values/overrides.yaml`), then re-run the offline installer, which
redeploys from the local chart/image cache (no internet):

```bash
/opt/kamiwaza/bin/install-prod.sh --offline
kubectl -n kamiwaza rollout status deploy/core-scheduler
kubectl -n kamiwaza rollout status statefulset/core-raycluster-head   # name may vary
```

### 5. (Fallback, rarely needed) certifi overlay

**You usually do not need this.** With `SSL_CERT_FILE` set (Step 2), httpx 0.28 and
litellm 1.83 already trust your CA. The certifi overlay is only a fallback for a client
that pins `certifi.where()` **and** ignores `SSL_CERT_FILE` (not the case for the
scheduler/Ray/Bedrock path on these pinned versions).

If you hit such a client, overlay the trust-bundle ConfigMap onto the venv's
`cacert.pem`. First find the path inside the pod:

```bash
kubectl -n kamiwaza exec deploy/core-scheduler -c core -- python -c "import certifi; print(certifi.where())"
# e.g. /app/.venv/lib/python3.11/site-packages/certifi/cacert.pem
```

Then uncomment the `extraVolumes` / `extraVolumeMounts` block in the snippet and set
`mountPath` + `subPath` to that exact path. Re-sync.

> The mount **replaces** certifi's file with the additive bundle (which already
> includes the Mozilla set), so public TLS keeps working. Note: a `subPath` mount does
> **not** hot-update on CA rotation — restart the pod.

---

## Verification

```bash
security/tls-trust/verify.sh                       # structural checks
security/tls-trust/verify.sh https://bedrock.example.com   # + live TLS probe from a Ray pod
```

Manual equivalents:

```bash
# (a) bundle contains your CA alongside Mozilla + platform root
kubectl -n kamiwaza get configmap kamiwaza-trust-bundle \
  -o jsonpath='{.data.ca-certificates\.crt}' | grep -c "BEGIN CERTIFICATE"

# (b) written to all three namespaces by the build script
for ns in kamiwaza kamiwaza-system kamiwaza-extensions; do
  kubectl -n "$ns" get configmap kamiwaza-trust-bundle >/dev/null && echo "$ns OK"
done

# (c) scheduler + Ray have the mount + env
kubectl -n kamiwaza exec deploy/core-scheduler -c core -- \
  sh -c 'ls -l /etc/ssl/certs/ca-certificates.crt; env | grep -E "AWS_CA_BUNDLE|SSL_CERT_FILE|REQUESTS_CA_BUNDLE"'

# (d) live: prove the LiteLLM/Bedrock path trusts your CA — use httpx (litellm's
#     transport), NOT urllib, so the test exercises the real SSL_CERT_FILE resolution.
#     Run from a Ray pod (where Bedrock runs):
kubectl -n kamiwaza exec <ray-pod> -- python -c "import httpx,os; \
print('SSL_CERT_FILE=',os.environ.get('SSL_CERT_FILE')); \
print('status', httpx.get('https://bedrock.example.com').status_code)"

# (e) confirm litellm itself resolves the bundle (mirrors its get_ssl_verify logic):
kubectl -n kamiwaza exec <ray-pod> -- python -c \
  "from litellm.llms.custom_httpx.http_handler import get_ssl_verify; print('litellm verify ->', get_ssl_verify())"
#   Expect it to print your SSL_CERT_FILE path (not 'True'/certifi).
```

**Pass:** the httpx/Bedrock call completes the TLS handshake with verification ON
(no `AUTH_GATEWAY_TLS_INSECURE`, no `verify=False`), and `get_ssl_verify()` returns the
`SSL_CERT_FILE` path — i.e. LiteLLM is verifying against your additive bundle.

## Extensions / Kaizen follow-on

Once the core / Ray packet above is green, use [`extensions/`](extensions/) for the
remaining 0.13.0 Kaizen slice.

That follow-on does five things:

1. re-runs the build script with `--include-sandboxes` to also write the
   `kamiwaza-trust-bundle` ConfigMap to `kamiwaza-sandboxes`
2. deploys the [extension trust webhook](extensions/extension-trust-webhook/) — a mutating
   admission webhook that injects the bundle mount + CA env into **every** declared
   extension pod **and** spawned sandbox pod automatically, across redeploys, for all
   extensions (apps, tools, MCP servers, Kaizen)
3. **(Kaizen-only)** runs the remediation the webhook does not do — re-assert the secure
   verify-on flags, fix a non-cert-matching internal `KAMIWAZA_API_URL`, and open egress /
   inject a proxy on the declared backend
4. verifies (via a live TLS probe) whether the spawned sandbox actually trusts
   the corporate CA — structural checks alone can pass on the agent image's
   default bundle
5. includes
   [`extensions/kaizen-offline-template-livepatch/`](extensions/kaizen-offline-template-livepatch/)
   for offline / local-catalog `0.13.0` systems that also need future Kaizen
   launches to pick up selected `0.13.1` template fixes

If you expect large Kaizen sandbox fan-out on live offline `0.13.0`, make sure
the standalone max-pods backport at the top of this README is already done.

**Important:** a green backend pod is not enough for Kaizen. The sandbox's CA file
(`/etc/ssl/certs/ca-certificates.crt`, which the Kaizen agent entrypoint already
points `SSL_CERT_FILE`/`REQUESTS_CA_BUNDLE` at) is owned by the sandbox-controller,
not by Helm values. That boundary is closed by the
[extension trust webhook](extensions/extension-trust-webhook/), which injects the same
bundle mount into every spawned sandbox at pod-create (no new image, no trust-manager;
validated live, Kaizen 1.8.13). The webhook mutates new pods only, so resume/start a new
conversation after deploying it. Even then, a live TLS probe from the sandbox to a
corporate-CA endpoint remains the only proof the corporate CA (not the agent image's
default bundle) is actually trusted.

---

## Recovery / rollback (bad CA)

The ConfigMap is rebuilt by the script, so revert is "re-run the script with the
corrected CA, then roll the pods":

```bash
# re-render the ConfigMap with the corrected CA (or drop the bad --ca-file):
security/tls-trust/build-trust-bundle-configmap.sh --ca-file /path/to/good-ca.pem
# ...or, if the bad CA came from the Secret, fix it and re-run with no --ca-file:
kubectl -n kamiwaza apply -f security/tls-trust/org-ca-secret.template.yaml
security/tls-trust/build-trust-bundle-configmap.sh
```

The re-run re-renders the `kamiwaza-trust-bundle` ConfigMap (it dedupes, so it is safe
to run repeatedly). **However**, the bundle is mounted with `subPath`, so kubelet does
**not** refresh the file inside running containers when the ConfigMap changes. To make
the new bundle visible to already-running pods you must roll them:

```bash
kubectl -n kamiwaza rollout restart deploy/core-scheduler
kubectl -n kamiwaza delete pod -l ray.io/cluster=core-raycluster,ray.io/node-type=head
```

This applies any time you rebuild the bundle — the updated ConfigMap lands immediately,
but live pods keep their old `/etc/ssl/certs/ca-certificates.crt` until they restart.

---

## Notes

- For real deployments, bring your own org root/intermediate PEM. The committed
  [`demo-pki/`](demo-pki/) material is **fake and throwaway** — for the live demo only.
- Do **not** commit real CA material — `local-secrets/` is gitignored. The only
  sanctioned committed keys are the fake ones under `demo-pki/`.
- Ingress (BYO) cert is a separate concern — see [`ingress/`](ingress/).
- Code-side follow-ups (retire `AUTH_GATEWAY_TLS_INSECURE`, point the `httpx` client
  factory at the CA path, boto3 `verify=`, per-endpoint CA field) are tracked as
  platform follow-up work.

---

## Global DNS fail-fast patch for offline clusters

Use this CoreDNS workaround when a disconnected cluster spends 6-12 seconds on
non-cluster DNS search suffixes before reaching the real Kubernetes service name.
It makes CoreDNS immediately return NXDOMAIN for those non-cluster suffixes while
leaving the normal cluster DNS path untouched.

This was validated on the RHEL9 0.13.0 offline test host. Before the patch,
lookups such as `traefik.kamiwaza.svc.cluster.local.dns.podman` and the Azure
`*.internal.cloudapp.net` search suffix took about 12 seconds to fail. After the
patch they failed in about 1 ms, and
`traefik.kamiwaza.svc.cluster.local` continued to resolve normally.

Back up the current CoreDNS ConfigMap:

```bash
sudo KUBECONFIG=/root/.kube/config kubectl -n kube-system get configmap coredns -o yaml \
  | sudo tee /root/coredns.before-offline-nxdomain.yaml >/dev/null
```

Edit CoreDNS:

```bash
sudo KUBECONFIG=/root/.kube/config kubectl -n kube-system edit configmap coredns
```

Add the relevant non-cluster suffix blocks before the existing `.:53 { ... }`
block. For the RHEL9 Azure test host, the observed suffixes were `dns.podman`
and `*.internal.cloudapp.net`:

```text
dns.podman:53 {
    errors
    template IN ANY dns.podman {
        rcode NXDOMAIN
    }
    cache 30
}

internal.cloudapp.net:53 {
    errors
    template IN ANY internal.cloudapp.net {
        rcode NXDOMAIN
    }
    cache 30
}
```

Restart CoreDNS:

```bash
sudo KUBECONFIG=/root/.kube/config kubectl -n kube-system rollout restart deploy/coredns
sudo KUBECONFIG=/root/.kube/config kubectl -n kube-system rollout status deploy/coredns --timeout=120s
```

Verify from a pod:

```bash
POD=$(sudo KUBECONFIG=/root/.kube/config kubectl -n kamiwaza-extensions get pod \
  -l extensions.kamiwaza.io/name=Kaizen,extensions.kamiwaza.io/service=backend \
  -o jsonpath='{.items[0].metadata.name}')

sudo KUBECONFIG=/root/.kube/config kubectl -n kamiwaza-extensions exec -i "$POD" -- python - <<'PY'
import socket, time

for name in [
    "traefik.kamiwaza.svc.cluster.local",
    "traefik.kamiwaza.svc.cluster.local.dns.podman",
]:
    start = time.monotonic()
    try:
        socket.getaddrinfo(name, 443)
        print(name, "OK", round(time.monotonic() - start, 3))
    except Exception as exc:
        print(name, type(exc).__name__, round(time.monotonic() - start, 3), exc)
PY
```

Expected result: the real service name resolves quickly, and the non-cluster suffix
returns NXDOMAIN immediately instead of timing out.

On EC2 or another cloud, replace `internal.cloudapp.net` with the non-cluster search
suffix actually present in pod `/etc/resolv.conf` (for example,
`ec2.internal` or `<region>.compute.internal`).

---

## 0.13.0 runtime DNS/API mitigation for Workrooms and Kaizen

Use this only when you need a **runtime/manual 0.13.0 mitigation** and cannot rebuild
patched Workroom Manager, Kaizen, and extension-operator images. This reduces the
observed 6-second DNS fallback path, but it is not the durable source fix for all
existing and future extension-generated URLs.

First, set `ndots:3` for Core and the Ray cluster templates:

```bash
sudo KUBECONFIG=/root/.kube/config kubectl -n kamiwaza patch deploy core-scheduler --type=merge -p '{"spec":{"template":{"spec":{"dnsConfig":{"options":[{"name":"ndots","value":"3"}]}}}}}'

sudo KUBECONFIG=/root/.kube/config kubectl -n kamiwaza patch raycluster core-raycluster --type=json -p='[
  {"op":"add","path":"/spec/headGroupSpec/template/spec/dnsConfig","value":{"options":[{"name":"ndots","value":"3"}]}},
  {"op":"add","path":"/spec/workerGroupSpecs/0/template/spec/dnsConfig","value":{"options":[{"name":"ndots","value":"3"}]}}
]'

sudo KUBECONFIG=/root/.kube/config kubectl -n kamiwaza rollout restart deploy/core-scheduler
sudo KUBECONFIG=/root/.kube/config kubectl -n kamiwaza rollout status deploy/core-scheduler --timeout=180s
sudo KUBECONFIG=/root/.kube/config kubectl -n kamiwaza delete pod -l ray.io/cluster=core-raycluster
sudo KUBECONFIG=/root/.kube/config kubectl -n kamiwaza wait --for=condition=Ready pod -l ray.io/cluster=core-raycluster --timeout=300s
```

If the Ray cluster has more than one worker group, repeat the
`/spec/workerGroupSpecs/<index>/template/spec/dnsConfig` JSON patch for each worker
group index. If it has no worker groups, omit the worker-group patch operation.

Patch Traefik's ForwardAuth target as well. This call is made by Traefik itself, so
it does not use `KAMIWAZA_API_URL` and it is not affected by the Core/Ray `ndots`
patch above.

First, check whether the cluster is using the optional ForwardAuth cache:

```bash
sudo KUBECONFIG=/root/.kube/config kubectl -n kamiwaza get middleware.traefik.io core-forwardauth \
  -o jsonpath='{.spec.forwardAuth.address}{"\n"}'
```

If the address points directly at Ray/Core, patch it to the trailing-dot service
FQDN:

```bash
sudo KUBECONFIG=/root/.kube/config kubectl -n kamiwaza patch middleware.traefik.io core-forwardauth --type=merge -p '{"spec":{"forwardAuth":{"address":"http://core-raycluster-headless.kamiwaza.svc.cluster.local.:7777/api/auth/forward/validate"}}}'
```

If the address points at `core-forwardauth-cache`, patch both Traefik's target and
the cache proxy's upstream Core target:

```bash
sudo KUBECONFIG=/root/.kube/config kubectl -n kamiwaza patch middleware.traefik.io core-forwardauth --type=merge -p '{"spec":{"forwardAuth":{"address":"http://core-forwardauth-cache.kamiwaza.svc.cluster.local.:7777/api/auth/forward/validate"}}}'

sudo KUBECONFIG=/root/.kube/config kubectl -n kamiwaza set env deploy/core-forwardauth-cache \
  FORWARDAUTH_CACHE_UPSTREAM_URL='http://core-raycluster-head-svc.kamiwaza.svc.cluster.local.:7777/api/auth/forward/validate'

sudo KUBECONFIG=/root/.kube/config kubectl -n kamiwaza rollout restart deploy/core-forwardauth-cache
sudo KUBECONFIG=/root/.kube/config kubectl -n kamiwaza rollout status deploy/core-forwardauth-cache --timeout=180s
```

Then point the current extension CRs at the trailing-dot internal Traefik API URL.
Patch the `KamiwazaExtension` resources instead of the generated Deployments; the
extension operator owns those Deployments and will revert a direct
`kubectl set env deploy ...` change.

```bash
NS=kamiwaza-extensions
URL='http://traefik-internal.kamiwaza.svc.cluster.local.:8081/api'

sudo KUBECONFIG=/root/.kube/config kubectl -n "$NS" get kext -o yaml \
  > /tmp/kamiwaza-extensions.kext.before-api-url-hotfix.yaml

sudo KUBECONFIG=/root/.kube/config python3 - <<'PY'
import json
import subprocess

NS = "kamiwaza-extensions"
URL = "http://traefik-internal.kamiwaza.svc.cluster.local.:8081/api"

data = json.loads(subprocess.check_output([
    "kubectl", "-n", NS, "get", "kext", "-o", "json"
]))

for item in data["items"]:
    name = item["metadata"]["name"]
    spec = item.setdefault("spec", {})
    kamiwaza = spec.setdefault("kamiwaza", {})
    patch = []

    patch.append({
        "op": "replace" if "apiUrl" in kamiwaza else "add",
        "path": "/spec/kamiwaza/apiUrl",
        "value": URL,
    })

    for si, svc in enumerate(spec.get("services", [])):
        env = svc.get("env")
        if env is None:
            patch.append({"op": "add", "path": f"/spec/services/{si}/env", "value": []})
            env = []

        has_internal = False
        for ei, entry in enumerate(env):
            if entry.get("name") == "KAMIWAZA_API_URL":
                patch.append({
                    "op": "replace",
                    "path": f"/spec/services/{si}/env/{ei}/value",
                    "value": URL,
                })
            if entry.get("name") == "KAMIWAZA_INTERNAL_API_URL":
                has_internal = True
                patch.append({
                    "op": "replace",
                    "path": f"/spec/services/{si}/env/{ei}/value",
                    "value": URL,
                })

        if not has_internal:
            patch.append({
                "op": "add",
                "path": f"/spec/services/{si}/env/-",
                "value": {"name": "KAMIWAZA_INTERNAL_API_URL", "value": URL},
            })

    subprocess.run([
        "kubectl", "-n", NS, "patch", "kext", name,
        "--type=json", "-p", json.dumps(patch),
    ], check=True)
PY

sudo KUBECONFIG=/root/.kube/config kubectl -n "$NS" get deploy -o name \
  | xargs -r sudo KUBECONFIG=/root/.kube/config kubectl -n "$NS" rollout restart
```

This patches all currently installed extension CRs. Re-run this block after creating
new 0.13.0 extensions until the image/operator fixes are available.

Quick verification:

```bash
sudo KUBECONFIG=/root/.kube/config kubectl -n kamiwaza get deploy core-scheduler \
  -o jsonpath='{.spec.template.spec.dnsConfig.options[?(@.name=="ndots")].value}{"\n"}'

sudo KUBECONFIG=/root/.kube/config kubectl -n kamiwaza get raycluster core-raycluster \
  -o jsonpath='{.spec.headGroupSpec.template.spec.dnsConfig.options[?(@.name=="ndots")].value}{"\n"}'

sudo KUBECONFIG=/root/.kube/config kubectl -n kamiwaza get middleware.traefik.io core-forwardauth \
  -o jsonpath='{.spec.forwardAuth.address}{"\n"}'

sudo KUBECONFIG=/root/.kube/config kubectl -n kamiwaza-extensions get kext \
  -o jsonpath='{range .items[*]}{.metadata.name}{" apiUrl="}{.spec.kamiwaza.apiUrl}{"\n"}{end}'

sudo KUBECONFIG=/root/.kube/config kubectl -n kamiwaza-extensions get deploy \
  -o jsonpath='{range .items[*]}{.metadata.name}{" KAMIWAZA_API_URL="}{range .spec.template.spec.containers[*].env[?(@.name=="KAMIWAZA_API_URL")]}{.value}{end}{" KAMIWAZA_INTERNAL_API_URL="}{range .spec.template.spec.containers[*].env[?(@.name=="KAMIWAZA_INTERNAL_API_URL")]}{.value}{end}{"\n"}{end}'
```

Expected result: Core and Ray show `3`, Traefik ForwardAuth uses a
`*.svc.cluster.local.` target, and current extension CRs and Deployments use
`http://traefik-internal.kamiwaza.svc.cluster.local.:8081/api` for both
`KAMIWAZA_API_URL` and `KAMIWAZA_INTERNAL_API_URL`.

This does **not** replace the durable app/operator fixes. It does not rewrite every
hardcoded fallback URL inside 0.13.0 images, nor does it stop the 0.13.0 extension
operator from generating short dependency service names for future extension pods.

---

## Auth refresh / Keycloak lockout stabilization for 0.13.0

Apply these after reinstall if the offline 0.13.0 environment shows repeated auth
refresh calls, browser sessions that do not receive refreshed cookies, or Keycloak
lockout pressure.

1. Patch Traefik so ForwardAuth refresh cookies actually get back to the browser:

   ```bash
   NS=kamiwaza
   kubectl -n "$NS" patch middlewares.traefik.io core-forwardauth --type=merge -p '{"spec":{"forwardAuth":{"addAuthCookiesToResponse":["access_token","access_token_refresh","access_token_refresh_ts","access_token_id"]}}}'
   kubectl -n "$NS" get middlewares.traefik.io core-forwardauth -o jsonpath='{.spec.forwardAuth.addAuthCookiesToResponse[*]}'; echo
   ```

2. Stop Keycloak lockout pressure and raise the 0.13.0 refresh interval.
3. Turn off debug logging, then restart core once:

   ```bash
   NS=kamiwaza
   kubectl -n "$NS" patch configmap core-config --type=merge -p '{"data":{
     "AUTH_GATEWAY_REFRESH_MIN_INTERVAL_SECONDS":"3600",
     "AUTH_GATEWAY_REFRESH_EXPIRY_THRESHOLD_SECONDS":"300",
     "AUTH_GATEWAY_JWKS_TTL_SECONDS":"86400",
     "LOG_LEVEL":"INFO",
     "AUTH_GATEWAY_LOG_LEVEL":"INFO",
     "KAMIWAZA_DEBUG":"false",
     "KAMIWAZA_DEBUG_MODE":"false",
     "KAMIWAZA_DEBUG_RAY":"false",
     "KAMIWAZA_DEBUG_DOWNLOAD":"false"
   }}'

   kubectl -n "$NS" rollout restart deploy/core-scheduler
   kubectl -n "$NS" delete pod -l ray.io/cluster=core-raycluster,ray.io/node-type=head
   ```
