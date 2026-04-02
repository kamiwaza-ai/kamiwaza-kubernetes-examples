# Keycloak declarative LDAP federation (lab)

Scripts and JSON consumed by:

1. **`kubectl apply -k ..`** — Kustomize packs this directory into ConfigMap `keycloak-declarative-bundle` and Job `keycloak-ldap-federation-apply` runs **`apply-keycloak-ldap.sh`** in-cluster.
2. **Your laptop** — same scripts against `KEYCLOAK_URL` (teaching / iteration); see **`../docs/OPERATOR_GUIDE.md` §5b**.

| File                                 | Role                                                             |
| ------------------------------------ | ---------------------------------------------------------------- |
| **`manifest.json`**                  | Realm, provider, mapper files, group→role mappings, sync options |
| **`ldap-provider.json`**             | User federation provider payload                                 |
| **`mappers/*.json`**                 | Attribute and group mappers                                      |
| **`keycloak-declarative-common.sh`** | Shared REST helpers                                              |
| **`apply-keycloak-ldap.sh`**         | Create/update provider + mappers + sync                          |
| **`validate-keycloak-ldap.sh`**      | Quick checks (LDAP + Keycloak users)                             |
| **`revert-keycloak-ldap.sh`**        | Remove federation (lab teardown)                                 |

Do not copy these paths into production verbatim — treat as a **pattern** and align DNs, TLS, and secrets with your IdP policy.
