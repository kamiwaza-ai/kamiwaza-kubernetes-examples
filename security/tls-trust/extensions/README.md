# Extensions / Kaizen follow-on (0.13.0)

Use this folder **after** the parent [`../`](../) packet is green for core / Ray.

The goal here is narrower: extend the same additive trust-bundle pattern into
Kaizen / extension workloads **without shipping new images** and determine
whether the current config-only packet reaches the spawned sandbox pods too.

## Scope

This folder covers two separate cases:

1. **Declared extension pods** in `kamiwaza-extensions`
   - supported config-only path
   - mount `kamiwaza-trust-bundle`
   - set `SSL_CERT_FILE` / `REQUESTS_CA_BUNDLE` / `AWS_CA_BUNDLE`
   - keep verification ON

2. **Spawned Kaizen sandboxes** in `kamiwaza-sandboxes`
   - not assumed
   - must be validated explicitly
   - if the sandbox pod does not show the bundle mount + CA env, stop calling
     the packet complete; that remaining gap belongs to sandbox-controller /
     operator behavior

## Files

| File | Purpose |
| --- | --- |
| [`sandbox-target-namespaces-values-snippet.yaml`](sandbox-target-namespaces-values-snippet.yaml) | Adds `kamiwaza-sandboxes` to the trust-bundle sync targets. |
| [`apply-kaizen-extension-trust.py`](apply-kaizen-extension-trust.py) | Fetches a live Kaizen `KamiwazaExtension` CR, injects bundle mount + CA env into declared services, flips verification back on, and reapplies it. |
| [`verify-kaizen.sh`](verify-kaizen.sh) | Validates the declared backend pod **and** the spawned sandbox pod. This is the gate that tells you whether config-only is actually enough. |

## Apply order

1. Apply the parent packet in [`../README.md`](../README.md) and make `../verify.sh`
   pass for core / Ray.
2. Merge [`sandbox-target-namespaces-values-snippet.yaml`](sandbox-target-namespaces-values-snippet.yaml)
   into the same Deploy values layer as the parent trust snippet, then sync.
3. Patch the live Kaizen extension CR:

   ```bash
   security/tls-trust/extensions/apply-kaizen-extension-trust.py <extension-name>
   ```

   Example:

   ```bash
   security/tls-trust/extensions/apply-kaizen-extension-trust.py kaizen-a1b2c3d4
   ```

4. Open or resume a Kaizen conversation so the sandbox-controller actually spawns
   an agent pod in `kamiwaza-sandboxes`.
5. Run the verifier:

   ```bash
   security/tls-trust/extensions/verify-kaizen.sh <extension-name>
   ```

   Optional live TLS probe:

   ```bash
   security/tls-trust/extensions/verify-kaizen.sh <extension-name> https://bedrock.example.com
   ```

## What the patcher changes

For the live Kaizen `KamiwazaExtension` CR, the patcher:

- sets `spec.kamiwaza.tlsRejectUnauthorized: "1"`
- sets `spec.networking.networkPolicy.allowExternalAccess: true`
- mounts `kamiwaza-trust-bundle` at `/etc/ssl/certs/ca-certificates.crt`
- injects `SSL_CERT_FILE`, `REQUESTS_CA_BUNDLE`, and `AWS_CA_BUNDLE`
- flips the Kaizen-side verify flags back on:
  - `AGENT_DISABLE_SSL_VERIFY=false`
  - `KAMIWAZA_VERIFY_SSL=true`

It patches the **declared** `backend` and `sandbox-controller` services only.
It does **not** claim to patch the spawned sandbox pod directly.

## Pass / fail criteria

**Pass for declared services**

- `kamiwaza-trust-bundle` exists in `kamiwaza-extensions`
- the Kaizen backend pod has the bundle mounted at
  `/etc/ssl/certs/ca-certificates.crt`
- the backend pod shows `SSL_CERT_FILE`, `REQUESTS_CA_BUNDLE`, and
  `AWS_CA_BUNDLE` pointing at that path
- the backend pod no longer runs with the Kaizen SSL-bypass flags

**Pass for sandbox path**

- `kamiwaza-trust-bundle` exists in `kamiwaza-sandboxes`
- a spawned sandbox pod exists for the extension
- that sandbox pod also shows the bundle mount and CA env

**Fail / stop**

- no sandbox pod exists yet: create or resume a Kaizen conversation, then rerun
- sandbox pod exists but lacks the mount or env: the current `0.13.0`
  config-only packet stops here; the remaining gap is sandbox-controller /
  operator propagation, not customer Helm values
