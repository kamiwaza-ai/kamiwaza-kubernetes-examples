# Delete a platform and retain data

Delete a `KamiwazaPlatform` with the default `RetainData` policy while preserving PVCs, Secrets, external resources, and independent extension roots.

**Tags:** #operator #deletion #retention #recovery

This workflow deletes the platform root and its ordinary stateless children. Run only with current backups and an approved recovery plan. It intentionally does not automate `DeleteAll`.

The commands use the dedicated `kamiwaza-examples` namespace. Replace it only
after selecting and recording the intended platform namespace.

## Deletion policies

| Policy       | Result                                                                                                                                         |
| ------------ | ---------------------------------------------------------------------------------------------------------------------------------------------- |
| `RetainData` | Delete ordinary owned stateless children; retain PVCs, Secrets, database contents, external certificate material, and extension roots          |
| `RetainAll`  | Orphan platform children for inspection or later transfer                                                                                      |
| `DeleteAll`  | Delete retained platform Secrets and PVCs selected by exact platform UID; requires policy, RBAC overlay, and UID/generation-bound confirmation |

`KamiwazaPlatform` and `KamiwazaExtension` are independent aggregate roots. Neither owns the other.

## 1. Confirm the safe policy and capture inventory

```bash
kubectl -n kamiwaza-examples get kamiwazaplatform kamiwaza \
  -o custom-columns=NAME:.metadata.name,UID:.metadata.uid,POLICY:.spec.deletionPolicy,PHASE:.status.phase
PLATFORM_UID="$(kubectl -n kamiwaza-examples get kamiwazaplatform kamiwaza -o jsonpath='{.metadata.uid}')"
test -n "${PLATFORM_UID}"
kubectl -n kamiwaza-examples get pvc,secret \
  -l "platform.kamiwaza.io/uid=${PLATFORM_UID}" \
  -o custom-columns=KIND:.kind,NAME:.metadata.name,UID:.metadata.uid
kubectl -n kamiwaza-examples get kamiwazaextensions.extensions.kamiwaza.io
```

Require `spec.deletionPolicy` to be `RetainData` or omitted. Capture PVC UIDs and Secret content hashes through an approved non-printing procedure.

## 2. Start deletion

Do not uninstall the manager first. It must process the platform finalizer and report retained identities.

```bash
kubectl -n kamiwaza-examples delete kamiwazaplatform kamiwaza --wait=false
kubectl -n kamiwaza-examples get kamiwazaplatform kamiwaza -w
```

While the root is finalizing, inspect `status.retainedResources` and Events in another terminal:

```bash
kubectl -n kamiwaza-examples get kamiwazaplatform kamiwaza \
  -o jsonpath='{range .status.retainedResources[*]}{.kind}{"\t"}{.namespace}{"\t"}{.name}{"\t"}{.reason}{"\n"}{end}'
kubectl -n kamiwaza-examples get events --sort-by=.metadata.creationTimestamp
```

Do not remove the finalizer manually.

## 3. Verify retention and isolation

After the root disappears:

```bash
kubectl -n kamiwaza-examples wait \
  --for=delete kamiwazaplatform/kamiwaza \
  --timeout=10m
kubectl -n kamiwaza-examples get pvc,secret \
  -l "platform.kamiwaza.io/uid=${PLATFORM_UID}" \
  -o custom-columns=KIND:.kind,NAME:.metadata.name,UID:.metadata.uid
kubectl -n kamiwaza-examples get kamiwazaextensions.extensions.kamiwaza.io
```

Require retained PVC and Secret identities to match the baseline. Extension roots and extension-owned children must remain. Ordinary platform-owned stateless resources may be garbage-collected.

## Recovery

Create a compatible replacement root in the same namespace and reference retained identities through supported existing-Secret and storage fields. Run [adoption Preview](../adoption/) before transferring compatible unowned resources. Verify PVC UIDs, Secret hashes, database identity, and endpoints before Explicit adoption.

## About `DeleteAll`

`DeleteAll` requires all of the following:

- Immutable policy sets `operations.deleteAllAllowed: true`.
- The manager has the scope-matched destructive-cleanup RBAC overlay.
- `spec.deletionPolicy` is `DeleteAll`.
- `spec.destructiveConfirmation` is exactly `delete:<platform UID>:<resulting generation>` in the same isolated spec update.

Because the operation is irreversible and the token depends on live UID and generation, this repository does not provide a copy-paste command. Follow the reviewed release deletion procedure and verify the live object after the confirmation patch before issuing deletion.
