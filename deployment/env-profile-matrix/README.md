# Deploy environment profile matrix (lite/full/dev/dev-full)

**Scenario:** expected behavior for the existing Kamiwaza Deploy Helmfile
environments.

**Tags:** #deployment #topology #profiles #helmfile

## Matrix

| Profile      | Typical command     | Helmfile env | Auth               | Metadata catalog        | Hot reload            | Expected platform shape                     |
| ------------ | ------------------- | ------------ | ------------------ | ----------------------- | --------------------- | ------------------------------------------- |
| **lite**     | `make install-lite` | `lite`       | Disabled           | Built-in (no DataHub)   | No                    | Core + Frontend + Network                    |
| **full**     | `make install`      | `full`       | Enabled (Keycloak) | Built-in (no DataHub)   | No                    | Full platform with Keycloak                 |
| **dev**      | `make dev`          | `dev`        | Disabled           | Built-in (no DataHub)   | Yes (core + frontend) | Lite services with hot-reload mounts        |
| **dev-full** | `make dev-full`     | `dev-full`   | Enabled (Keycloak) | Built-in (no DataHub)   | Yes (core + frontend) | Full platform + Keycloak + hot reload       |

## Expected values layering

These profiles map to Helmfile values composition in Deploy:

| Profile      | Expected values layering                                                    |
| ------------ | --------------------------------------------------------------------------- |
| **lite**     | `kamiwaza-base.yaml` + `kamiwaza-lite.yaml`                                 |
| **full**     | `kamiwaza-base.yaml`                                                        |
| **dev**      | `kamiwaza-base.yaml` + `kamiwaza-lite.yaml` + `kamiwaza-hotreload-k0s.yaml` |
| **dev-full** | `kamiwaza-base.yaml` + `kamiwaza-hotreload-k0s.yaml`                         |

See Deploy `cluster/helmfile.yaml.gotmpl` for the authoritative environment-to-values mapping.

## Quick verification checklist

Render each profile from the Deploy repository before changing a live cluster:

```bash
for profile in lite full dev dev-full; do
  helmfile -f cluster/helmfile.yaml.gotmpl -e "${profile}" \
    -l name=kamiwaza template --skip-deps \
    --output-dir-template "/tmp/kamiwaza-profile-${profile}"
done
```

After installation, verify the selected shape:

```bash
kubectl -n kamiwaza get deployment

# Expected only for full and dev-full.
kubectl -n kamiwaza get deployment keycloak

# Expected value "true" only for dev and dev-full.
kubectl -n kamiwaza get deployment core-scheduler \
  -o jsonpath='{range .spec.template.spec.containers[*].env[?(@.name=="KAMIWAZA_HOT_RELOAD")]}{.value}{"\n"}{end}'
```

DataHub is not shipped in any current profile. `KAMIWAZA_DATAHUB_ENABLED=true`
is rejected by Helmfile instead of silently restoring removed workloads.

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
