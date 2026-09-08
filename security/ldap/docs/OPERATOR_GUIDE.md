# LDAP + Keycloak federation — operator guide

This document is the **hands-on runbook** for the `security/ldap` example. Start with the scenario **[README.md](../README.md)** for a one-page overview, then use this guide for step-by-step operations.

**All paths** below are relative to the scenario root **`security/ldap/`** (the directory that contains `kustomization.yaml`).

---

## 1. How this scenario is organized (design)

| Layer                    | Directory                                                      | What operators should know                                                                                                                                                                                                     |
| ------------------------ | -------------------------------------------------------------- | ------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------ |
| **Kubernetes manifests** | `namespace.yaml`, `openldap/`, `jobs/`                         | What `kubectl apply -k .` applies: the lab directory, its content, and the bootstrap Job. Images are pinned by digest.                                                                                                         |
| **Administrator policy** | `auth-profile-fragment.yaml`, `transport-policy-fragment.yaml` | The auth profile and the egress destination an operator-managed platform uses for a directory the customer owns. Two files because they merge into different sections of the policy document, and each is separately loadable. |
| **LDAP sample LDIF**     | `ldap-samples/`                                                | Optional files you apply yourself with `ldapadd` / `ldapmodify`. Not mounted by default, and no passwords in them.                                                                                                             |
| **Keycloak automation**  | `keycloak-federation/`                                         | Versioned JSON and shell scripts that call the Keycloak Admin API from a workstation.                                                                                                                                          |

**Why split `ldap-samples/` from `keycloak-federation/`?**
Operators think in two systems: the **directory** and the **identity provider**. Keeping Keycloak JSON out of `openldap/` matches that split, and matches the production one — directory team and platform team.

---

## 2. Architecture (mental model)

```text
Browser → Kamiwaza UI / API
            ↓ OIDC
         Keycloak (realm: kamiwaza)
            ↓ read-only user federation
         Directory (lab: namespace ldap)
```

- **Kamiwaza never talks to the directory**; Keycloak does.
- **Groups** in the directory (`user`, `admin`) map to **realm roles**, so tokens carry roles the auth gateway understands. Authorization past that point is ReBAC.
- The federation **reads**. It creates nothing in the directory and writes nothing back.

---

## 3. Lab constants (change for production)

| Item               | Lab value                                                    |
| ------------------ | ------------------------------------------------------------ |
| Directory Service  | `openldap.ldap.svc.cluster.local.:389` (plaintext, lab only) |
| Base DN            | `dc=kamiwaza,dc=local`                                       |
| Federation bind DN | `cn=federation-reader,ou=services,dc=kamiwaza,dc=local`      |
| Keycloak realm     | `kamiwaza`                                                   |
| Demo users         | `alice` (admin+user), `bob`, `carol`                         |
| Passwords          | generated into `local-secrets/`; nothing committed           |
| Addresses          | `*@users.example.invalid` (reserved, non-resolvable)         |

---

## 4. Credentials

Four values are generated locally, and Git ignores the directory that holds them:

```bash
mkdir -p local-secrets
for name in admin-password config-password federation-bind-password demo-user-password; do
  openssl rand -hex 32 > "local-secrets/${name}"
done
```

Kustomize turns them into Secret `openldap-secret` in namespace `ldap`:

| Key                        | Used by                                                          |
| -------------------------- | ---------------------------------------------------------------- |
| `admin-password`           | the directory manager; the bootstrap Job imports content with it |
| `config-password`          | granting the read-only account its read access, once             |
| `federation-bind-password` | the federation bind account, and nothing else                    |
| `demo-user-password`       | the three lab users                                              |

Rotation is a re-run: write a new value into `local-secrets/`, re-apply, and delete the completed Job so it runs again. The Job sets the credentials on every run, so a rotated Secret takes effect rather than leaving the directory on a stale password.

---

## 5. Bootstrap Job

`ldap-bootstrap-import` is the only writer of the directory tree. It:

1. waits for the directory to answer;
2. imports `openldap-bootstrap` (the tree, `ou=services`, three users, two groups) — idempotently, so an existing entry is skipped;
3. creates `cn=federation-reader,ou=services,…`;
4. grants that account **read** on the base DN, inserted ahead of the shipped catch-all rule. The password rule already ahead of it keeps `userPassword` unreadable, so the federation reads accounts and never their password hashes;
5. sets the federation and lab-user credentials from the Secret; and
6. **proves** the account can read the user branch and cannot write to it. If a write succeeds, the Job fails instead of reporting a read-only federation it does not have.

```bash
kubectl -n ldap wait --for=condition=complete job/ldap-bootstrap-import --timeout=300s
kubectl -n ldap logs job/ldap-bootstrap-import
```

To re-run: `kubectl -n ldap delete job ldap-bootstrap-import` then `kubectl apply -k .`.

Optional richer content lives in `ldap-samples/bootstrap.ldif` (`title`, `manager`, …). Apply it before the Job, or on a fresh directory, because `ldapadd -c` skips DNs that already exist. Set any password it needs afterwards with `ldappasswd`, which prompts.

---

## 6. Keycloak federation

### 6a. From your workstation

```bash
cd keycloak-federation
chmod +x apply-keycloak-ldap.sh validate-keycloak-ldap.sh revert-keycloak-ldap.sh
./apply-keycloak-ldap.sh
```

`KEYCLOAK_ADMIN_PASSWORD` comes from Secret `kamiwaza/keycloak-admin` and `LDAP_BIND_PASSWORD` from Secret `ldap/openldap-secret` key `federation-bind-password` when `kubectl` is available; export either to override. If `curl` cannot verify TLS for a local development hostname, `KEYCLOAK_INSECURE_TLS=1` — development only.

### 6b. Admin Console parity

Add provider **Enterprise LDAP** and mirror the URL, bind DN, users DN, and object classes from `ldap-provider.json`. Keep **Edit mode** on `READ_ONLY` and **Sync registrations** off. Use **Test connection** and **Test authentication** before saving.

---

## 7. Mapping summary

| Directory                                           | Keycloak                                                                         |
| --------------------------------------------------- | -------------------------------------------------------------------------------- |
| `uid`                                               | username                                                                         |
| `mail`                                              | `email`                                                                          |
| `givenName`                                         | `firstName`                                                                      |
| `sn`                                                | `lastName`                                                                       |
| Groups under `ou=groups` (`groupOfNames`, `member`) | Imported groups; `user` / `admin` mapped to realm roles **`user`** / **`admin`** |

No mapper assigns a group, role, or tenant the directory does not state. A user who is in no directory group arrives with no group, which is the directory's answer rather than a default this example invents.

---

## 8. Sync, login test, validate

1. Keycloak: **User federation → Enterprise LDAP → Synchronize all users**.
2. Confirm **`alice`** exists and is linked to the federation.
3. Log in through Keycloak as **`alice`** with the generated `demo-user-password`.
4. Decode the token: `realm_access.roles` should include **`user`** and **`admin`**.

```bash
cd keycloak-federation && ./validate-keycloak-ldap.sh
```

`validate-keycloak-ldap.sh` checks that the live provider still reports `editMode: READ_ONLY`, `syncRegistrations: false`, and the read-only bind account — a configuration that drifted in the Admin Console is caught here.

---

## 9. Adding users (`ldap-samples/user-template.ldif`)

1. Copy **`user-template.ldif`** and replace the placeholders.
2. Omit the **`demo-engineering`** block unless that group already exists.
3. Apply with **`ldapmodify`** as the directory manager, then set the password with `ldappasswd`:

```bash
POD="$(kubectl get pod -n ldap -l app=openldap -o jsonpath='{.items[0].metadata.name}')"
kubectl cp MY.ldif "ldap/${POD}:/tmp/MY.ldif"
kubectl -n ldap get secret openldap-secret -o jsonpath='{.data.admin-password}' | base64 -d |
  kubectl -n ldap exec -i "$POD" -- sh -lc 'read -r pw
    ldapmodify -x -c -H ldap://127.0.0.1:389 \
      -D "cn=admin,dc=kamiwaza,dc=local" -w "$pw" -f /tmp/MY.ldif'
kubectl -n ldap exec -it "$POD" -- ldappasswd -x -W -H ldap://127.0.0.1:389 \
  -D "cn=admin,dc=kamiwaza,dc=local" -S "uid=<uid>,ou=people,dc=kamiwaza,dc=local"
```

The manager credential arrives on standard input, so it stays out of your shell history and the process table. `ldappasswd -W -S` prompts for both passwords rather than taking them as arguments.

Then Keycloak: **Synchronize changed users**.

---

## 10. Production alignment

- `ldaps://`, or `ldap://` with StartTLS required. The lab directory serves neither; see `auth-profile-fragment.yaml` for the shape a real directory takes.
- A read-only bind account, as here, and a credential from your own secret store rather than a local file.
- Declare the directory as a `Directory` egress destination so the platform's policy-aware dialer bounds which host and port the federation may reach.
- Document the synchronization interval and what happens when a person leaves the organisation: with `editMode: READ_ONLY`, the directory is the answer to that question.

---

## 11. Troubleshooting

| Symptom                             | Check                                                                                                                                                                                                                                                 |
| ----------------------------------- | ----------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| Bootstrap Job fails                 | `kubectl logs -n ldap job/ldap-bootstrap-import` — directory readiness, ConfigMap `openldap-bootstrap`, and the four Secret keys.                                                                                                                     |
| Job fails on the read-only proof    | The bind account can write. Check that the access rule inserted at step 4 above was not replaced, and that the account is not the directory manager.                                                                                                  |
| Federation reads nothing            | The bind account has no read access, which the directory reports as `No such object` rather than as a permission error. Delete the completed Job and re-apply so it grants the access again.                                                          |
| `0 users` synced                    | Empty directory, or the users DN and object classes do not match `ldap-provider.json`. `ldapsearch` on `ou=people` as the bind account.                                                                                                               |
| TLS errors from workstation scripts | `KEYCLOAK_INSECURE_TLS=1` (development only) or trust the cluster CA.                                                                                                                                                                                 |
| DNS: FQDNs resolve to the wrong IP  | Clusters whose node search domain has a wildcard record can hijack `*.svc.cluster.local` under the default `ndots:5`. The Job sets `dnsConfig.options: [{name: ndots, value: "1"}]` and the FQDN carries a trailing dot to force absolute resolution. |

---

## 12. Observe Kamiwaza auth (optional)

```bash
kubectl logs -n kamiwaza deployment/core-scheduler --tail=200 | \
  awk '/forwardauth|User headers:|Auth success for user/{print}'
```
