# Deploy environment profile matrix (lite/full/dev/dev-full)

**Scenario:** expected behavior for the existing Kamiwaza Deploy Helmfile
environments.

**Tags:** #deployment #topology #profiles #helmfile

## Matrix

| Profile      | Typical command     | Helmfile env | Auth               | DataHub  | Hot reload            | Expected platform shape                 |
| ------------ | ------------------- | ------------ | ------------------ | -------- | --------------------- | --------------------------------------- |
| **lite**     | `make install-lite` | `lite`       | Disabled           | Disabled | No                    | Core + Frontend + Network only          |
| **full**     | `make install`      | `full`       | Enabled (Keycloak) | Enabled  | No                    | Full platform (Auth + DataHub included) |
| **dev**      | `make dev`          | `dev`        | Disabled           | Disabled | Yes (core + frontend) | Lite services with hot-reload mounts    |
| **dev-full** | `make dev-full`     | `dev-full`   | Enabled (Keycloak) | Enabled  | Yes (core + frontend) | Full platform + hot reload              |

## Expected values layering

These profiles map to Helmfile values composition in Deploy:

| Profile      | Expected values layering                                                |
| ------------ | ----------------------------------------------------------------------- |
| **lite**     | `kamiwaza-base.yaml` + `kamiwaza-lite.yaml`                             |
| **full**     | `kamiwaza-base.yaml`                                                    |
| **dev**      | `kamiwaza-base.yaml` + `kamiwaza-lite.yaml` + `kamiwaza-hotreload.yaml` |
| **dev-full** | `kamiwaza-base.yaml` + `kamiwaza-hotreload.yaml`                        |

See Deploy `cluster/helmfile.yaml.gotmpl` for the authoritative environment-to-values mapping.

## Quick verification checklist

```bash
# Release status
helm list -n kamiwaza

# Auth/DataHub workload presence
kubectl -n kamiwaza get deploy | grep -E 'keycloak|datahub|core-scheduler|frontend'

# Hot-reload hint (dev/dev-full): scheduler should carry dev mounts/env from hotreload values
kubectl -n kamiwaza get deploy core-scheduler -o yaml | grep -E 'KAMIWAZA_HOT_RELOAD|extraVolumeMounts|hostPath'
```

## Notes

- `dev` / `dev-full` are for operator/developer iteration; production-like checks should use `full`.
- Local-image variants (`dev-local`, `dev-full-local`) are separate from this matrix and depend on local image builds.

## Platform operator deployment configurations

The current `KamiwazaPlatform` API accepts only `profile: Full`. Do not map
Helmfile `lite`, `dev`, or `dev-full` to undocumented operator profiles.

Use the concrete operator scenarios instead:

| Configuration                                                | Scenario                                                                                              |
| ------------------------------------------------------------ | ----------------------------------------------------------------------------------------------------- |
| Fresh Full platform with a separately placed bounded manager | [`operator/quickstart`](../../operator/quickstart/)                                                   |
| Manager in the platform namespace                            | [`operator/namespace-scopes`](../../operator/namespace-scopes/#same-namespace-manager)                |
| Manager in a separate namespace with an explicit watch list  | [`operator/namespace-scopes`](../../operator/namespace-scopes/#separate-manager-with-bounded-targets) |
| Explicit all-namespace watch authority                       | [`operator/namespace-scopes`](../../operator/namespace-scopes/#all-namespace-watch)                   |
| Shared platform and model with real Tomo tenant isolation    | [`multi-tenancy/tomo-shared-workrooms`](../../multi-tenancy/tomo-shared-workrooms/)                   |

These are lifecycle and authority choices, not application profiles. Every
operator deployment still uses the release-published compatibility artifact,
digest-pinned images, immutable admin policy, and external prerequisites.
