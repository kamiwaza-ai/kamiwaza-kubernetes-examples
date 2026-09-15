# Persistent multi-service extension

## Purpose

Run a two-component extension. API depends on worker. Worker writes idempotent results to a retained PVC. A bounded Job submits one workflow, evicts one worker, and verifies the same durable result after replacement.

## Grounded design

API and worker graphs plus workflow code live in digest-verified artifacts. `Extension` names only artifact, state, existing credentials, and pass-through configuration. The operator owns Kubernetes lifecycle and status, not workflow semantics.

## Prerequisites

- StorageClass `example-rwo` supports durable `ReadWriteOnce` volumes.
- Existing Secret `workflow-signing` in `kw-persistent-extension`. Its required keys belong to the reviewed image contract; never commit values.
- Shared manager installed through the [operator quickstart](../../operator/quickstart/) with this scenario's `operator-values.yaml` and access to pinned images.

## Apply and check

```bash
kubectl apply --server-side --field-manager=platform-operator-user -k .
kubectl -n kw-persistent-extension wait --for=condition=Ready extension/persistent-workflow --timeout=15m
kubectl -n kw-persistent-extension logs job/workflow-check
kubectl -n kw-persistent-extension get pvc
kubectl diff --server-side --field-manager=platform-operator-user -k .
```

Expected graph: `worker` first, then `api`. Operator-owned NetworkPolicy admits API-to-worker and the scenario's labeled check Job to API only. Every rendered container has explicit resources, read-only root filesystem, dropped capabilities, and its own identity.

`workflow001` is processed once. Repeating it returns the stored result. The check uses the Kubernetes Eviction API for one bounded disruption; it does not delete a controller, finalizer, PVC, or extension object.

## Failure and recovery

Withdraw storage in a disposable cluster or make provisioning temporarily unavailable. Expect `Ready=False` with `VolumeUnbound` or a storage-specific transient reason. Restore the StorageClass or backend. The same PVC and workflow ID must resume without duplicate processing. Restarting the operator must not recreate or adopt the PVC under a new identity.

Removing the existing Secret must block the affected components without exposing values or deleting state. Restoring the same Secret name resumes reconciliation.

## Cleanup

```bash
kubectl delete -k .
kubectl -n kw-persistent-extension get pvc
```

State PVCs deliberately have no Extension owner reference and remain. Extension deletion must not affect any `KamiwazaPlatform` aggregate root. Remove retained PVCs only through an approved application-data procedure.
