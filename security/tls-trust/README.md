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
| Outbound CA trust (this folder) | **Works as-is on 0.13.0** via `ca.trustBundle.customerCASecret` + `core.trustManager.enabled` + `core.scheduler.extraEnv` |
| BYO ingress cert | **Required on 0.13.0** — there is no native values knob, so use the manifest path in [`ingress/`](ingress/). **Not needed on later releases**, which serve a BYO ingress cert through a native values knob. |

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
- **trust-manager installed** (ships with the `ca` chart). Check:

  ```bash
  kubectl get crd bundles.trust.cert-manager.io
  kubectl get deploy -A | grep -i trust-manager   # must be Running
  ```

  > On a stock dev install trust-manager is part of the platform. If the deployment
  > is missing, the `ca` chart must be synced with trust-manager enabled before the
  > `kamiwaza-trust-bundle` ConfigMap can be produced.
- Access to Deploy values layering (`cluster/values/overrides.yaml`).
- Your enterprise **root + intermediate** CA chain as PEM (one file, concatenated is fine).

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

No data loss; trust-manager re-renders the ConfigMap automatically. Pods pick up the
new ConfigMap on next mount refresh; restart scheduler/Ray if you need it immediate.

---

## Notes

- This example never generates PKI. Bring your org root/intermediate PEM.
- Do **not** commit real CA material — `local-secrets/` is gitignored.
- Ingress (BYO) cert is a separate concern — see [`ingress/`](ingress/).
- Code-side follow-ups (retire `AUTH_GATEWAY_TLS_INSECURE`, point the `httpx` client
  factory at the CA path, boto3 `verify=`, per-endpoint CA field) are tracked as
  platform follow-up work.
