# Extension trust webhook (dynamic, extension-agnostic CA trust)

**Scenario:** make **every** Kamiwaza extension workload trust your corporate CA
**dynamically**, with **no per-extension patching** and **no controller-code overlay** —
declared service pods of any extension (apps, tools, MCP servers) **and** the spawned
sandbox pods that sandbox-spawning extensions (e.g. Kaizen) create. Config-only: no new
image, no image rebuild, no trust-manager.

**Tags:** #security #tls #ca-trust #webhook #extensions #sandbox #config-only

> This is the **recommended dynamic mechanism** for extension CA trust. It supersedes
> per-extension mount patching — it keys on namespace + extension labels, so any
> app / tool / MCP server / sandbox using those labels is covered automatically,
> **including extensions deployed after the webhook is installed**.

---

## How it works

A single `MutatingWebhookConfiguration` intercepts pod **CREATE** with **two rules**:

1. **declared extension pods** in `kamiwaza-extensions`, matched by label
   `extensions.kamiwaza.io/deployment-id` (`Exists`)
2. **spawned sandbox pods** in `kamiwaza-sandboxes`, matched by label
   `kamiwaza.io/sandbox=true`

Into each matched pod it injects, **idempotently**:

- a `kamiwaza-trust-bundle` volume sourcing ConfigMap `kamiwaza-trust-bundle`
  (key `ca-certificates.crt`, **`optional: true`**), added only if absent
- a **read-only subPath volumeMount** of that key at
  `/etc/ssl/certs/ca-certificates.crt` on **every** container, added only if absent
- the CA env vars `SSL_CERT_FILE`, `REQUESTS_CA_BUNDLE`, `AWS_CA_BUNDLE`,
  `NODE_EXTRA_CA_CERTS` pointing at that path — each added **only if the container does
  not already set it** (never overrides the image's own value)

**Why the env vars, not just the mount.** Replacing
`/etc/ssl/certs/ca-certificates.crt` covers code that reads the OS trust store, but
Python `requests`/`httpx` use `certifi` and Node uses its own bundled CAs — they only
pick up the corporate CA via `REQUESTS_CA_BUNDLE` / `SSL_CERT_FILE` /
`NODE_EXTRA_CA_CERTS`. The env is **load-bearing for real extension runtimes**, not
cosmetic. The mount covers OS-trust-store consumers; the env covers the language
runtimes. The verified shared `sandbox_controller` (used by the Kaizen app **and** the
mcp-guard tool) labels every sandbox `kamiwaza.io/sandbox=true` in `kamiwaza-sandboxes`,
and declared pods carry `extensions.kamiwaza.io/deployment-id` — so both rules fire
without any extension-specific wiring.

The webhook is pure Python standard library (an `AdmissionReview` handler), runs on an
**in-cluster python image auto-detected from `core-scheduler`**, with the server code in
a ConfigMap and a long-lived self-signed serving cert that is **reused across re-runs**
(stable `caBundle`; the pod only rolls when the code-sha / cert-sha annotations change).
`failurePolicy: Ignore` means a webhook outage degrades to "pod without injected trust"
(prior behavior) and **never blocks pod creation**.

## What it covers

| Pod                                                              | Namespace             | Matched by                                              | Injected                                 |
| ---------------------------------------------------------------- | --------------------- | ------------------------------------------------------- | ---------------------------------------- |
| Declared extension pods (apps, tools, MCP servers)               | `kamiwaza-extensions` | label `extensions.kamiwaza.io/deployment-id` (`Exists`) | mount + CA env (only-if-absent)          |
| Spawned sandbox pods (Kaizen and any sandbox-spawning extension) | `kamiwaza-sandboxes`  | label `kamiwaza.io/sandbox=true`                        | mount + CA env (only-if-absent)          |
| Everything else (operator, core, Ray, infra, unlabeled pods)     | any                   | —                                                       | **not touched** — safe for platform pods |

## Prerequisite

The `kamiwaza-trust-bundle` ConfigMap must exist in the **watched namespaces**. The
injected volume is `optional: true`, so without the ConfigMap a matched pod comes up with
**no CA file, silently**. Build it (additive: Mozilla set + platform `root-ca` + your
corporate CA) with the parent packet's script, writing all of `kamiwaza` /
`kamiwaza-system` / `kamiwaza-extensions` / `kamiwaza-sandboxes`:

```bash
security/tls-trust/build-trust-bundle-configmap.sh \
  --ca-file /path/to/root+intermediate.pem \
  --include-sandboxes
```

> `--ca-file` is optional if you already created the `kamiwaza-org-ca` Secret per the
> parent packet — omit it and the build script reads that Secret. `--include-sandboxes`
> is what writes the bundle into `kamiwaza-sandboxes`.

## Deploy

```bash
# Deploy (auto-detects a python runner image from core-scheduler)
./deploy-extension-trust-webhook.sh

# Pin the runner image instead of auto-detecting
./deploy-extension-trust-webhook.sh --image <python-image-ref>

# Tear everything down
./deploy-extension-trust-webhook.sh --delete
```

[`deploy-extension-trust-webhook.sh`](deploy-extension-trust-webhook.sh) is the source of
truth for flags and behavior. Re-running it is **idempotent** — the serving cert and
`caBundle` are reused, and the webhook pod only rolls when the code or cert sha changes.

| Flag / env          | Default                                                              | Purpose                                                                                    |
| ------------------- | -------------------------------------------------------------------- | ------------------------------------------------------------------------------------------ |
| `--image <ref>`     | auto-detect from `core-scheduler`                                    | pin the in-cluster python runner image                                                     |
| `--webhook-ns`      | `kamiwaza-system`                                                    | namespace the webhook runs in (see gotcha below)                                           |
| `--ext-ns`          | `kamiwaza-extensions`                                                | namespace of declared extension service pods                                               |
| `--sandbox-ns`      | `kamiwaza-sandboxes`                                                 | namespace of spawned sandbox pods                                                          |
| `--delete`          | —                                                                    | tear down the webhook + its `MutatingWebhookConfiguration`                                 |
| `CA_ENV_VARS` (env) | `SSL_CERT_FILE,REQUESTS_CA_BUNDLE,AWS_CA_BUNDLE,NODE_EXTRA_CA_CERTS` | comma-separated env names to set (only-if-absent); set `CA_ENV_VARS=""` for **mount-only** |

> **Run the webhook in `kamiwaza-system`, NOT in an extension namespace.** > `kamiwaza-extensions` has a default-deny-style Ingress NetworkPolicy (empty
> `podSelector`) that blocks the API server from reaching a webhook deployed there. With
> `failurePolicy: Ignore`, that failure is **silent** — pods are admitted with **no
> injection** and you get no error. `kamiwaza-system` is permissive (no NetworkPolicies),
> so the API server can reach the webhook. The default `--webhook-ns` is already
> `kamiwaza-system`; only change it to another namespace the API server can reach.

## Verify

The webhook only mutates **NEW** pods, so roll or recreate a pod to see injection:

```bash
# Roll an existing declared extension Deployment (or just recreate a pod), then inspect it.
# For Kaizen, opening or RESUMING a conversation spawns a fresh sandbox pod.
kubectl -n kamiwaza-extensions get pod <pod> \
  -o jsonpath='{range .spec.containers[*].volumeMounts[*]}{.mountPath}{"\n"}{end}' \
  | grep ca-certificates

# Confirm the CA env landed on a container (declared pod or sandbox pod):
kubectl -n kamiwaza-extensions get pod <pod> \
  -o jsonpath='{.spec.containers[0].env}' | tr ',' '\n' | grep -E 'SSL_CERT_FILE|REQUESTS_CA_BUNDLE|AWS_CA_BUNDLE|NODE_EXTRA_CA_CERTS'
```

For the **Kaizen sandbox** path specifically — the structural checks **plus** the live
TLS probe that is the only real proof of corporate-CA trust — run
[`../verify-kaizen.sh`](../verify-kaizen.sh):

```bash
../verify-kaizen.sh <extension-name> https://<corp-ca-endpoint>
```

> **Structural checks alone do not prove corporate-CA trust.** An extension or agent
> image may already ship a full CA bundle (Mozilla set + a Traefik leaf it installs), so
> the mount + env can be present without your corporate CA being trusted. Only a **live
> TLS probe to a corporate-CA-signed endpoint with verification ON** proves it. Always
> pass a `https://<corp-ca-endpoint>` URL.

**Validated live:** a declared extension pod (label `extensions.kamiwaza.io/deployment-id`)
received the mount + all 4 CA env vars; a sandbox pod (label `kamiwaza.io/sandbox=true`)
received the mount + env and a verify-**ON** `httpsGET` to a demo-CA-signed endpoint
returned **200**; a pod **without** an extension label was untouched (operator/infra
safe); re-running the deploy script was idempotent.

## Caveats

> **`failurePolicy: Ignore` — safe degradation, never blocks.** A webhook outage (or a
> namespace the API server can't reach) silently falls back to "pod without injected
> trust." That is the intended fail-open behavior — it never blocks pod creation — but it
> also means a misconfigured webhook fails **silently**, so verify after deploying.

> **NEW pods only.** Existing pods keep their old spec. Roll the Deployment, recreate the
> pod, or (for sandboxes) open/resume a conversation so a fresh pod is admitted through
> the webhook.

> **Env injected only-if-absent.** If an image already sets `SSL_CERT_FILE` (etc.), the
> webhook leaves it alone — it never overrides the image's own value. The mount is also
> only-if-absent.

> **Mount-over `/etc/ssl/certs/ca-certificates.crt` (read-only).** An agent's runtime
> `update-ca-certificates` Traefik-leaf re-merge is shadowed by the read-only mount.
> Corporate-CA trust still works — the corporate CA is _in_ the bundle, the platform
> `root-ca` in the bundle covers Traefik via chain, and in-cluster MCP is HTTP — so this
> is acceptable. For mount-only behavior (no env), deploy with `CA_ENV_VARS=""`.

> **Hostname validation is orthogonal.** CA trust ≠ hostname match. An IP-literal or
> wrong-host HTTPS URL still fails verification after injection (same as the parent
> packet's hostname caveat) — first `unknown CA`, then, once the CA is trusted,
> `IP address mismatch`. See the hostname section in [`../README.md`](../README.md).

> **The webhook must run in a namespace the API server can reach.** See the
> `kamiwaza-system` blockquote under [Deploy](#deploy).

## Teardown

```bash
./deploy-extension-trust-webhook.sh --delete
```

Removes the `MutatingWebhookConfiguration` and the webhook Deployment / Service /
ConfigMap / Secret. Pods admitted while the webhook was active keep their injected mount

- env until they respawn; the bundle volume is `optional`, so even after teardown those
  pods are fine.

## Files

| File                                                                     | Purpose                                                                                                                                                                                                                                |
| ------------------------------------------------------------------------ | -------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| [`deploy-extension-trust-webhook.sh`](deploy-extension-trust-webhook.sh) | Generates the self-signed serving cert and deploys everything (Secret, ConfigMap, Deployment, Service, `MutatingWebhookConfiguration` with both rules). Idempotent; `--delete` tears down. **Source of truth for flags and behavior.** |
| [`extension-trust-webhook.py`](extension-trust-webhook.py)               | The webhook server: a Python stdlib `AdmissionReview` handler that builds the idempotent JSONPatch (mount + only-if-absent CA env). Pure function `build_patch` is unit-testable without a cluster.                                    |
| [`README.md`](README.md)                                                 | This guide.                                                                                                                                                                                                                            |

## Durable platform fix

Same theme as the parent extensions [`../README.md`](../README.md) "durable fix" section:
the clean long-term answer is **platform-side** — the extension operator and
sandbox-controller should propagate the `kamiwaza-trust-bundle` mount + CA env into
extension service pods and the spawned-sandbox template natively, gated by a value
(mirroring the core `trustManager.enabled` pattern). That is declarative end-to-end but
requires changes to the platform charts and the operator / sandbox-controller images,
which live outside this examples repo. **In-repo, this webhook is the durable interim**:
it closes both boundaries (declared pods + sandboxes) for every extension without
per-extension patching and survives redeploys.
