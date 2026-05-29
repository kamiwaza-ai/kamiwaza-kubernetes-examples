# Custom TLS trust + BYO ingress cert

**Scenario:** make Kamiwaza platform pods trust a custom / enterprise / corporate PKI
for **outbound** TLS (private Bedrock endpoints, internal HuggingFace mirrors, private
registries, private object stores) **with verification left ON**, and serve the
**inbound** ingress cert from a non-Kamiwaza CA — without `SSL_VERIFY=false`,
without `AUTH_GATEWAY_TLS_INSECURE`, and without rebuilding containers.

It uses **only supported Helm values + Secrets** on the trust side (no chart edits),
and a manifest path for the ingress side on 0.13.0. Driver: a private AWS Bedrock
endpoint whose certificate is signed by a corporate CA.

> **Two blockers often travel together for custom Bedrock endpoints.** The
> privately-signed cert (this recipe) is usually paired with a **custom AWS region**
> botocore doesn't know. The region half lives in
> [`bedrock-custom-region/`](bedrock-custom-region/). Apply **both** and the
> `SSL_VERIFY=False` stopgap is unnecessary — TLS verification stays ON.

**Tags:** #security #tls #pki #ca-trust #bedrock #helm-values #ingress

---

## Compatibility / version pin

| Item | Status |
| --- | --- |
| Validated against | **Kamiwaza 0.13.0** |
| Outbound CA trust (this folder) | **Requires one extra prereq on 0.13.0** — install the trust-manager controller out-of-band first (see [Prereq A](#prereq-a-trust-manager-on-0130), then use `ca.trustBundle.customerCASecret` + `core.trustManager.enabled` + `core.scheduler.extraEnv` as documented |
| BYO ingress cert | **Manifest path on 0.13.0** — there is no native values knob, but the network subchart already manages a `default` TLSStore + wildcard Certificate, so the BYO manifests collide with Helm-owned resources. Read the [Helm-ownership caveat](ingress/#helm-ownership-on-0130) in `ingress/` before applying. **Not needed on later releases**, which serve a BYO ingress cert through a native values knob. |

> The trust bundle is **additive**: Mozilla public CAs **+** platform `root-ca` **+**
> your corporate CA(s). There is intentionally no "replace / drop public CAs" mode.

### What picks up new trust via this path

| Workload | Outbound trust | Notes |
| --- | --- | --- |
| `core-scheduler` | ✅ | bundle mounted at `/etc/ssl/certs/ca-certificates.crt` |
| Ray head + workers | ✅ | same mount; this is where Bedrock/LiteLLM runs |
| Frontend / extensions / Kaizen | ❌ deferred | platform follow-up (`NODE_EXTRA_CA_CERTS`, extension trust) |

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
- Access to Deploy values layering (`cluster/values/overrides.yaml`).
- Your enterprise **root + intermediate** CA chain as PEM (one file, concatenated is fine).

### Starting state: existing cluster vs fresh install

This recipe works on a cluster that is **already running** and on a **fresh install**.
Both paths must satisfy one ordering rule, then differ only in *when* you run the steps.

> **Ordering rule (both paths):** trust-manager ([Prereq A](#prereq-a-trust-manager-on-0130))
> and the `kamiwaza-org-ca` Secret must both exist in the `kamiwaza` namespace **before**
> the `helmfile sync` that sets `core.trustManager.enabled: true`. The bundle volume is
> `optional: true`, so a sync run *before* the prereqs are in place brings the
> scheduler/Ray pods up with **no CA file mounted** — silently. `verify.sh` (step 2 /
> in-pod cert count) is the guard.

**Path 1 — cluster already running (the verified path).**

1. Install trust-manager out-of-band ([Prereq A](#prereq-a-trust-manager-on-0130)).
2. Create the `kamiwaza-org-ca` Secret ([Step 1](#1-create-the-kamiwaza-org-ca-secret-in-kamiwaza)).
3. Merge the values snippet ([Step 2](#2-merge-the-values-snippet-into-clustervaluesoverridesyaml)).
4. `helmfile … sync` ([Step 3](#3-sync-and-wait-for-rollout)). The sync changes the
   scheduler/Ray **pod spec** (adds the mount + env), so the rollout it triggers brings
   pods up with the bundle already populated — no manual restart needed in the normal
   case. If a pod predates the synced ConfigMap, roll it (see [Recovery](#recovery--rollback-bad-ca)).

**Path 2 — fresh 0.13.0 install.** Namespaces don't exist until the first sync's
prepare hook creates them, but the Secret must live in `kamiwaza` before the
bundle-enabling sync. Two clean orderings:

- **(a) Sync, then enable (simplest).** Run a normal install first
  (`make install` / `helmfile … sync`) to create the namespaces and platform, then
  follow Path 1 exactly. This is just "existing cluster" applied to a cluster you
  brought up a minute ago.
- **(b) Pre-seed, enable on first boot.** Pre-create the `kamiwaza` namespace
  (`kubectl create namespace kamiwaza`), create the `kamiwaza-org-ca` Secret, install
  trust-manager, merge the values snippet, **then** run the first `make install` /
  `helmfile … sync`. Pods come up trusting your CA on first boot — no second sync, no
  rollout. Use this when you want the platform correct from the very first reconcile
  (e.g. air-gapped or GitOps bootstrap).

### Prereq A: trust-manager on 0.13.0

The trust-bundle CRD (`bundles.trust.cert-manager.io`) ships with the `ca` chart on
0.13.0 (`charts/ca/crds/`), but the **trust-manager controller does not** — on
`release/0.13.0` the `ca` chart declares `dependencies: []` (verify:
`grep -n dependencies charts/ca/Chart.yaml`), so no controller Deployment is rendered.
The controller is wired in as a `ca`-chart dependency on `develop`/`main` (ENG-2838),
but **that work is not on `release/0.13.0`** — so on a 0.13.0 cluster you must install
the controller out-of-band, while the Bundle CR the chart renders has nothing to
reconcile it until you do.

Check:

```bash
kubectl get crd bundles.trust.cert-manager.io                # must be Present
kubectl get deploy -A | grep -i trust-manager                # must be Running
```

If the CRD is present but the deployment is missing (the 0.13.0 default state),
install trust-manager out-of-band into `cert-manager`:

```bash
helm repo add jetstack https://charts.jetstack.io --force-update
helm repo update jetstack

helm install trust-manager jetstack/trust-manager \
  --namespace cert-manager \
  --version v0.21.1 \
  --set crds.enabled=false \
  --set app.trust.namespace=kamiwaza \
  --wait
```

`crds.enabled=false` because the Bundle CRD already ships at `charts/ca/crds/`;
re-installing it would conflict with the Helm-owned CRD.

> **Failure mode if you skip this on 0.13.0:** the chart still renders the Bundle
> CR and the scheduler/Ray pod volume mounts, but the bundle volume uses
> `optional: true`, so pods come up **with no CA file mounted at all** and corp TLS
> fails silently. `verify.sh` will fail on "Bundle ConfigMap synced" in step 2.

---

## What you get

| File | Purpose |
| --- | --- |
| [`trust-bundle-values-snippet.yaml`](trust-bundle-values-snippet.yaml) | Helm values overlay: enable trust bundle, point at the CA Secret, set `SSL_CERT_FILE` (covers httpx/LiteLLM/Bedrock) + `AWS_CA_BUNDLE` (direct boto3) on scheduler + Ray, plus an optional certifi-overlay fallback. |
| [`org-ca-secret.template.yaml`](org-ca-secret.template.yaml) | Direct-apply `kamiwaza-org-ca` Secret template. |
| [`kustomization.yaml`](kustomization.yaml) | Local-secret-driven generator for the same Secret (keeps PEM out of hand-edited YAML). |
| [`org-ca.pem.example`](org-ca.pem.example) | Placeholder PEM. |
| [`verify.sh`](verify.sh) | End-to-end verification (ConfigMap contents, namespace sync, pod env/mount, optional live TLS probe). |
| [`bedrock-custom-region/`](bedrock-custom-region/) | **Companion** — custom Bedrock **region** enablement. Declarative botocore hotfix so boto3 *accepts* a non-default region; pair with this recipe so no `SSL_VERIFY=False` is needed. |
| [`ingress/`](ingress/) | BYO ingress cert — manifest path required on 0.13.0 (not needed on later releases). |

---

## Steps — outbound CA trust

### 1. Create the `kamiwaza-org-ca` Secret in `kamiwaza`

A single Secret can carry root **and** intermediate(s) — the Bundle uses
`includeAllKeys: true`.

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

> The Secret **must** live in the `kamiwaza` namespace and **must exist before**
> the Helm sync that sets `ca.trustBundle.customerCASecret`.

### 2. Merge the values snippet into `cluster/values/overrides.yaml`

Copy [`trust-bundle-values-snippet.yaml`](trust-bundle-values-snippet.yaml) into your
highest-priority values file. It sets:

- `ca.trustBundle.customerCASecret: kamiwaza-org-ca` (`customerCASecret` is the chart's key name)
- `core.trustManager.enabled: true`  ← mounts the bundle on scheduler + Ray
- `core.scheduler.extraEnv` → **`SSL_CERT_FILE`** (covers stdlib `ssl`, httpx, and the
  LiteLLM/Bedrock path) **+ `AWS_CA_BUNDLE`** (covers any direct boto3 use)

> The chart already sets `REQUESTS_CA_BUNDLE`; this recipe adds `SSL_CERT_FILE` and
> `AWS_CA_BUNDLE`. **`SSL_CERT_FILE` is what makes Bedrock/LiteLLM trust your CA** — it
> is honored by httpx 0.28 and litellm 1.83 (Bedrock is httpx-based). No code changes,
> no certifi edit needed.

> ⚠️ **Known footgun (do not "fix"):** `cluster/values/kamiwaza-base.yaml` sets a
> **top-level** `trustManager:` key that the `core` subchart never reads. The working
> key is **`core.trustManager.enabled`**. (Tracked separately — document, don't patch base.)

### 3. Sync and wait for rollout

```bash
helmfile -f cluster/helmfile.yaml.gotmpl -e full sync
kubectl -n kamiwaza rollout status deploy/core-scheduler
kubectl -n kamiwaza rollout status statefulset/core-raycluster-head   # name may vary
```

### 4. (Fallback, rarely needed) certifi overlay

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

# (b) synced to all three namespaces
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

---

## Recovery / rollback (bad CA)

The whole recipe is Helm values + one Secret, so revert is a values rollback:

```bash
# remove the bad CA from the bundle: drop ca.trustBundle.customerCASecret, re-sync
helmfile -f cluster/helmfile.yaml.gotmpl -e full sync
# or roll the Secret back to known-good content and let trust-manager re-sync (seconds)
kubectl -n kamiwaza apply -f security/tls-trust/org-ca-secret.template.yaml
```

No data loss; trust-manager re-renders the ConfigMap in seconds. **However**, the
bundle is mounted with `subPath`, so kubelet does **not** refresh the file inside
running containers when the ConfigMap changes. To make a new bundle visible to
already-running pods you must roll them:

```bash
kubectl -n kamiwaza rollout restart deploy/core-scheduler
kubectl -n kamiwaza delete pod -l ray.io/cluster=core-raycluster,ray.io/node-type=head
```

This applies any time you change the customer CA Secret content too — the Bundle CR
will update the ConfigMap, but live pods keep their old `/etc/ssl/certs/ca-certificates.crt`
until they restart.

---

## Notes

- This example never generates PKI. Bring your org root/intermediate PEM.
- Do **not** commit real CA material — `local-secrets/` is gitignored.
- Ingress (BYO) cert is a separate concern — see [`ingress/`](ingress/).
- Code-side follow-ups (retire `AUTH_GATEWAY_TLS_INSECURE`, point the `httpx` client
  factory at the CA path, boto3 `verify=`, per-endpoint CA field) are tracked as
  platform follow-up work.
