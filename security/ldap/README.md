# LDAP + Keycloak federation (read-only)

**Scenario:** federate a directory into Kamiwaza through Keycloak, **read-only**, with a referenced bind credential and every image pinned by digest. A lab directory stands in for the customer-owned one so the federation can be exercised end to end.

**Tags:** #security #ldap #keycloak #read-only #pinned

## What this example restricts itself to

- **Read-only federation.** `editMode: READ_ONLY` and `syncRegistrations: false`: the platform reads accounts and group membership and writes nothing back. The directory belongs to whoever owns it, and a federation that can write to it is a federation that can lock out its users.
- **A referenced bind credential.** The federation binds as `cn=federation-reader,ou=services,…`, not as the directory manager, and its credential comes from Secret `openldap-secret` key `federation-bind-password`. Directory access control grants that account read on the user and group branches, nothing on password hashes, and no write anywhere. The bootstrap Job proves it: the Job fails rather than report a read-only federation it does not have.
- **Pinned images.** Every image is `docker.io/osixia/openldap:1.5.0@sha256:18742e9c449c9c1afe129d3f2f3ee15fb34cc43e5f940a20f3399728f41d7c28`. The tag is there to read; the digest is what runs.
- **A closed mapper vocabulary.** Mappers project directory attributes and directory group membership onto reviewed claims. Nothing manufactures a group, a role, or a tenant the directory does not state; group membership becomes a realm role, and authorization past that point is ReBAC.
- **No credential in Git.** Every password is generated locally into `local-secrets/`, which Git ignores. No sample LDIF, ConfigMap, or Secret manifest in this directory carries a password or a hash.

## What is not here any more

- **The directory web UI.** It bound as the directory manager and existed to write to the directory, which is the opposite of what this example now demonstrates. It also pulled an unpinned third-party image and patched it at container start.
- **The in-cluster federation Job.** It installed packages from the internet at run time, so nothing about it could be pinned. The same declarative bundle runs from a workstation instead, which is where an administrator applying identity configuration is anyway.

## Prerequisites

- Kamiwaza deployed with Keycloak from your **pinned release chart** (or merge `values-snippet.yaml` and re-sync first). This example pins its own images; it selects no chart version, because the Keycloak your platform runs comes from your release.
- Secret `keycloak-admin` in namespace `kamiwaza`.
- `kubectl` with kustomize support, plus `curl` and `jq` on the workstation that applies the federation.

## Steps

```bash
# 1) generate the lab credentials (Git ignores local-secrets/)
mkdir -p security/ldap/local-secrets
for name in admin-password config-password federation-bind-password demo-user-password; do
  openssl rand -hex 32 > "security/ldap/local-secrets/${name}"
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

Hex rather than base64: these values are written into LDIF, where a value beginning with a space or a colon has to be base64-encoded to be read back correctly.

## Layout

| Group                 | Paths                                                        | Purpose                                                                        |
| --------------------- | ------------------------------------------------------------ | ------------------------------------------------------------------------------ |
| **Manifests**         | `kustomization.yaml`, `namespace.yaml`, `openldap/`, `jobs/` | Runnable resources (`kubectl apply -k .`)                                      |
| **Federation bundle** | `keycloak-federation/`                                       | Declarative Keycloak LDAP provider, mappers, and apply/validate/revert scripts |
| **Auth profile**      | `auth-profile-fragment.yaml`                                 | Loadable `profiles` fragment; merge as `authProfiles` in the policy document    |
| **Egress destination** | `transport-policy-fragment.yaml`                            | Loadable `transport` fragment; merge under `transport.egress.destinations`       |
| **Sample data**       | `ldap-samples/`                                              | Optional LDIF for labs, with no passwords in it                                |
| **Runbook**           | `docs/OPERATOR_GUIDE.md`                                     | Step-by-step operations and troubleshooting                                    |
| **Values snippet**    | `values-snippet.yaml`                                        | Re-enables Keycloak when an environment has auth disabled                      |

## The lab directory is not the contract

The directory in `openldap/` serves plaintext LDAP on the cluster network. That is a teaching directory: it is enough to exercise federation, and it does **not** satisfy the transport a real federation requires.

[auth-profile-fragment.yaml](auth-profile-fragment.yaml) is the shape administrator policy takes for a directory you actually own: `ldaps://`, or `ldap://` with `startTlsRequired: true`, because a plaintext bind puts the credential on the network before any upgrade; a declared `Directory` egress destination the platform's policy-aware dialer reaches it through; and the same read-only edit mode, referenced bind credential, closed mapper vocabulary, and bounded synchronization this lab uses.

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
