# Environment profile matrix (lite/full/dev/dev-full)

**Scenario:** operator reference for expected behavior by deployment profile, aligned with Deploy `make` targets and Helmfile environments.

**Tags:** #deployment #topology #profiles #helmfile

## Matrix

| Profile | Typical command | Helmfile env | Auth | DataHub | Hot reload | Expected platform shape |
| --- | --- | --- | --- | --- | --- | --- |
| **lite** | `make install-lite` | `lite` | Disabled | Disabled | No | Core + Frontend + Network only |
| **full** | `make install` | `full` | Enabled (Keycloak) | Enabled | No | Full platform (Auth + DataHub included) |
| **dev** | `make dev` | `dev` | Disabled | Disabled | Yes (core + frontend) | Lite services with hot-reload mounts |
| **dev-full** | `make dev-full` | `dev-full` | Enabled (Keycloak) | Enabled | Yes (core + frontend) | Full platform + hot reload |

## Expected values layering

These profiles map to Helmfile values composition in Deploy:

| Profile | Expected values layering |
| --- | --- |
| **lite** | `kamiwaza-base.yaml` + `kamiwaza-lite.yaml` |
| **full** | `kamiwaza-base.yaml` |
| **dev** | `kamiwaza-base.yaml` + `kamiwaza-lite.yaml` + `kamiwaza-hotreload.yaml` |
| **dev-full** | `kamiwaza-base.yaml` + `kamiwaza-hotreload.yaml` |

See Deploy `cluster/helmfile.yaml.gotmpl` for the authoritative environment-to-values mapping.

## Quick verification checklist

```bash
# Release status
helm list -n kamiwaza

# Auth/DataHub workload presence
kubectl -n kamiwaza get deploy | grep -E 'keycloak|datahub|core-scheduler|frontend'

# Hot-reload hint (dev/dev-full): scheduler should carry dev mounts/env from hotreload values
kubectl -n kamiwaza get deploy core-scheduler -o yaml | grep -E 'extraVolumeMounts|KAMIWAZA_DEBUG|watch|hotreload'
```

## Notes

- `dev` / `dev-full` are for operator/developer iteration; production-like checks should use `full`.
- Local-image variants (`dev-local`, `dev-full-local`) are separate from this matrix and depend on local image builds.
