# Retention, deletion, and recovery

## Purpose

Exercise `RetainData`, `RetainAll`, guarded `DeleteAll`, and same-namespace recovery over retained identities and volumes. This is lifecycle validation, not a backup procedure.

## Grounded design

Stateful data survives ordinary lifecycle changes. Kamiwaza separates Kubernetes garbage collection, retained data, independent extension and model roots, and explicitly authorized destructive cleanup.

## Prerequisites

- Disposable namespace for `DeleteAll`; never use production data.
- Existing Secrets from `platform.yaml`, `workflow-signing`, and `retention-client` (`token`).
- StorageClass `example-rwo`, Gateway API front door, certificate Secret `kamiwaza-gateway-tls`, and model-download egress.
- Shared manager installed through the [operator quickstart](../quickstart/) with this scenario's `operator-values.yaml`.

## Establish proof data

```bash
kubectl apply --server-side --field-manager=platform-operator-user -k .
kubectl -n kw-retention-recovery wait --for=condition=Ready kamiwazaplatform/kamiwaza --timeout=30m
kubectl -n kw-retention-recovery wait --for=condition=complete job/seed-retained-data --timeout=15m
kubectl -n kw-retention-recovery logs job/seed-retained-data
kubectl -n kw-retention-recovery get pvc,secret -l platform.kamiwaza.io/cluster-id=kw-retention-recovery -o custom-columns=KIND:.kind,NAME:.metadata.name,UID:.metadata.uid
```

The Job writes catalog metadata, a relational catalog record, object bytes, and verifies inference from the model artifact. Capture the listed PVC UIDs and approved non-printing Secret hashes. Also record Extension and ModelDeployment UIDs. Ready pods alone are not proof.

## `RetainData` recovery

Delete only the platform root. Independent Extension and ModelDeployment roots remain.

```bash
kubectl -n kw-retention-recovery delete kamiwazaplatform kamiwaza
kubectl -n kw-retention-recovery get pvc,secret,extension,modeldeployment
kubectl apply --server-side --field-manager=platform-operator-user -f platform.yaml
kubectl -n kw-retention-recovery wait --for=condition=Ready kamiwazaplatform/kamiwaza --timeout=30m
kubectl -n kw-retention-recovery delete job/verify-retained-data --ignore-not-found
kubectl -n kw-retention-recovery apply -f recovery-checks.yaml
kubectl -n kw-retention-recovery wait --for=condition=complete job/verify-retained-data --timeout=15m
kubectl -n kw-retention-recovery logs job/verify-retained-data
```

Require unchanged `clusterID`, domain, version, Secret references, StorageClass, PVC UIDs, Secret hashes, public endpoint, Extension UID, ModelDeployment UID, dataset URN, object bytes, and runtime model ID.

## `RetainAll`

Apply the complete alternate state before deleting the root:

```bash
kubectl apply --server-side --field-manager=platform-operator-user -f retain-all.yaml
kubectl -n kw-retention-recovery delete kamiwazaplatform kamiwaza
kubectl -n kw-retention-recovery get all,pvc,secret
```

`RetainAll` orphans safe platform-owned children. It adds no owner reference to the Extension, ModelDeployment, external certificate material, or other independent root. Reapply `retain-all.yaml`, then run `recovery-checks.yaml` and compare the baseline.

## Guarded `DeleteAll`

`delete-all.yaml` intentionally has no confirmation. With normal `operator-values.yaml`, immutable policy denies it. Even after an administrator installs the complete `delete-all-operator-values.yaml`, destructive cleanup requires its separate RBAC overlay and an exact confirmation.

1. Apply `delete-all.yaml` in a disposable namespace and verify `OperationNotAllowed` or `DestructiveConfirmationRequired`.
2. Read the live resource UID and generation.
3. Copy `delete-all.yaml` to an isolated, ignored file. Add `spec.destructiveConfirmation: delete:<UID>:<resulting generation>`, where resulting generation is the generation produced by that exact apply. Never commit this file or token.
4. Server-side apply the isolated file. Read back UID, generation, and confirmation; require an exact match.
5. Delete the root. Verify only PVCs and Secrets labeled with that root UID are removed. Independent roots and external certificate material remain.

Never calculate or inject the token with a checked-in script. Never remove finalizers manually.

## Limits

Operator performs no backup, snapshot, point-in-time restore, or application-data export. Recovery works only because retained volumes and create-once identities remain compatible with the same declarative installation identity. Use storage-native and application-native backup systems for disaster recovery.
