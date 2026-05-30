# Kaizen sandbox trust (spawned-sandbox CA bundle)

**Scenario:** close the last gap left open by the parent [`../`](../) packet — make the
Kaizen **spawned sandbox** pods (not just the declared backend) trust your corporate CA,
**config-only**: no new image, no image rebuild, no trust-manager. The parent packet
already builds the additive `kamiwaza-trust-bundle` ConfigMap and mounts it on
core / Ray / declared extension pods; this recipe gets that same bundle, mounted at the
same path, into every sandbox the Kaizen sandbox-controller spawns.

**Tags:** #security #tls #ca-trust #kaizen #sandbox #config-only

> Use this **after** the parent packet is green for core / Ray and the generic
> [`../README.md`](../README.md) extension follow-on is applied for the declared Kaizen
> backend. This folder only addresses the spawned-sandbox boundary.

> **The recommended way to close this boundary is the generic, dynamic
> [`../extension-trust-webhook/`](../extension-trust-webhook/)** — it covers sandboxes
> **and** declared pods for **all** extensions, automatically and across redeploys. The
> per-extension controller overlay documented in the rest of this README is now the niche
> **fallback** (single stable Kaizen extension, no admission webhook wanted).

---

## Two ways to do this

There are two config-only ways to land the trust bundle in spawned sandboxes. Both reuse the
**same `kamiwaza-trust-bundle` ConfigMap** at the **same `/etc/ssl/certs/ca-certificates.crt`
path** — they differ only in *how* the mount reaches the spawned pod.

| Approach | What it does | Dynamic? | When to use |
| --- | --- | --- | --- |
| **(a) Dynamic, extension-agnostic webhook (recommended)** → [`../extension-trust-webhook/`](../extension-trust-webhook/) | A mutating admission webhook injects the bundle mount **and** CA env into **every** sandbox pod **and** every declared extension pod at admission time | **Yes** — every conversation, resume, redeployed extension, and brand-new/second extension, across **all** extensions, automatically | The general case — zero per-extension action, survives redeploys, covers declared pods too |
| **(b) Per-extension Kaizen controller overlay** (`apply-sandbox-controller-trust.py`, the rest of this README) | Overlays **one** Kaizen extension's sandbox-controller pod-builder | **No** — tied to one extension's CR, **lost on redeploy**, must be re-run per extension | The niche fallback: you don't want an admission webhook **and** have a **single stable** Kaizen extension |

**(a) Recommended: the dynamic, extension-agnostic webhook**
([`../extension-trust-webhook/`](../extension-trust-webhook/)). Because it mutates **pod
creation** rather than controller code, it auto-applies to every sandbox from every
extension (and to declared extension pods), survives extension redeploys, and needs no
per-extension action. This is the durable replacement for the overlay below.

**(b) Alternative: the per-extension Kaizen controller overlay** (the rest of this
README). Simpler — no admission webhook — but it is **not** dynamic: it patches one
Kaizen extension's sandbox-controller, is tied to that extension's CR, and is **lost when
that extension is redeployed or a new/second Kaizen extension is created** (you must
re-run it per extension). Keep it as the fallback for "I don't want an admission webhook
and have a single stable Kaizen extension."

> The rest of this README documents the **per-extension overlay fallback (b)**. For the
> recommended dynamic, extension-agnostic approach, see
> [`../extension-trust-webhook/`](../extension-trust-webhook/).

---

## Why this is needed (for the overlay alternative)

The Kaizen sandbox-controller builds every agent sandbox pod **programmatically** in
`kaizen/sandbox_controller/backends/kubernetes.py` (methods `_build_pod` and
`_build_resume_pod`). The pod spec for a sandbox is decided in that code — **not** by
Helm values and **not** by the `KamiwazaExtension` CR. Neither customer config surface can
add a volume to a pod the controller invents at spawn time.

One config-only way to land the trust bundle in a sandbox without an admission webhook is to
overlay a tiny patch onto **that one controller file** and let the controller mount the
bundle into the pods it creates. That is exactly what
[`apply-sandbox-controller-trust.py`](apply-sandbox-controller-trust.py) does — the file
is the source of truth for behavior and flags; this README is the operator guide. (The
dynamic [`../extension-trust-webhook/`](../extension-trust-webhook/) achieves the same
mount cluster-wide — for sandboxes and declared pods alike — without touching controller
code; see [Two ways to do this](#two-ways-to-do-this).)

## How it works

[`apply-sandbox-controller-trust.py`](apply-sandbox-controller-trust.py) does five things,
imperatively, and ships **no static controller file**:

1. **Extract** the *live* `kubernetes.py` from the running sandbox-controller pod, so the
   overlay is always byte-matched to the deployed controller version. **No committed file,
   no version drift.** (`--from-file` substitutes a file extracted offline — see caveats.)
2. **Inject** a `kamiwaza-trust-bundle` volume + volumeMount into `_build_pod` and
   `_build_resume_pod` by keying on the structural anchors `volume_mounts=[` and
   `volumes=[`. Idempotent (sentinel `kamiwaza-trust-bundle (tls-trust)`); **fails closed**
   if the anchors are missing — it refuses to ship a broken or partial overlay rather than
   silently no-op.
3. **Validate** the patched file with `py_compile`.
4. **Create** a ConfigMap (default `kaizen-controller-trust-patch`, key `kubernetes.py`)
   holding the patched file.
5. **Patch** the live `KamiwazaExtension` CR so the `sandbox-controller` service
   subPath-mounts that file over the in-image module path (auto-detected, e.g.
   `/usr/local/lib/python3.12/site-packages/kaizen/sandbox_controller/backends/kubernetes.py`).
   The operator rolls the controller once; from then on every `_build_pod` /
   `_build_resume_pod` mounts `kamiwaza-trust-bundle` into the sandbox at
   `/etc/ssl/certs/ca-certificates.crt`.

This reuses the **same `kamiwaza-trust-bundle` ConfigMap and the same
`/etc/ssl/certs/ca-certificates.crt` mount path** as the rest of the packet — nothing new
to build, just a new mount target.

**Why the mount is honored inside the sandbox** (all verified against live controller
**1.8.13**):

- the Kaizen agent entrypoint (`entrypoint-agent.sh`) **unconditionally** exports
  `SSL_CERT_FILE=REQUESTS_CA_BUNDLE=/etc/ssl/certs/ca-certificates.crt`, so the agent
  already verifies against that exact path — no env injection needed in the sandbox
- the sandbox security context has a **writable rootfs** and a non-root `run_as_user`, so
  a read-only configMap subPath mount over that path is accepted and the agent verifies
  against it
- the spawned-pod bundle volume is `optional: true`, so a missing ConfigMap does **not**
  block the spawn — it just comes up with no CA file. See the prerequisite below.

### What's proven (against live controller 1.8.13)

| Check | Result |
| --- | --- |
| Anchors matched in the live file | **4 injection sites** (`_build_pod` + `_build_resume_pod`, each a mount + a volume) |
| Patched file compiles | `py_compile` clean |
| CR patch accepted | `kubectl apply --dry-run=server` returned **`configured`** — the operator/CRD accepts it |
| CRD schema supports the mount | the 1.8.13 CRD confirms `spec.services.items` carries `volumes` / `volumeMounts` |

## Prerequisites

- The parent [`../../README.md`](../../README.md) packet is **green** for core / Ray, and
  the generic declared-pod follow-on in [`../README.md`](../README.md) is applied for the
  Kaizen backend.
- `kamiwaza-trust-bundle` exists in **`kamiwaza-sandboxes`** — run
  `build-trust-bundle-configmap.sh --include-sandboxes`. The sandbox volume is
  `optional: true`, so without this the sandbox comes up with **no CA file, silently**.
- A **deployed Kaizen extension**, so the `sandbox-controller` pod exists (the controller
  runs before any conversation; the applier extracts the live file from it).
- `python3` + `kubectl` (with cluster access). **No docker, no image rebuild, no
  trust-manager.**

## Apply

```bash
# 1. Make sure the bundle exists in the sandbox namespace (additive: Mozilla + platform
#    root-ca + your corporate CA). Re-runnable / idempotent.
security/tls-trust/build-trust-bundle-configmap.sh \
  --ca-file /path/to/root+intermediate.pem \
  --include-sandboxes

# 2. Overlay the live sandbox-controller and patch the CR. Preview first if you like:
./apply-sandbox-controller-trust.py kaizen-a1b2c3d4 --print-only   # prints patched file + ConfigMap + CR patch, applies nothing
./apply-sandbox-controller-trust.py kaizen-a1b2c3d4                # applies the ConfigMap + CR patch

# 3. Wait for the operator to roll the controller (reconcile is async — see caveats):
kubectl -n kamiwaza-extensions rollout status deploy/<sandbox-controller-deploy>

# 4. Open or RESUME a Kaizen conversation so the controller spawns a FRESH sandbox pod
#    (the mount only lands on pods spawned after the rollout).

# 5. Verify — structural checks PLUS the live TLS probe that is the only real proof:
../verify-kaizen.sh kaizen-a1b2c3d4 https://<corp-ca-endpoint>
```

> `--ca-file` in step 1 is optional: if you already created the `kamiwaza-org-ca` Secret
> per the parent packet, omit it and the build script reads that Secret. `--include-sandboxes`
> is the part that matters here. The in-image module path the overlay mounts over is
> **auto-detected** from the running controller (`--site-packages-path` overrides it).

Useful flags (full set in the applier docstring / `--help`):

| Flag | Default | Purpose |
| --- | --- | --- |
| `<extension-name>` (positional) | — | the `KamiwazaExtension` to patch |
| `--namespace` | `kamiwaza-extensions` | extension namespace |
| `--controller-service` | `sandbox-controller` | controller service name on the CR |
| `--configmap-name` | `kaizen-controller-trust-patch` | ConfigMap holding the patched file |
| `--from-file` | — | patch THIS `kubernetes.py` instead of extracting live (must match the deployed image) |
| `--site-packages-path` | auto-detect | override the in-image module path to mount over |
| `--print-only` | off | print patched file + ConfigMap + CR patch; apply nothing |
| `--skip-cr-patch` | off | build/apply the ConfigMap only; don't touch the CR |

## Verify

Use [`../verify-kaizen.sh`](../verify-kaizen.sh) — this recipe is proven by its **steps 4
and 5**:

- **Step 4 (structural):** a spawned sandbox pod exists for the extension, has the bundle
  mounted at `/etc/ssl/certs/ca-certificates.crt`, and the agent's `SSL_CERT_FILE` /
  `REQUESTS_CA_BUNDLE` point at it.
- **Step 5 (live TLS probe):** an `httpx` GET from inside the sandbox to a
  corporate-CA-signed endpoint completes the handshake with verification ON.

> **Structural checks alone do not prove sandbox trust.** The Kaizen agent image already
> ships a full CA bundle (Mozilla set + the Traefik cert it installs), so step 4 can pass
> on the agent's **default** bundle without your corporate CA being present. **Only step 5,
> the live probe to a corporate-CA endpoint, proves the corporate CA is trusted.** Always
> pass a `https://<corp-ca-endpoint>` URL.

## Caveats

> **Mount strategy = mount-over (Choice A).** The bundle is mounted **over**
> `/etc/ssl/certs/ca-certificates.crt`, which is then read-only, so the agent's
> `update-ca-certificates` cannot re-merge a runtime-fetched Traefik leaf into it.
> Corporate-CA trust still works — the corporate CA is *in* the bundle, and the platform
> `root-ca` in the bundle covers Traefik via chain — and in-cluster MCP is HTTP, so this is
> acceptable. If you must preserve the runtime Traefik-leaf merge, mount the corp CA into
> `/usr/local/share/ca-certificates/` instead (alternative, **not** the default).

> **New pods only.** Sandboxes already running before the controller rollout keep their old
> spec. Open or **resume** a conversation *after* the rollout to get a fresh pod with the
> mount.

> **Not dynamic — lost on redeploy.** This overlay patches **one** extension's
> sandbox-controller and is tied to that extension's CR. Redeploying the extension reverts it
> to the stock controller, and a new/second Kaizen extension does not inherit it — you must
> re-run the applier per extension. If you need it to apply automatically and survive
> redeploys, use the dynamic [`../extension-trust-webhook/`](../extension-trust-webhook/) instead.

> **One controller per Kaizen extension.** Each `KamiwazaExtension` has its own
> sandbox-controller — re-run the applier per extension. A brand-new Kaizen from the catalog
> gets the stock controller until you run the applier (or bake the overlay into the
> deploy / catalog). The dynamic [`../extension-trust-webhook/`](../extension-trust-webhook/) avoids this entirely.

> **Version pin is auto-handled.** Because the applier extracts + patches the **live** file,
> the overlay always matches the running controller. But if you use `--from-file`, that file
> **must** match the deployed image or sandbox spawns break.

> **Hostname validation is orthogonal.** CA trust ≠ hostname match. An IP-literal or
> wrong-host HTTPS URL still fails after the patch (same as the parent packet's hostname
> caveat) — first `unknown CA`, then, once the CA is trusted, `IP address mismatch`.

> **Reconcile is async.** After the CR patch the operator rolls the controller a moment
> later; a `kubectl rollout status` run *immediately* after can read the **pre-reconcile**
> state. Re-check after a few seconds.

> **Rollback order matters.** Un-patch the CR (remove the `trust-controller-code` volume +
> mount) **before** deleting the `kaizen-controller-trust-patch` ConfigMap. The code-overlay
> mount is **not** optional, so deleting the ConfigMap while it is still mounted would
> crashloop the controller.

## Rollback

Reversible, in this order:

```bash
# 1. Un-patch the CR FIRST: remove the trust-controller-code volume + volumeMount from the
#    sandbox-controller service so the controller stops mounting the overlay. Then let the
#    operator roll it back to the in-image kubernetes.py.
kubectl -n kamiwaza-extensions edit kamiwazaextension kaizen-a1b2c3d4
#    (delete the `trust-controller-code` entries under the sandbox-controller service's
#     volumes / volumeMounts; reconcile is async — wait for the controller to roll)

# 2. THEN delete the ConfigMap (safe only once nothing mounts it):
kubectl -n kamiwaza-extensions delete configmap kaizen-controller-trust-patch
```

> Do **not** reverse this order. The code-overlay mount is not `optional`, so deleting the
> ConfigMap while the controller still references it crashloops the controller.

Sandboxes spawned after rollback revert to the stock spec (no bundle mount). Already-running
sandboxes are unaffected until they respawn.

## Files

| File | Purpose |
| --- | --- |
| [`../extension-trust-webhook/`](../extension-trust-webhook/) | **Dynamic, extension-agnostic trust (recommended).** A mutating admission webhook that injects the bundle mount + CA env into **every** spawned sandbox **and** every declared extension pod automatically — survives redeploys, no per-extension action. The durable replacement for the overlay below. |
| [`apply-sandbox-controller-trust.py`](apply-sandbox-controller-trust.py) | **Per-extension Kaizen overlay (fallback).** Extract → inject → validate → ConfigMap → CR-patch. Config-only; live extraction = no drift. Source of truth for behavior/flags. Not dynamic — re-run per extension. |
| [`smoke-test-local.sh`](smoke-test-local.sh) | Cluster-free validation of the overlay: PART A asserts the injection (4 sites, idempotent, compiles) against a sample `kubernetes.py`; optional PART B mirrors the proven local E2E with the demo PKI + agent image. |
| [`README.md`](README.md) | This guide. |

> `apply-sandbox-controller-trust.py` and `smoke-test-local.sh` are executable; if your
> checkout dropped the bit, `chmod +x` them.

## Durable platform fix

Same theme as the parent extensions [`../README.md`](../README.md) "durable fix" section:
the clean long-term answer is **platform-side**. The sandbox-controller / operator should
ship this sandbox mount **natively**, gated by a value — mirroring the core
`trustManager.enabled` pattern — so the `kamiwaza-trust-bundle` is propagated into the
spawned-pod template without overlaying controller code. That is the only path that is both
declarative and able to close the sandbox boundary, but it requires changes to the platform
charts and the sandbox-controller image, which live outside this examples repo.

In-repo, the **dynamic [`../extension-trust-webhook/`](../extension-trust-webhook/) is the
durable interim** — it closes the sandbox boundary (and the declared-pod boundary) for every
extension without per-extension patching and survives redeploys, so it does not drift the way
this single-extension overlay does. This overlay remains the fallback for operators who do not
want to run an admission webhook on a single stable Kaizen extension.
