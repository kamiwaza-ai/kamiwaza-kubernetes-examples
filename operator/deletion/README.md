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
  -o custom-columns=NAME:.metadata.name,UID:.metadata.uid,POLICY:.spec.deletionPolicy,CURRENT:.status.currentVersion
PLATFORM_UID="$(kubectl -n kamiwaza-examples get kamiwazaplatform kamiwaza -o jsonpath='{.metadata.uid}')"
test -n "${PLATFORM_UID}"
kubectl -n kamiwaza-examples get pvc,secret \
  -l "platform.kamiwaza.io/uid=${PLATFORM_UID}" \
  -o custom-columns=KIND:.kind,NAME:.metadata.name,UID:.metadata.uid
kubectl -n kamiwaza-examples get kamiwazaplatform kamiwaza \
  -o jsonpath='{range .status.retainedResources[*]}{.identity.kind}{"\t"}{.identity.namespace}{"\t"}{.identity.name}{"\t"}{.reason}{"\t"}{.ownership}{"\n"}{end}'
kubectl -n kamiwaza-examples get kamiwazaextensions.extensions.kamiwaza.io
```

Require `spec.deletionPolicy` to be `RetainData` or omitted. The retained-resource status must name every labeled PVC and Secret before deletion starts. Capture PVC UIDs and Secret content hashes through an approved non-printing procedure.

## 2. Start deletion

Keep the manager installed. It continues reconciling independent extension and model roots and preserves the operator diagnostics used during verification.

```bash
kubectl -n kamiwaza-examples delete kamiwazaplatform kamiwaza --wait=false
kubectl -n kamiwaza-examples get events --sort-by=.metadata.creationTimestamp
```

`RetainData` deliberately carries no deletion finalizer: ordinary children use Kubernetes garbage collection, while retained PVCs and Secrets have no platform owner reference. The root can disappear immediately, so review and save `status.retainedResources` before issuing the delete command.

Do not remove a finalizer manually if another policy or external cleanup keeps the root present.

## 3. Verify retention and isolation

After the root disappears:

```bash
kubectl -n kamiwaza-examples wait \
  --for=delete kamiwazaplatform/kamiwaza \
  --timeout=10m
kubectl -n kamiwaza-examples get pvc,secret \
  -l "platform.kamiwaza.io/uid=${PLATFORM_UID}" \
  -o custom-columns=KIND:.kind,NAME:.metadata.name,UID:.metadata.uid
kubectl -n kamiwaza-examples get deployment,statefulset,job \
  -l "platform.kamiwaza.io/uid=${PLATFORM_UID}"
kubectl -n kamiwaza-examples get kamiwazaextensions.extensions.kamiwaza.io
```

Require retained PVC and Secret identities to match the baseline. Extension
roots and extension-owned children must remain. No ordinary platform-owned
workload may remain under the deleted platform UID.

## Recovery

Reapply a compatible platform manifest with the same non-empty `spec.clusterID`.
The operator treats that stable identity as proof that retained PVCs and
operator-created Secrets belong to the same installation. It changes their
owner UID to the replacement root without changing PVC UIDs or Secret data:

```bash
kubectl apply --server-side \
  --field-manager=platform-operator-user \
  -f ../quickstart/kamiwaza-platform.local.yaml
kubectl -n kamiwaza-examples wait \
  --for=condition=Ready kamiwazaplatform/kamiwaza \
  --timeout=15m
NEW_PLATFORM_UID="$(kubectl -n kamiwaza-examples get kamiwazaplatform kamiwaza -o jsonpath='{.metadata.uid}')"
kubectl -n kamiwaza-examples get pvc,secret \
  -l "platform.kamiwaza.io/uid=${NEW_PLATFORM_UID}" \
  -o custom-columns=KIND:.kind,NAME:.metadata.name,UID:.metadata.uid
```

Require the same PVC UIDs and Secret content hashes captured before deletion.
Verify database identity and endpoints. A resource without the matching stable
cluster identity is not rebound automatically; use [adoption
Preview](../adoption/) before any explicit transfer.

## About `DeleteAll`

`DeleteAll` requires all of the following:

- Immutable policy sets `operations.deleteAllAllowed: true`.
- The manager has the scope-matched destructive-cleanup RBAC overlay.
- `spec.deletionPolicy` is `DeleteAll`.
- `spec.destructiveConfirmation` is exactly `delete:<platform UID>:<resulting generation>` in the same isolated spec update.

Because the operation is irreversible and the token depends on live UID and generation, this repository does not provide a copy-paste command. Follow the reviewed release deletion procedure and verify the live object after the confirmation patch before issuing deletion.
