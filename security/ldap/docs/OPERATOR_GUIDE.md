# LDAP + Keycloak federation — operator guide

This document is the **hands-on runbook** for the `security/ldap` example. Start with the scenario **[README.md](../README.md)** for a one-page overview, then use this guide for step-by-step operations.

**All paths** below are relative to the scenario root **`security/ldap/`** (the directory that contains `kustomization.yaml`).

---

## 1. How this scenario is organized (design)

| Layer                    | Directory                                          | What operators should know                                                                                                                                                                      |
| ------------------------ | -------------------------------------------------- | ----------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| **Kubernetes manifests** | `namespace.yaml`, `openldap/`, `ldap-ui/`, `jobs/` | What gets applied with `kubectl apply -k .`. Nothing here is “sample data scripts” — it is the runnable lab stack.                                                                              |
| **LDAP sample LDIF**     | `ldap-samples/`                                    | Optional files you **apply yourself** with `ldapadd` / `ldapmodify` when teaching or extending the directory. Not mounted by default.                                                           |
| **Keycloak automation**  | `keycloak-federation/`                             | Versioned JSON + shell scripts that call the Keycloak Admin API. A **ConfigMap** is built from here and consumed by the federation **Job**; you can also run the same scripts from your laptop. |

**Why split `ldap-samples/` from `keycloak-federation/`?**  
Operators think in two systems: the **directory** (OpenLDAP) and the **IdP** (Keycloak). Mixing Keycloak JSON under `openldap/` blurred that line. This layout matches mental models and production splits (directory team vs platform team).

---

## 2. Architecture (mental model)

```text
Browser → Kamiwaza UI / API
            ↓ OIDC
         Keycloak (realm: kamiwaza)
            ↓ User Federation (LDAP provider)
         OpenLDAP (namespace: ldap)
```

- **Kamiwaza** never talks to LDAP directly in this pattern; **Keycloak** does.
- **Groups** in LDAP (`user`, `admin`) are mapped to **realm roles** so JWTs work with the auth gateway.

---

## 3. Lab constants (change for production)

| Item           | Lab value                                |
| -------------- | ---------------------------------------- |
| LDAP Service   | `openldap.ldap.svc.cluster.local:389`    |
| Base DN        | `dc=kamiwaza,dc=local`                   |
| Keycloak realm | `kamiwaza`                               |
| Demo users     | `alice` (admin+user), `bob`, `carol`     |
| Demo password  | `kamiwaza` (in committed YAML/LDIF only) |
| Emails         | `*@users.example.invalid`                |

---

## 4. LDAP data: built-in Job vs optional `bootstrap.ldif`

1. **`ldap-bootstrap-import` Job** loads LDIF from the **`openldap-bootstrap`** ConfigMap (minimal users + groups). Enough for federation and UI login tests.

2. **`ldap-samples/bootstrap.ldif`** is an alternative set with richer attributes (`title`, `manager`, …). Use when teaching attribute sync or HR-style entries. **Note:** if the Job already loaded the minimal data, `ldapadd -c` skips existing DNs (same `uid=*` entries already exist). To use this file instead, apply it on a fresh OpenLDAP instance before the Job runs, or delete and recreate the OpenLDAP PVCs first.

Apply optional bootstrap from **`security/ldap`** (admin password from secret; demo default `kamiwaza`):

```bash
POD="$(kubectl get pod -n ldap -l app=openldap -o jsonpath='{.items[0].metadata.name}')"
ADMIN_PW="$(kubectl get secret -n ldap openldap-secret -o jsonpath='{.data.admin-password}' | base64 -d)"
kubectl cp ldap-samples/bootstrap.ldif "ldap/${POD}:/tmp/bootstrap.ldif"
kubectl exec -n ldap "$POD" -- sh -lc \
  "ldapadd -x -c -H ldap://127.0.0.1:389 -D 'cn=admin,dc=kamiwaza,dc=local' -w '${ADMIN_PW}' -f /tmp/bootstrap.ldif; rc=\$?; [ \$rc -eq 68 ] && exit 0; exit \$rc"
```

Verify:

```bash
kubectl exec -n ldap deploy/openldap -- ldapsearch -x \
  -H ldap://127.0.0.1:389 \
  -D "cn=admin,dc=kamiwaza,dc=local" -w kamiwaza \
  -b "dc=kamiwaza,dc=local" "(uid=alice)"
```

---

## 5. Keycloak LDAP federation

### 5a. Automatic (recommended for first success path)

The **`keycloak-ldap-federation-apply`** Job waits for Keycloak, then runs `apply-keycloak-ldap.sh` from the ConfigMap. Ensure the **`keycloak-ldap-bind`** secret matches the OpenLDAP admin password (`jobs/keycloak-ldap-bind-secret.yaml`).

### 5b. From your workstation (teaching / iteration)

```bash
cd keycloak-federation
chmod +x apply-keycloak-ldap.sh validate-keycloak-ldap.sh revert-keycloak-ldap.sh
./apply-keycloak-ldap.sh
```

Artifacts: **`manifest.json`** (orchestrates everything), **`ldap-provider.json`**, **`mappers/*.json`**.

If `curl` fails TLS verification for `https://kamiwaza.test`, set **`KEYCLOAK_INSECURE_TLS=1`** for local dev only.

### 5c. Admin Console parity

Add provider **Enterprise LDAP**; mirror URL, bind DN, user DN, and object classes from **`ldap-provider.json`**. Always use **Test connection** and **Test authentication** before saving.

---

## 6. Mapping summary

| LDAP                                                | Keycloak                                                                         |
| --------------------------------------------------- | -------------------------------------------------------------------------------- |
| `mail`                                              | `email`                                                                          |
| `givenName`                                         | `firstName`                                                                      |
| `sn`                                                | `lastName`                                                                       |
| Groups under `ou=groups` (`groupOfNames`, `member`) | Imported groups; `user` / `admin` mapped to realm roles **`user`** / **`admin`** |

---

## 7. Sync, login test, validate

1. Keycloak: **User federation → Enterprise LDAP → Synchronize all users** (if you did not rely on the Job alone).
2. Confirm **`alice`** exists and is linked to LDAP.
3. Log in through Keycloak as **`alice` / `kamiwaza`**.
4. Decode JWT: `realm_access.roles` should include **`user`** and **`admin`**.

```bash
cd keycloak-federation && ./validate-keycloak-ldap.sh
```

---

## 8. Adding users (`ldap-samples/user-template.ldif`)

1. Copy **`user-template.ldif`**, replace `<placeholders>`.
2. Omit the **`demo-engineering`** block unless that group already exists.
3. Apply with **`ldapmodify`**:

```bash
POD="$(kubectl get pod -n ldap -l app=openldap -o jsonpath='{.items[0].metadata.name}')"
ADMIN_PW="$(kubectl get secret -n ldap openldap-secret -o jsonpath='{.data.admin-password}' | base64 -d)"
kubectl cp MY.ldif "ldap/${POD}:/tmp/MY.ldif"
kubectl exec -n ldap "$POD" -- sh -lc \
  "ldapmodify -x -c -H ldap://127.0.0.1:389 -D 'cn=admin,dc=kamiwaza,dc=local' -w '${ADMIN_PW}' -f /tmp/MY.ldif"
```

Then Keycloak: **Synchronize changed users**.

---

## 9. Production alignment

- **`ldaps://`**, dedicated read-only bind, strong passwords, your real base DN.
- Do not commit production secrets; use Sealed Secrets / External Secrets / vault.
- Document sync intervals and what happens when users leave the org.

---

## 10. Troubleshooting

| Symptom                             | Check                                                                                                           |
| ----------------------------------- | --------------------------------------------------------------------------------------------------------------- |
| Federation Job `CrashLoop` / errors | `kubectl logs -n kamiwaza job/keycloak-ldap-federation-apply` — Keycloak URL, admin password, LDAP bind secret. |
| Bootstrap Job fails                 | `kubectl logs -n ldap job/ldap-bootstrap-import` — OpenLDAP readiness, ConfigMap `openldap-bootstrap`.          |
| `0 users` synced                    | LDAP empty or wrong **Users DN** / object classes — `ldapsearch` on `ou=people`.                                |
| TLS errors from laptop scripts      | `KEYCLOAK_INSECURE_TLS=1` (dev only) or trust cluster CA.                                                       |
| UI login fails                      | LDAP UI expects a user in **`admin`** group (demo: **`alice`**), not directory `cn=admin`.                      |
| DNS: FQDNs resolve to wrong IP      | Clusters with wildcard DNS search domains (e.g. `*.example.com`) can hijack `*.svc.cluster.local` under the default `ndots:5`. Job manifests include `dnsConfig.options: [{name: ndots, value: "1"}]` and FQDNs use a trailing dot to force absolute resolution. |

---

## 11. Observe Kamiwaza auth (optional)

```bash
kubectl logs -n kamiwaza deployment/core-scheduler --tail=200 | \
  awk '/forwardauth|User headers:|Auth success for user/{print}'
```
