# Extension trust pattern + Kaizen sandbox follow-on (0.13.0)

Use this folder **after** the parent [`../`](../) packet is green for core / Ray.

The goal here is two-layered:

1. define the **generic extension trust pattern** for declared extension pods
2. document the **Kaizen-specific sandbox follow-on**, where spawned agent pods
   must inherit that trust wiring too

This stays within the same emergency `0.13.0` constraint: additive trust bundle,
verification left ON, and no new images.

If you need the live `maxPods: 1000` backport for offline `release/0.13.0`
production, use the top of the parent [`../README.md`](../README.md). It is
documented there once on purpose.

## Two layers

### 1. Generic extension trust pattern

For any extension with **declared service pods** in `kamiwaza-extensions`, the
reusable config-only pattern is:

- mount `kamiwaza-trust-bundle`
- set `SSL_CERT_FILE`, `REQUESTS_CA_BUNDLE`, and `AWS_CA_BUNDLE`
- keep TLS verification ON
- allow external egress only when the extension actually needs it

This layer is broadly reusable across extensions even though the helper scripts
in this folder are Kaizen-focused.

### 2. Kaizen-specific sandbox follow-on

Kaizen adds one more boundary:

- declared `backend` / `sandbox-controller` services must pick up the trust
  bundle like any other extension
- **spawned sandbox pods** in `kamiwaza-sandboxes` must also end up trusting the
  corporate CA

**What the sandbox actually needs (and why it's simpler than it looks).** The
Kaizen agent image entrypoint already pins trust to a fixed path — it runs
`update-ca-certificates` and unconditionally exports
`SSL_CERT_FILE=REQUESTS_CA_BUNDLE=/etc/ssl/certs/ca-certificates.crt`
(`apps/kaizenv3/backend/entrypoint-agent.sh`). So the sandbox needs **no CA env
injection at all** — the single requirement is that the corporate CA is present
in that one file **inside the sandbox pod**.

That file is owned by the spawned pod, which the **sandbox-controller** creates —
not the operator and not Helm values. Customer config (this packet) cannot add a
volume to it. So if a live probe from the sandbox to a corporate-CA endpoint
fails, the remaining gap is sandbox-controller / operator behavior, not customer
values — stop calling the packet complete.

> **Structural checks alone do not prove sandbox trust.** The agent image already
> ships a full CA bundle (Mozilla set + the Traefik cert it installs), so a
> sandbox can show `SSL_CERT_FILE` set and a populated bundle file **without** the
> corporate CA being present. Only the **live TLS probe** to a corporate-CA-signed
> endpoint actually proves the sandbox trusts your CA.

## Files

| File | Purpose |
| --- | --- |
| [`sandbox-target-namespaces-values-snippet.yaml`](sandbox-target-namespaces-values-snippet.yaml) | Generic follow-on values snippet: adds `kamiwaza-sandboxes` to the trust-bundle sync targets. |
| [`apply-kaizen-extension-trust.py`](apply-kaizen-extension-trust.py) | Kaizen-specific helper: patches a live Kaizen `KamiwazaExtension` CR so its declared services pick up the generic trust pattern. |
| [`verify-kaizen.sh`](verify-kaizen.sh) | Kaizen-specific verifier: checks declared backend trust wiring **and** whether the spawned sandbox pod inherited it. |
| [`kaizen-offline-template-livepatch/`](kaizen-offline-template-livepatch/) | Offline / local-catalog livepatch for future Kaizen launches: 30-day lifetime / retention plus selected `0.13.1` startup and memory fixes. |

## Apply order

1. Apply the parent packet in [`../README.md`](../README.md) and make `../verify.sh`
   pass for core / Ray.
2. Merge [`sandbox-target-namespaces-values-snippet.yaml`](sandbox-target-namespaces-values-snippet.yaml)
   into the same Deploy values layer as the parent trust snippet, then sync.
3. For **declared extension pods generally**, apply the generic pattern:
   mount `kamiwaza-trust-bundle`, inject the CA envs, keep verification ON, and
   allow external egress only when needed.

   For **Kaizen specifically**, patch the live extension CR with the helper:

   ```bash
   security/tls-trust/extensions/apply-kaizen-extension-trust.py <extension-name>
   ```

   Example:

   ```bash
   security/tls-trust/extensions/apply-kaizen-extension-trust.py kaizen-a1b2c3d4
   ```

   Optional proxy path for customer/private egress:

   ```bash
   security/tls-trust/extensions/apply-kaizen-extension-trust.py \
     --https-proxy http://squid.internal:3128 \
     --http-proxy http://squid.internal:3128 \
     --no-proxy localhost,127.0.0.1,.svc,.cluster.local \
     kaizen-a1b2c3d4
   ```

   Optional explicit Kamiwaza API base override for the Kaizen backend:

   ```bash
   security/tls-trust/extensions/apply-kaizen-extension-trust.py \
     --kamiwaza-base-url http://core-raycluster-head-svc.kamiwaza.svc:7777/api \
     kaizen-a1b2c3d4
   ```

   This injects proxy env into the **declared Kaizen backend service** only. It is
   still not assumed to reach spawned sandboxes; that remains a verification
   gate below.

4. For Kaizen, open or resume a conversation so the sandbox-controller actually
   spawns an agent pod in `kamiwaza-sandboxes`.
5. If this customer is on offline / local catalog `0.13.0` and future Kaizen
   launches also need the selected `0.13.1` template fixes, run
   [`kaizen-offline-template-livepatch/`](kaizen-offline-template-livepatch/).
6. For Kaizen, run the verifier:

   ```bash
   security/tls-trust/extensions/verify-kaizen.sh <extension-name>
   ```

   Optional live TLS probe:

   ```bash
   security/tls-trust/extensions/verify-kaizen.sh <extension-name> https://bedrock.example.com
   ```

## What the Kaizen patcher changes

For the live Kaizen `KamiwazaExtension` CR, the patcher patches the **declared**
`backend` and `sandbox-controller` services only.

**The two changes that actually establish corporate-CA trust on the backend:**

- mounts `kamiwaza-trust-bundle` at `/etc/ssl/certs/ca-certificates.crt`
- injects `SSL_CERT_FILE` + `REQUESTS_CA_BUNDLE` pointing at that path — these are
  the **load-bearing pair** for Kaizen (httpx + requests/MCP). `AWS_CA_BUNDLE` is
  injected too, but only covers any *direct* boto3/botocore use; Kaizen's backend
  path is httpx/requests, so it is belt-and-suspenders, not the lever.

**Re-asserting the platform's secure TLS defaults (only matters if TLS was turned off):**

- `spec.kamiwaza.tlsRejectUnauthorized: "1"` — the operator surfaces this to the
  pod via the `<deployment-id>-config` ConfigMap (`envFrom`)
- `AGENT_DISABLE_SSL_VERIFY=false` — set as a **direct** `env` on the backend service
- `KAMIWAZA_VERIFY_SSL=true` — set as a **direct** `env` on the backend service
- `KAMIWAZA_BASE_URL=...` — set as a **direct** `env` on the backend service.
  This is critical: Kaizen's Python backend reads `KAMIWAZA_BASE_URL`, not the
  platform's generic `KAMIWAZA_API_URL`. The patcher derives it from
  `spec.kamiwaza.apiUrl` by default (falling back to `publicApiUrl`), or you can
  force it with `--kamiwaza-base-url`.
- `KAMIWAZA_TLS_REJECT_UNAUTHORIZED=1` — also set as a **direct** `env` on the
  backend service. This is required, not redundant: when the platform was
  generated in insecure mode it leaves a stale **direct** `env`
  `KAMIWAZA_TLS_REJECT_UNAUTHORIZED=0` on the backend, and a container's direct
  `env` **overrides** the same key coming from `envFrom`. So setting only
  `spec.kamiwaza.tlsRejectUnauthorized` (which lands in the ConfigMap) is shadowed
  by the stale direct env — the patcher must override it directly.

  These are the **secure defaults**. The platform derives them from a single TLS
  setting (`AUTH_GATEWAY_TLS_INSECURE` / the platform TLS toggle), and the operator
  already renders them this way for every extension. If they are wrong, the root
  cause is that the platform was put in insecure mode — the simplest fix is to
  restore the platform TLS setting once, rather than patching each extension. The
  patcher re-asserts them idempotently as a safety net.

> **Timing: the patch lands after the operator reconciles.** The patcher applies
> the `KamiwazaExtension` CR; the operator then reconciles it into the Deployment
> and rolls the pod. A `kubectl rollout status` run *immediately* after the patch
> can return "successfully rolled out" against the **pre-reconcile** Deployment.
> Re-check the running pod's env (or rerun `verify-kaizen.sh`) a few seconds later
> to confirm the new values landed.

**Allowing egress + optional proxy:**

- `spec.networking.networkPolicy.allowExternalAccess: true`
- optionally injects `HTTPS_PROXY`, `HTTP_PROXY`, and `NO_PROXY` into the Kaizen
  **backend** when you pass them (or export them in the shell running the patcher)

> **Proxy and CA env do NOT propagate to spawned sandboxes.** The Kaizen backend
> builds `forward_env` for spawned agents (`conversation_manager.py`), but in the
> verification-ON path it forwards only `MCP_VERIFY_SSL` and
> `KAMIWAZA_TRUST_TRAEFIK_CERT` — **not** `SSL_CERT_FILE` / `REQUESTS_CA_BUNDLE` /
> `AWS_CA_BUNDLE`, and **not** the proxy vars. Patching the backend therefore does
> not reach the sandbox; that remains the verification gate below.

## Why this is a script and not a plain manifest (and the durable fix)

The patcher is imperative on purpose — on `0.13.0` the mount **cannot** be added
to a live `KamiwazaExtension` declaratively:

- `spec.services` is an **atomic list** in the CRD (no
  `x-kubernetes-list-type: map`), so `kubectl apply --server-side` and
  `kubectl patch --type=merge` replace the *entire* services array, and JSON
  Patch (`--type=json`) can only target a service by **positional index**, which
  is dynamic. A static patch file can't reliably hit `backend` by name.
- The Kaizen catalog template is docker-compose, and the compose→CR adapter maps
  compose `volumes:` to **PVCs only**, never a ConfigMap mount — so the trust
  mount can't be baked into the template either.

So the script does the one thing manifests can't here: a **name-keyed
read-modify-write merge** of a ConfigMap volume + CA env into the live CR. A
`jq`/`kubectl` rewrite is possible but is the same imperative merge in a less
readable form — it buys nothing.

**The durable fix is platform-side, not in this repo.** The clean solution mirrors
the core `trustManager.enabled` pattern: have the **extension operator** inject
the `kamiwaza-trust-bundle` mount + `SSL_CERT_FILE`/`REQUESTS_CA_BUNDLE` into
extension service pods (gated by a value), and propagate that mount into the
**spawned sandbox pod** template via the sandbox-controller. That is the only path
that is both declarative *and* able to close the sandbox gap — but it requires
changes to the platform Helm charts and the operator/sandbox-controller images,
which live outside this examples repo. Until that ships, this script is the
supported **interim** path for live `0.13.0` clusters.

## Pass / fail criteria

**Pass for the generic extension trust pattern**

- `kamiwaza-trust-bundle` exists in `kamiwaza-extensions`
- the declared extension pod(s) have the bundle mounted at
  `/etc/ssl/certs/ca-certificates.crt`
- the declared extension pod(s) show `SSL_CERT_FILE`, `REQUESTS_CA_BUNDLE`, and
  `AWS_CA_BUNDLE` pointing at that path

**Additional pass criteria for Kaizen declared services**

- the Kaizen backend pod no longer runs with the Kaizen SSL-bypass flags
- if proxy envs were requested, the Kaizen backend pod shows them too

**Additional pass criteria for the Kaizen sandbox path**

- `kamiwaza-trust-bundle` exists in `kamiwaza-sandboxes`
- a spawned sandbox pod exists for the extension
- the sandbox pod has a CA bundle at `/etc/ssl/certs/ca-certificates.crt` with
  `SSL_CERT_FILE` / `REQUESTS_CA_BUNDLE` pointing at it (the agent entrypoint sets
  these itself; `AWS_CA_BUNDLE` and proxy vars are **not** forwarded to sandboxes,
  so do not gate on them here)
- **the live TLS probe from the sandbox to a corporate-CA endpoint succeeds** —
  this is the only check that proves the corporate CA (and not just the image's
  default bundle) is actually trusted

**Fail / stop**

- no sandbox pod exists yet: create or resume a Kaizen conversation, then rerun
- sandbox pod exists but the live probe to a corporate-CA endpoint fails (the
  corporate CA is not in the sandbox's `/etc/ssl/certs/ca-certificates.crt`): the
  current `0.13.0` config-only packet stops here; the remaining gap is
  sandbox-controller / operator behavior, not customer Helm values

## Important hostname constraint

The generic extension trust pattern solves **CA trust**. It does **not**
override normal TLS hostname validation.

That matters especially for Kaizen because model/serving endpoints are often
reached by **IP-literal** HTTPS URLs — App Garden deployments expose ports on a
host IP, so an agent config can point at something like
`https://<host-ip>:611xx/v1`. Meanwhile the Kamiwaza Traefik ingress presents a
**wildcard DNS** cert, confirmed as `*.default.deployment.kamiwaza.ai` (see
`apps/kaizenv3/scripts/kamiwaza-entrypoint.sh`, which sets the cert-request SNI to
`toolshed.default.deployment.kamiwaza.ai` precisely so it matches that wildcard).

An IP-literal URL can never match a DNS-only wildcard cert, so if your sandbox
calls an IP-literal HTTPS URL while the server presents that wildcard cert, you
will still fail verification even after the CA bundle is mounted correctly:

- first failure mode: `self-signed certificate` / unknown CA
- second failure mode after trusting that CA: `IP address mismatch`

So for verification-on success you need **both**:

1. the CA bundle mounted and wired into the caller environment
2. the target hostname in the URL to match the certificate SANs

If the federal/customer endpoint is a private DNS hostname signed by the
customer CA, this packet can still work. If the endpoint is configured as an
IP-literal HTTPS URL, fix the endpoint naming first or use a different routing
pattern; do not assume a wildcard DNS cert or generic private CA patch will
make the IP literal verify.

### Kaizen must have `KAMIWAZA_BASE_URL`, and the internal API URL can still be the real-world tripwire

This is **not** only about IP literals or sandbox model endpoints. Kaizen's
Python backend reads `KAMIWAZA_BASE_URL`. The platform generically injects
`KAMIWAZA_API_URL` / `KAMIWAZA_PUBLIC_API_URL` into extensions, but Kaizen's
backend does **not** consume those names directly. If `KAMIWAZA_BASE_URL` is
left unset, the backend falls back to its app default (`https://localhost`) and
then surfaces "Unable to connect to Kamiwaza API" / model auto-discovery
failures / chat 502s even though the rest of the platform is healthy.

The patcher now fixes that by setting `KAMIWAZA_BASE_URL`, but the **value**
still matters. On some builds the platform's `apiUrl` is an **internal HTTPS
service hostname** such as `https://traefik.kamiwaza.svc.cluster.local/api`.
That hostname does **not** match the Traefik serving cert
(`*.kamiwaza.test` / `*.default.deployment.kamiwaza.ai`), so the moment this
packet turns verification **on**, the backend's calls to its own API base fail
with a **hostname mismatch** — even though the CA is now trusted. With
verification off (the platform default) that mismatch was silently ignored, so
it surfaces *only after applying this packet*.

**Check before patching** what the extension actually calls:

```bash
kubectl -n kamiwaza-extensions exec <kaizen-backend-pod> -- \
  sh -c 'echo "BASE=$KAMIWAZA_BASE_URL"; echo "API=$KAMIWAZA_API_URL"; echo "PUBLIC=$KAMIWAZA_PUBLIC_API_URL"'
```

- `KAMIWAZA_BASE_URL` is **HTTP** (e.g. `http://core-api.kamiwaza.svc:7777/api`):
  verification does not apply to it — safe, and usually ideal for in-cluster
  control-plane calls.
- `KAMIWAZA_BASE_URL` is **HTTPS to an internal `.svc` hostname**: verification ON
  will break it. Before (or instead of) flipping verify on, make it cert-matching:
  - rerun the patcher with `--kamiwaza-base-url` pointing at the public origin
    (`https://kamiwaza.test/api` — the same host Kaizen already uses for *model*
    calls, which **does** verify cleanly), **or**
  - have the platform serve a Traefik cert whose SANs include the internal
    hostname (`traefik.kamiwaza.svc.cluster.local`).

> Model calls from Kaizen already use the public origin
> (`https://kamiwaza.test/runtime/models/...`), which matches the cert and verifies
> cleanly. It is specifically the backend's own API base that can be wrong:
> either missing (`KAMIWAZA_BASE_URL` unset) or pointed at a non-cert-matching
> internal hostname. `verify-kaizen.sh` now probes the backend's real
> `KAMIWAZA_BASE_URL` under verification-on (step 3a) so it **fails closed** on
> both cases instead of letting you ship a packet that silently breaks the
> extension.
