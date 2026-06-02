# Extension trust (declared pods + Kaizen sandboxes) — 0.13.0

Use this folder **after** the parent [`../`](../) packet is green for core / Ray.

> **The mechanism is the mutating admission webhook:
> [`extension-trust-webhook/`](extension-trust-webhook/).** Deploy it once and **every**
> extension workload trusts the corporate CA automatically — declared service pods of any
> extension (apps, tools, MCP servers) **and** the spawned sandbox pods that
> sandbox-spawning extensions (e.g. Kaizen) create — across redeploys, with **no
> per-extension patching**. The other files here are Kaizen-specific *remediation* and
> *verification* that the generic webhook does not do.

This stays within the same `0.13.0` constraint: additive trust bundle, verification left
ON, no new images.

If you need the live `maxPods: 1000` backport for offline `release/0.13.0` production, use
the top of the parent [`../README.md`](../README.md). It is documented there once on purpose.

The separate frontend font hotfix below is an image-tar workaround for a different
offline startup failure: Next.js rebuilds that try to fetch Google Fonts.

## What the webhook covers (and what it doesn't)

A single `MutatingWebhookConfiguration` injects the `kamiwaza-trust-bundle` mount + the CA
env vars (`SSL_CERT_FILE`, `REQUESTS_CA_BUNDLE`, `AWS_CA_BUNDLE`, `NODE_EXTRA_CA_CERTS`,
only-if-absent) into:

- **declared extension pods** in `kamiwaza-extensions` (label `extensions.kamiwaza.io/deployment-id`)
- **spawned sandbox pods** in `kamiwaza-sandboxes` (label `kamiwaza.io/sandbox=true`)

That is the entire mount + CA-env story for both boundaries — see
[`extension-trust-webhook/`](extension-trust-webhook/) for how it works, the
`kamiwaza-system` deployment gotcha, and `failurePolicy: Ignore` semantics.

What the webhook does **not** do, and Kaizen still needs:

- re-assert Kaizen's secure verify-on flags when the platform was generated in insecure mode
- fix a non-cert-matching internal `KAMIWAZA_API_URL` (the most common real-world tripwire — see below)
- open egress / inject a proxy on the declared Kaizen backend

Those live in [`apply-kaizen-extension-trust.py`](apply-kaizen-extension-trust.py).

## Files

| File | Purpose |
| --- | --- |
| [`extension-trust-webhook/`](extension-trust-webhook/) | **The mechanism (recommended).** Mutating admission webhook that injects the `kamiwaza-trust-bundle` mount + CA env into **every** declared extension pod **and** spawned sandbox pod, automatically and across redeploys — no per-extension patching, no controller overlay, no new image. Validated live. |
| [`apply-kaizen-extension-trust.py`](apply-kaizen-extension-trust.py) | **Kaizen-specific remediation the webhook does not do:** re-asserts the secure verify-on flags, fixes the internal-`KAMIWAZA_API_URL` mismatch, and opens egress / injects a proxy on the declared backend CR. The mount + CA env is the webhook's job now, so run this **only** for that remediation. |
| [`verify-kaizen.sh`](verify-kaizen.sh) | Kaizen verifier: checks declared-backend trust wiring **and** whether the spawned sandbox inherited it (including the live TLS probe — the only real proof of corporate-CA trust). |
| [`kaizen-offline-template-livepatch/`](kaizen-offline-template-livepatch/) | Offline / local-catalog livepatch for future Kaizen launches: 30-day lifetime / retention plus selected `0.13.1` startup and memory fixes. Unrelated to CA trust. |
| [`kaizen-offline-frontend-font-hotfix/`](kaizen-offline-frontend-font-hotfix/) | Offline image-tar hotfix for `0.13.0` Kaizen frontend startup rebuilds that fail on `next/font/google` / Google Fonts access. |

## Apply order

1. Apply the parent packet in [`../README.md`](../README.md) and make `../verify.sh` pass
   for core / Ray.
2. Write the `kamiwaza-trust-bundle` ConfigMap into the sandbox namespace too (additive:
   Mozilla set + platform `root-ca` + your corporate CA):

   ```bash
   security/tls-trust/build-trust-bundle-configmap.sh --ca-file /path/to/root+intermediate.pem --include-sandboxes
   ```

   > `--include-sandboxes` is what writes the bundle into `kamiwaza-sandboxes` (in addition
   > to the three defaults `kamiwaza` / `kamiwaza-system` / `kamiwaza-extensions`). `--ca-file`
   > is optional if you already created the `kamiwaza-org-ca` Secret per the parent packet.
   > No values change is needed — trust-manager is not used; the script applies the ConfigMap directly.

3. **Deploy the webhook once** — this covers every extension's declared pods **and** spawned
   sandboxes (the mount + CA env, injected at pod-create, across redeploys). Full guide:
   [`extension-trust-webhook/`](extension-trust-webhook/).

   ```bash
   security/tls-trust/extensions/extension-trust-webhook/deploy-extension-trust-webhook.sh
   ```

4. **(Kaizen-only, optional)** If the platform was put in insecure mode, or the backend's
   `KAMIWAZA_API_URL` is an HTTPS `.svc` hostname (see
   [the internal API URL tripwire](#the-internal-api-url-is-the-most-common-real-world-tripwire-verify-this-first)),
   run the remediation patcher on the live extension CR:

   ```bash
   security/tls-trust/extensions/apply-kaizen-extension-trust.py <extension-name>
   ```

   Optional proxy path for customer/private egress:

   ```bash
   security/tls-trust/extensions/apply-kaizen-extension-trust.py \
     --https-proxy http://squid.internal:3128 \
     --http-proxy http://squid.internal:3128 \
     --no-proxy localhost,127.0.0.1,.svc,.cluster.local \
     <extension-name>
   ```

   This patches the **declared Kaizen backend** only. It does not reach spawned sandboxes —
   the bundle reaches sandboxes via the webhook, not via the backend's `forward_env` (see note below).

5. For Kaizen, open or **resume** a conversation so the sandbox-controller spawns a fresh
   agent pod in `kamiwaza-sandboxes`. The webhook mutates pods at **CREATE**, so this must
   come after the webhook is deployed.
6. If this customer is on offline / local catalog `0.13.0` and future Kaizen launches also
   need the selected `0.13.1` template fixes, run
   [`kaizen-offline-template-livepatch/`](kaizen-offline-template-livepatch/).
7. If this customer is on a fully disconnected `0.13.0` install and the Kaizen
   frontend fails its startup rebuild while trying to fetch Google Fonts, patch
   the bundled frontend image tar with
   [`kaizen-offline-frontend-font-hotfix/`](kaizen-offline-frontend-font-hotfix/).
8. Verify:

   ```bash
   security/tls-trust/extensions/verify-kaizen.sh <extension-name>
   security/tls-trust/extensions/verify-kaizen.sh <extension-name> https://<corp-ca-endpoint>   # + live TLS probe
   ```

> **Structural checks alone do not prove corporate-CA trust.** An extension or agent image
> already ships a full CA bundle (Mozilla set + a Traefik leaf it installs), so the mount +
> env can be present without your corporate CA being trusted. Only a **live TLS probe to a
> corporate-CA-signed endpoint with verification ON** proves it — always pass a
> `https://<corp-ca-endpoint>` URL to `verify-kaizen.sh`.

## What the Kaizen patcher changes

For the live Kaizen `KamiwazaExtension` CR, [`apply-kaizen-extension-trust.py`](apply-kaizen-extension-trust.py)
patches the declared `backend` and `sandbox-controller` services. **The mount + CA env is
now provided generically by [`extension-trust-webhook/`](extension-trust-webhook/)** — run
this patcher only for the Kaizen-specific remediation below.

**Re-asserting the platform's secure TLS defaults (only matters if TLS was turned off):**

- `spec.kamiwaza.tlsRejectUnauthorized: "1"` — surfaced to the pod via the
  `<deployment-id>-config` ConfigMap (`envFrom`)
- `AGENT_DISABLE_SSL_VERIFY=false`, `KAMIWAZA_VERIFY_SSL=true`,
  `KAMIWAZA_TLS_REJECT_UNAUTHORIZED=1` — set as **direct** `env` on the backend. The last
  is required, not redundant: when the platform was generated in insecure mode it leaves a
  stale **direct** `KAMIWAZA_TLS_REJECT_UNAUTHORIZED=0` on the backend, and a container's
  direct `env` **overrides** the same key coming from `envFrom`. Setting only
  `spec.kamiwaza.tlsRejectUnauthorized` (the ConfigMap value) is shadowed by it.

  These are the platform's secure defaults; if they are wrong the root cause is that the
  platform was put in insecure mode. The cleanest fix is to restore the platform TLS
  setting once; the patcher re-asserts them idempotently as a safety net.

**Allowing egress + optional proxy:**

- `spec.networking.networkPolicy.allowExternalAccess: true`
- optionally injects `HTTPS_PROXY` / `HTTP_PROXY` / `NO_PROXY` into the Kaizen **backend**
  when you pass them

> **Timing: the patch lands after the operator reconciles.** The patcher applies the CR;
> the operator then reconciles it into the Deployment and rolls the pod. A `kubectl rollout
> status` run *immediately* after can return "successfully rolled out" against the
> **pre-reconcile** Deployment. Re-check (or rerun `verify-kaizen.sh`) a few seconds later.

> **Proxy and CA env do NOT propagate to spawned sandboxes.** The Kaizen backend builds
> `forward_env` for spawned agents (`conversation_manager.py`), but in the verification-ON
> path it forwards only `MCP_VERIFY_SSL` and `KAMIWAZA_TRUST_TRAEFIK_CERT` — **not**
> `SSL_CERT_FILE` / `REQUESTS_CA_BUNDLE` / `AWS_CA_BUNDLE`, and **not** the proxy vars. The
> CA bundle reaches the sandbox directly on the spawned pod via the webhook — not via
> `forward_env`.

### Why the patcher is a script, not a manifest

On `0.13.0` these changes **cannot** be applied to a live `KamiwazaExtension`
declaratively: `spec.services` is an **atomic list** in the CRD (no
`x-kubernetes-list-type: map`), so `kubectl apply`/`patch --type=merge` replaces the entire
services array and JSON Patch can only target a service by **positional index** (dynamic).
A static patch file can't reliably hit `backend` by name, and the compose→CR adapter maps
compose `volumes:` to PVCs only. So the patcher does a **name-keyed read-modify-write
merge** of the env/flags into the live CR.

## Important hostname constraint

CA trust ≠ hostname match. The webhook (and this packet) solve **CA trust**; they do **not**
override TLS hostname validation. An IP-literal or wrong-host HTTPS URL still fails after
the CA is trusted — first `unknown CA`, then `IP address mismatch`. This matters for Kaizen
because model/serving endpoints are often reached by **IP-literal** HTTPS URLs (App Garden
exposes ports on a host IP, e.g. `https://<host-ip>:611xx/v1`) while the Kamiwaza Traefik
ingress presents a **wildcard DNS** cert. For verification-on success you need **both** the
CA trusted **and** the target hostname matching the cert SANs.

### The internal API URL is the most common real-world tripwire (verify this first)

The platform hands each extension a `KAMIWAZA_API_URL` for calling the Kamiwaza API, and on
some builds that value is an **internal HTTPS service hostname** such as
`https://traefik.kamiwaza.svc.cluster.local/api`. That hostname does **not** match the
Traefik serving cert (`*.kamiwaza.test` / `*.default.deployment.kamiwaza.ai`), so the moment
verification turns **on**, the extension's calls to its own `KAMIWAZA_API_URL` fail with a
**hostname mismatch** — even though the CA is now trusted. With verification off (the
platform default) that mismatch was silently ignored, so it surfaces *only after applying
this packet*. Symptom: "Unable to connect to Kamiwaza API" / model auto-discovery fails, or
chat 502s, despite the CA being correctly trusted.

**Check before patching** what the extension actually calls:

```bash
kubectl -n kamiwaza-extensions exec <kaizen-backend-pod> -- \
  sh -c 'echo "API=$KAMIWAZA_API_URL"; echo "PUBLIC=$KAMIWAZA_PUBLIC_API_URL"'
```

- `KAMIWAZA_API_URL` is **HTTP** (e.g. `http://core-api.kamiwaza.svc:7777/api`):
  verification does not apply to it — safe.
- `KAMIWAZA_API_URL` is **HTTPS to an internal `.svc` hostname**: verification ON will break
  it. Point it at the public origin (`https://kamiwaza.test/api` — the same host Kaizen
  already uses for *model* calls, which verifies cleanly), **or** have the platform serve a
  Traefik cert whose SANs include the internal hostname. `apply-kaizen-extension-trust.py`
  auto-corrects this to the public origin when a `publicApiUrl`/`origin` is available, and
  `verify-kaizen.sh` probes the backend's real `KAMIWAZA_API_URL` under verification-on (step
  3a) so it **fails closed** on this mismatch.

## Pass / fail criteria

**Declared extension pods (webhook)**

- the declared extension pod(s) have `kamiwaza-trust-bundle` mounted at
  `/etc/ssl/certs/ca-certificates.crt` and show `SSL_CERT_FILE` / `REQUESTS_CA_BUNDLE` /
  `AWS_CA_BUNDLE` pointing at it

**Kaizen declared backend (after the remediation patcher, if it was needed)**

- the backend pod no longer runs with the Kaizen SSL-bypass flags
- the backend reaches its own `KAMIWAZA_API_URL` under verification-on
- if proxy envs were requested, the backend pod shows them

**Kaizen spawned sandbox (webhook)**

- `kamiwaza-trust-bundle` exists in `kamiwaza-sandboxes`, a spawned sandbox pod exists, and
  it has the bundle at `/etc/ssl/certs/ca-certificates.crt` (the agent entrypoint sets
  `SSL_CERT_FILE` / `REQUESTS_CA_BUNDLE` itself; `AWS_CA_BUNDLE` and proxy vars are not
  forwarded to sandboxes, so do not gate on them)
- **the live TLS probe from the sandbox to a corporate-CA endpoint succeeds** — the only
  check that proves the corporate CA (not just the image's default bundle) is trusted

**Fail / stop**

- no sandbox pod yet: open or resume a Kaizen conversation, then rerun
- sandbox pod exists but the live probe fails: confirm the webhook is deployed and reachable
  (it must run where the API server can reach it — see the `kamiwaza-system` gotcha in
  [`extension-trust-webhook/`](extension-trust-webhook/)), confirm `kamiwaza-trust-bundle`
  exists in `kamiwaza-sandboxes` (`build-trust-bundle-configmap.sh --include-sandboxes`),
  resume/open a new conversation so a fresh sandbox spawns, then re-run the probe

## Durable platform fix

The clean long-term answer is **platform-side** — the extension operator and
sandbox-controller should propagate the `kamiwaza-trust-bundle` mount + CA env into
extension service pods and the spawned-sandbox template natively, gated by a value
(mirroring the core `trustManager.enabled` pattern). That requires changes to the platform
charts and the operator / sandbox-controller images, which live outside this examples repo.
In-repo, the webhook is the durable interim — it closes both boundaries for every extension
without per-extension patching and survives redeploys. See the same section in
[`extension-trust-webhook/`](extension-trust-webhook/) for detail.
