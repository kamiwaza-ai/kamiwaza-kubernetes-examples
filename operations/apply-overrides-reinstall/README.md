# Apply config changes, reinstall, and uninstall

**Scenario:** you changed platform configuration (values overrides) and need it live, or
you need to cleanly uninstall and reapply. This is the day-2 lifecycle for the umbrella
`kamiwaza` release and its extensions.

**Tags:** #operations #helmfile #overrides #install #uninstall #day2

---

## How config layering works

The kamiwaza umbrella release is deployed by **helmfile**, which composes values files in
order; the last layer wins. The operator-managed override file is
`cluster/values/overrides.yaml` — it is applied **last** (highest precedence) for every
non-`default` environment and is **gitignored**, so it's the safe place for
site-specific changes.

```
kamiwaza-base.yaml / kamiwaza-prod.yaml   (chart + env defaults)
  └── env overlays (lite / hotreload / release ...)
        └── overrides.yaml                 ← your changes go here (wins)
```

Match the **environment** to how the cluster was installed (`full`, `lite`, `release`,
`dev`, `dev-full`). Mismatching the env re-layers different value files and can add or
remove services (e.g. `lite` drops auth + datahub).

---

## Apply a values change (overrides → sync)

```bash
# 1. Edit the highest-precedence override file
$EDITOR cluster/values/overrides.yaml

# 2. Re-sync ONLY the umbrella release (fast; leaves infra releases alone)
helmfile -f cluster/helmfile.yaml.gotmpl -e <env> -l name=kamiwaza sync

# 3. Wait for the workloads your change touched to roll
kubectl -n kamiwaza rollout status deploy/core-scheduler
```

> **Match the install env.** If you brought the cluster up with `make install` it is the
> `full` env; `make install-lite` is `lite`; release installs are `release`. On Kind,
> set `KAMIWAZA_K8S_RUNTIME=kind` so the small-resource profile is layered the same way
> the installer did:
> ```bash
> KAMIWAZA_K8S_RUNTIME=kind helmfile -f cluster/helmfile.yaml.gotmpl -e full -l name=kamiwaza sync
> ```

> **Preview before applying (optional).** With the `helm-diff` plugin installed:
> ```bash
> helm plugin install https://github.com/databus23/helm-diff   # one-time
> helmfile -f cluster/helmfile.yaml.gotmpl -e <env> -l name=kamiwaza diff
> ```
> Without the plugin, `helmfile ... diff` fails with `unknown command "diff" for "helm"` —
> that's a missing plugin, not a config error.

A `sync` of an unchanged release is a no-op, so re-running is safe.

---

## Roll a workload without a values change

When the change is in a Secret/ConfigMap the pod reads at startup, or you just need a
fresh pull (`pullPolicy: Always`), roll the Deployment instead of re-syncing:

```bash
kubectl -n kamiwaza rollout restart deploy/<name>
kubectl -n kamiwaza rollout status  deploy/<name>
```

Bundles mounted with `subPath` (e.g. a trust bundle) do **not** hot-update in running
pods — a roll is required to pick them up.

---

## Reinstall (clean redeploy, keep the cluster)

```bash
make reinstall          # uninstall + reinstall the platform on the existing Kind cluster
```

Stateful PVCs (Postgres, OpenSearch, Neo4j, etc.) survive a reinstall as long as the
cluster and their PVCs exist.

---

## Uninstall

### Just the umbrella release

```bash
helm -n kamiwaza uninstall kamiwaza
# PVCs are retained by default; delete them explicitly if you want a clean slate:
kubectl -n kamiwaza get pvc
# kubectl -n kamiwaza delete pvc <name>      # destructive — data loss
```

### The whole cluster

```bash
make clean              # delete the Kind cluster (everything goes)
```

### An out-of-band add-on (e.g. trust-manager)

Add-ons you installed directly with Helm are uninstalled the same way:

```bash
helm -n cert-manager uninstall trust-manager
```

---

## Extensions are a separate lifecycle

Extension workloads (`kamiwaza-extensions` ns) are **not** part of the helmfile release —
they are reconciled by the `kamiwaza-extension-operator` from `KamiwazaExtension` CRs.
To change an extension's config, patch its CR (the operator re-renders the Deployment;
editing the Deployment directly is reverted):

```bash
kubectl -n kamiwaza-extensions patch kamiwazaextension <cr> --type=json -p '[ ... ]'
kubectl -n kamiwaza-extensions get kamiwazaextension <cr> \
  -o jsonpath='phase={.status.phase}{"\n"}'
```

See [`../../troubleshooting/healthcheck-probe/`](../../troubleshooting/healthcheck-probe/)
for a worked CR-patch example.

---

## Verify

```bash
helm -n kamiwaza list                                   # release deployed, revision bumped
kubectl -n kamiwaza get pods                            # workloads Running / Ready
kubectl -n kamiwaza rollout status deploy/core-scheduler
```

**Pass:** the release shows a new `REVISION`, the workloads your change touched rolled to
`Ready`, and nothing unrelated was disturbed.

---

## Related

- [`../cluster-scaling-maxpods/`](../cluster-scaling-maxpods/) — raise the Kind pod ceiling.
- [`../credential-rotation/`](../credential-rotation/) — rotate registry credentials.
- [`../../security/tls-trust/`](../../security/tls-trust/) — a real overrides-driven change (custom CA trust) end to end.
- [`../../troubleshooting/healthcheck-probe/`](../../troubleshooting/healthcheck-probe/) — fix a probe that crashloops a healthy pod.
