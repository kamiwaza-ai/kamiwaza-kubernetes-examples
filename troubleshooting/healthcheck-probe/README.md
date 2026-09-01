# Healthcheck probe kills a healthy container

**Scenario:** a pod logs that it started successfully (e.g. `✓ Ready`) but Kubernetes
keeps restarting it into `CrashLoopBackOff`. The container's last state is
**Exit Code 0 / Reason: Completed** — it did not crash, the **kubelet killed it**
because a startup/liveness/readiness probe failed. The usual culprit is a probe that
checks the wrong path, port, or scheme, or one tuned too aggressively for the app's
cold-start time.

This is the "probe kill" branch of crashloop triage — start from
[`../diagnostic-commands/`](../diagnostic-commands/) if you have not narrowed it down yet.

**Tags:** #troubleshooting #probes #healthcheck #crashloop #extensions

---

## Fingerprint — is this actually a probe kill?

```bash
kubectl -n <ns> describe pod <pod>
```

You are in this playbook if you see **all** of:

- `Last State: Terminated`, **`Exit Code: 0`**, `Reason: Completed`
- Events: `Unhealthy: <Startup|Liveness|Readiness> probe failed` → `Killing: ... will be restarted`
- The container's own logs show it came up fine (`kubectl logs <pod>` → server "ready/listening")

If the exit code is non-zero, or logs show a stack trace, this is an app/config crash, not a
probe kill — triage it with [`../diagnostic-commands/`](../diagnostic-commands/) instead.

---

## Step 1 — read the exact probe definition

```bash
kubectl -n <ns> get pod <pod> -o jsonpath='{range .spec.containers[*]}{.name}:
  startup={.startupProbe}
  liveness={.livenessProbe}
  readiness={.readinessProbe}
{"\n"}{end}'
```

Note the **command/path/port** and the **timing fields**:
`initialDelaySeconds`, `periodSeconds`, `timeoutSeconds`, `failureThreshold`.
A `failureThreshold: 1` startup probe with a short delay kills the container on the
**first** miss — no retries, no grace for a slow cold start.

---

## Step 2 — reproduce the probe by hand (the decisive step)

Probes run *inside* the container. Reproduce the exact check during a `Running` window.
If the pod is in a 5-minute backoff, force a fresh start first:

```bash
kubectl -n <ns> delete pod <pod>          # the controller recreates it immediately
```

Then, while it is `Running` (you have ~`initialDelaySeconds` before the kill):

**`exec` probe** — run the command and read its exit code:

```bash
kubectl -n <ns> exec <pod> -c <container> -- <the exact probe command>
echo "exit=$?"     # non-zero = why the kubelet kills it
```

**`httpGet` probe** — curl/fetch the path the probe uses, from inside the pod:

```bash
kubectl -n <ns> exec <pod> -c <container> -- \
  node -e 'fetch("http://127.0.0.1:<port><path>").then(r=>{console.log(r.status);process.exit(0)}).catch(e=>{console.log("ERR",e.message);process.exit(0)})'
# or, if the image has curl:
kubectl -n <ns> exec <pod> -c <container> -- curl -sS -o /dev/null -w '%{http_code}\n' http://127.0.0.1:<port><path>
```

A `404`/`000`/connection-refused here is your answer: the probe targets something the
app doesn't serve.

---

## Step 3 — find what the app *does* serve

Probe the likely real endpoints to find the one that returns `2xx`:

```bash
for p in /health /healthz /ready / /<basePath>/health; do
  code=$(kubectl -n <ns> exec <pod> -c <container> -- \
    node -e "fetch('http://127.0.0.1:<port>$p').then(r=>{console.log(r.status);process.exit(0)}).catch(()=>{console.log('ERR');process.exit(0)})")
  echo "$p -> $code"
done
```

> **Most common root cause: a basePath mismatch.** An app served under a path prefix
> (Next.js `basePath`, a sub-route ingress, etc.) serves `/<prefix>/health`, not
> `/health`. The probe baked into the image assumes `/health` and gets a `404`.

---

## The two failure classes and their fixes

| Class | Tell | Fix surface |
| --- | --- | --- |
| **Wrong target** (path/port/scheme) | hand-run probe returns 404/refused; a different path returns 200 | point the probe at the correct path/port |
| **Too aggressive** (cold start) | hand-run probe returns 200 when run late, but the app needs > the probe's grace to first respond | raise `failureThreshold` / `initialDelaySeconds` / add `startPeriod` |

---

## Fixing it — pick the surface that owns the probe

A probe is rendered from somewhere. Patch the **owner**, not the live Deployment, or
your change is reverted on the next reconcile.

### A. Kamiwaza extension (operator-owned)

Extension pods (`kamiwaza-extensions` ns, managed by `kamiwaza-extension-operator`)
get their probes from the `KamiwazaExtension` CR's `services[].healthCheck`. Editing the
Deployment directly is futile — the operator re-renders it. Patch the CR:

```bash
# services is an ordered list; confirm the index/name first
kubectl -n kamiwaza-extensions get kamiwazaextension <cr> \
  -o jsonpath='{range .spec.services[*]}{.name}{"\n"}{end}'

# guarded JSON patch (test the name at the index you target)
kubectl -n kamiwaza-extensions patch kamiwazaextension <cr> --type=json -p '[
  {"op":"test","path":"/spec/services/<i>/name","value":"frontend"},
  {"op":"replace","path":"/spec/services/<i>/healthCheck/exec/command",
   "value":["node","-e","fetch(\"http://127.0.0.1:3000/<basePath>/health\").then(r=>process.exit(r.ok?0:1)).catch(()=>process.exit(1))"]}
]'
```

The `healthCheck` schema also supports `httpGet` (`path`, `port`, `scheme`, `httpHeaders`)
and `tcpSocket`, plus `initialDelaySeconds` / `periodSeconds` / `timeoutSeconds` /
`startPeriod` / `failureThreshold`. Prefer `httpGet` with an explicit `path` when the
image's baked-in `exec` script hard-codes the wrong route:

```bash
kubectl -n kamiwaza-extensions patch kamiwazaextension <cr> --type=json -p '[
  {"op":"test","path":"/spec/services/<i>/name","value":"frontend"},
  {"op":"replace","path":"/spec/services/<i>/healthCheck/httpGet",
   "value":{"path":"/<basePath>/health","port":3000}},
  {"op":"replace","path":"/spec/services/<i>/healthCheck/failureThreshold","value":3}
]'
```

### B. Helm-deployed service (chart-owned)

Set the probe in values and re-sync — never `kubectl edit` the Deployment:

```yaml
<component>:
  livenessProbe:
    httpGet: { path: /<basePath>/health, port: http }
    initialDelaySeconds: 15
    failureThreshold: 3
  readinessProbe:
    httpGet: { path: /<basePath>/health, port: http }
```

```bash
helmfile -f cluster/helmfile.yaml.gotmpl -e <env> sync
```

### C. Plain Deployment you own

Edit the manifest in source and re-apply (`kubectl apply -f`), or
`kubectl patch deploy <dep> --type=json` if there is no GitOps owner that would revert it.

---

## Verify the fix

```bash
# 1. the OWNER now carries the corrected probe (extension example):
kubectl -n kamiwaza-extensions get deploy <cr>-<svc> \
  -o jsonpath='{.spec.template.spec.containers[0].startupProbe}{"\n"}'

# 2. a fresh pod goes Ready and STAYS at 0 restarts:
kubectl -n <ns> get pods -l <selector> -w     # Ctrl-C once Ready 1/1

# 3. (extensions) the CR reports healthy:
kubectl -n kamiwaza-extensions get kamiwazaextension <cr> \
  -o jsonpath='phase={.status.phase} {range .status.services[*]}{.name}=ready:{.ready} {end}{"\n"}'
# expect: phase=Running ... <svc>=ready:true
```

**Pass:** new pod is `1/1 Running` with `restartCount: 0`, the old crashlooping
ReplicaSet scales to 0, and (for extensions) the CR is `phase: Running`, all services
`ready: true`.

---

## Worked example — workroom-manager frontend (basePath 404)

A real case from this platform:

- **Symptom:** `workroom-manager-...-frontend` in `CrashLoopBackOff`; backend healthy
  (`1/2 services ready`); pod logs `▲ Next.js ✓ Ready in 50ms`; last state Exit 0 / Completed.
- **Probe:** startup `exec [node /app/healthcheck.mjs]`, `failureThreshold: 1`.
- **Reproduced:** `node /app/healthcheck.mjs` → exit 1. The script fetched
  `http://127.0.0.1:3000/health`.
- **Found:** app uses `basePath=/workrooms` (`KAMIWAZA_APP_PATH=/workrooms`), so
  `/health` → **404** but `/workrooms/health` → **200**.
- **Fixed:** patched the `KamiwazaExtension` CR's `services[frontend].healthCheck.exec.command`
  to fetch `/workrooms/health`. Operator re-rendered the Deployment; new pod went
  `1/1 Running`, 0 restarts; CR `phase: Running`, `2/2 services ready`.

The fix belongs upstream too: the image's baked-in `/app/healthcheck.mjs` should honor
the app's basePath rather than assuming `/health`. The CR patch is the in-cluster
remediation; the durable fix is in the extension image.

---

## Related

- [`../diagnostic-commands/`](../diagnostic-commands/) — the general triage this branches off.
- [`../../operations/apply-overrides-reinstall/`](../../operations/apply-overrides-reinstall/) — apply config changes (overrides) and roll workloads safely.
- [`../../security/tls-trust/extensions/`](../../security/tls-trust/extensions/) — extension trust/egress patterns.
