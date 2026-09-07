# Keycloak declarative LDAP federation (lab)

Scripts and JSON that apply **read-only** directory federation to Keycloak. Run them from a workstation with `curl`, `jq`, and `kubectl` against `KEYCLOAK_URL`; see **`../docs/OPERATOR_GUIDE.md` §5**.

There is no in-cluster Job for this any more. The Job that used to run it installed its tooling from the internet at container start, so nothing about it could be pinned.

| File                                 | Role                                                                           |
| ------------------------------------ | ------------------------------------------------------------------------------ |
| **`manifest.json`**                  | Realm, provider, mapper files, group→role mappings, sync options               |
| **`ldap-provider.json`**             | User federation provider payload: `READ_ONLY`, no registrations, reader bindDn |
| **`mappers/*.json`**                 | Attribute and group mappers                                                    |
| **`keycloak-declarative-common.sh`** | Shared REST helpers                                                            |
| **`apply-keycloak-ldap.sh`**         | Create or update provider, mappers, group role mappings, then sync             |
| **`validate-keycloak-ldap.sh`**      | Checks the provider is read-only and the federated user arrived                |
| **`revert-keycloak-ldap.sh`**        | Remove the federation (lab teardown)                                           |

The bind credential is never written into these files. `apply-keycloak-ldap.sh` reads `LDAP_BIND_PASSWORD`, and fills it from Secret `openldap-secret` key `federation-bind-password` when `kubectl` is available — the read-only federation account, never the directory manager.

Treat the DNs and URLs here as a **pattern**, not a configuration: align them, the transport, and the credential storage with your own directory and identity policy. `auth-profile-fragment.yaml` in the scenario root is the shape that policy takes for an operator-managed platform.
