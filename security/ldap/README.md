# LDAP + Keycloak federation

**Scenario:** deploy a lab OpenLDAP server, apply declarative Keycloak federation, and expose LDAP UI for operator learning. Demo users are **`alice`**, **`bob`**, **`carol`** (password **`kamiwaza`** in sample data). Replace all demo values for production.

**Tags:** #security #ldap #keycloak

## Quick start

```bash
# 1) ensure Keycloak is enabled (if your environment is lite)
# merge security/ldap/values-snippet.yaml into deploy cluster values first

# 2) apply LDAP scenario resources
cd kamiwaza-kubernetes-examples/security/ldap
kubectl apply -k .

# 3) validate federation bundle from your workstation (optional)
cd keycloak-federation
./validate-keycloak-ldap.sh
```

## Scenario layout (grouped)

| Group                 | Paths                                                                    | Purpose                                                                      |
| --------------------- | ------------------------------------------------------------------------ | ---------------------------------------------------------------------------- |
| **Manifests**         | `kustomization.yaml`, `namespace.yaml`, `openldap/`, `ldap-ui/`, `jobs/` | Runnable Kubernetes resources (`kubectl apply -k .`)                         |
| **Federation bundle** | `keycloak-federation/`                                                   | Declarative Keycloak LDAP provider + mappers + apply/validate/revert scripts |
| **Sample data**       | `ldap-samples/`                                                          | Optional LDIF data for labs (`bootstrap.ldif`, `user-template.ldif`)         |
| **Runbook**           | `docs/OPERATOR_GUIDE.md`                                                 | Canonical operator narrative and troubleshooting                             |
| **Values snippet**    | `values-snippet.yaml`                                                    | Re-enables auth (Keycloak + core integration) when needed for federation     |

## Prerequisites

- Kamiwaza deployed with Keycloak (or merge `values-snippet.yaml` and re-sync first).
- Secret `keycloak-admin` exists in namespace `kamiwaza`.
- `kubectl` with kustomize support.

## What the jobs do

- `ldap/ldap-bootstrap-import`: imports `openldap-bootstrap` ConfigMap LDIF into OpenLDAP.
- `kamiwaza/keycloak-ldap-federation-apply`: applies files from `keycloak-federation/` into Keycloak.

To rerun either job: delete the completed Job and re-apply `kubectl apply -k .`.

## Verify

```bash
kubectl -n ldap get pods
kubectl -n ldap get jobs
kubectl -n kamiwaza get jobs keycloak-ldap-federation-apply
```

For script-based validation and troubleshooting, use `docs/OPERATOR_GUIDE.md`.

## Notes

- Demo secrets in `openldap/secret.yaml` and `jobs/keycloak-ldap-bind-secret.yaml` intentionally match sample LDIF users; rotate for real environments.
- LDAP UI endpoint: `https://ldap-ui.kamiwaza.test` (with Traefik + local DNS), or use `kubectl port-forward`.
- CAC/client-cert login is documented in `security/cac`, not in this LDAP scenario.
