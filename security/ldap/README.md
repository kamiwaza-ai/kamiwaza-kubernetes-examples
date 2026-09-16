# LDAP + Keycloak federation (read-only)

**Scenario:** federate a directory into Kamiwaza through Keycloak, **read-only**, with a referenced bind credential and every image pinned by digest. A lab directory stands in for the customer-owned one so the federation can be exercised end to end.

**Tags:** #security #ldap #keycloak #read-only #pinned

## What this example restricts itself to

- Read-only federation. `editMode: READ_ONLY` and `syncRegistrations: false`: the platform reads accounts and group membership and writes nothing back. The directory owner retains control. A writable federation can lock out directory users.
- Referenced bind credential. The federation uses `cn=federation-reader,ou=services,…`, not the directory manager. Secret `openldap-secret` key `federation-bind-password` supplies its credential. Directory access control permits user and group reads only. The bootstrap Job fails if it cannot prove read-only access.
- Pinned images. Every image is `docker.io/osixia/openldap:1.5.0@sha256:18742e9c449c9c1afe129d3f2f3ee15fb34cc43e5f940a20f3399728f41d7c28`. The tag identifies the release. The digest selects the image.
- Closed mapper vocabulary. Mappers project directory attributes and group membership onto reviewed claims. They do not invent groups, roles, or tenants. Directory group membership becomes a realm role. ReBAC controls later authorization.
- No credential in Git. Git ignores all passwords in `local-secrets/`. No sample LDIF, ConfigMap, or Secret manifest contains a password or hash.

## What is not here any more

- Directory web UI. It used the directory manager account and had write access to the directory. It also used an unpinned image and patched that image at container start.
- In-cluster federation Job. It installed internet packages at run time. Its dependencies were not pinned. The same declarative bundle now runs from an administrator workstation.

## Prerequisites

- Kamiwaza deployed with Keycloak from your **pinned release chart** (or merge `values-snippet.yaml` and re-sync first). This example pins its own images; it selects no chart version, because the Keycloak your platform runs comes from your release.
- StorageClass `local-path` is installed. Change both PVC manifests before applying when the cluster uses another reviewed class.
- Secret `keycloak-admin` in namespace `kamiwaza`.
- `kubectl` with kustomize support, plus `curl` and `jq` on the workstation that applies the federation.

## Steps

```bash
# 1) generate the lab credentials (Git ignores local-secrets/)
mkdir -p security/ldap/local-secrets
for name in admin-password config-password federation-bind-password demo-user-password; do
  openssl rand -hex 32 | tr -d '\n' > "security/ldap/local-secrets/${name}"
done

# 2) apply the directory, its content, and the read-only bind account
kubectl apply -k security/ldap

# 3) wait for the bootstrap Job, which also proves the bind account is read-only
kubectl -n ldap wait --for=condition=complete job/ldap-bootstrap-import --timeout=300s

# 4) apply the declarative federation from your workstation
cd security/ldap/keycloak-federation
./apply-keycloak-ldap.sh
./validate-keycloak-ldap.sh
```

Use hexadecimal values without trailing newline characters. LDIF requires base64 encoding when a value starts with a space or colon.

## Layout

| Group                  | Paths                                                        | Purpose                                                                        |
| ---------------------- | ------------------------------------------------------------ | ------------------------------------------------------------------------------ |
| **Manifests**          | `kustomization.yaml`, `namespace.yaml`, `openldap/`, `jobs/` | Runnable resources (`kubectl apply -k .`)                                      |
| **Federation bundle**  | `keycloak-federation/`                                       | Declarative Keycloak LDAP provider, mappers, and apply/validate/revert scripts |
| **Auth profile**       | `auth-profile-fragment.yaml`                                 | Loadable `profiles` fragment; merge as `authProfiles` in the policy document   |
| **Egress destination** | `transport-policy-fragment.yaml`                             | Loadable `transport` fragment; merge under `transport.egress.destinations`     |
| **Sample data**        | `ldap-samples/`                                              | Optional LDIF for labs, with no passwords in it                                |
| **Runbook**            | `docs/OPERATOR_GUIDE.md`                                     | Step-by-step operations and troubleshooting                                    |
| **Values snippet**     | `values-snippet.yaml`                                        | Re-enables Keycloak when an environment has auth disabled                      |

## The lab directory is not the contract

The directory in `openldap/` serves plaintext LDAP on the cluster network. That is a teaching directory: it is enough to exercise federation, and it does **not** satisfy the transport a real federation requires.

Administrator policy for a customer-owned directory must:

- require `ldaps://` or `ldap://` with `startTlsRequired: true`;
- declare the directory as an allowed `Directory` egress destination;
- use the same read-only mode, referenced bind credential, mapper vocabulary, and bounded synchronization as this lab.

These requirements prevent a plaintext bind from exposing the credential before a transport upgrade.

## Verify

```bash
kubectl -n ldap get pods
kubectl -n ldap get job ldap-bootstrap-import

# The federation account reads the user branch...
kubectl -n ldap get secret openldap-secret -o jsonpath='{.data.federation-bind-password}' | base64 -d |
  kubectl -n ldap exec -i deploy/openldap -- sh -lc 'read -r pw
    ldapsearch -x -LLL -H ldap://127.0.0.1:389 \
      -D "cn=federation-reader,ou=services,dc=kamiwaza,dc=local" -w "$pw" \
      -b "ou=people,dc=kamiwaza,dc=local" "(objectClass=inetOrgPerson)" dn'

# ...and cannot read a password hash.
kubectl -n ldap get secret openldap-secret -o jsonpath='{.data.federation-bind-password}' | base64 -d |
  kubectl -n ldap exec -i deploy/openldap -- sh -lc 'read -r pw
    ldapsearch -x -LLL -H ldap://127.0.0.1:389 \
      -D "cn=federation-reader,ou=services,dc=kamiwaza,dc=local" -w "$pw" \
      -b "uid=alice,ou=people,dc=kamiwaza,dc=local" -s base userPassword'
```

The credential arrives on standard input rather than on a command line, so it stays out of your shell history and out of the process table. The second command returns the entry with no `userPassword` attribute, which is the read restriction working.

For script-based validation and troubleshooting, use `docs/OPERATOR_GUIDE.md`.

## Notes

- Lab users are **`alice`**, **`bob`**, and **`carol`**, sharing the generated `demo-user-password`. `alice` is in the `admin` and `user` groups; the others are in `user`.
- `dc=kamiwaza,dc=local` is the stock example base DN and `users.example.invalid` is a reserved non-resolvable domain (RFC 6761). Both are synthetic. Replace them for anything real.
- CAC/PIV certificate login is documented in [`security/cac`](../cac), not here.
