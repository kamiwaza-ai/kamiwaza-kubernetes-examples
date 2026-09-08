# Managed workload drift repair

Prove that the operator restores a replaceable platform Deployment after deletion without rotating retained Secrets or recreating completed lifecycle Jobs.

**Tags:** #operator #day2 #drift-repair #reconciliation

This scenario intentionally deletes a Deployment. Use only on a disposable installation or during an approved resilience exercise. Do not select PostgreSQL, etcd, or another stateful workload.

## Prerequisites

- The [quickstart](../quickstart/) platform is Ready.
- No installation, upgrade, adoption, or deletion transition is active.
- The selected Deployment is platform-owned, stateless, and safe to interrupt.

## 1. Capture the stable baseline

```bash
kubectl -n kamiwaza-examples get kamiwazaplatform kamiwaza \
  -o custom-columns=GENERATION:.metadata.generation,OBSERVED:.status.observedGeneration,PHASE:.status.phase,CURRENT:.status.currentVersion
kubectl -n kamiwaza-examples get deployments \
  -l app.kubernetes.io/managed-by=kamiwaza-platform-operator,platform.kamiwaza.io/controller-domain=platform
kubectl -n kamiwaza-examples get jobs \
  -l app.kubernetes.io/managed-by=kamiwaza-platform-operator
kubectl -n kamiwaza-examples get secrets \
  -l platform.kamiwaza.io/uid \
  -o custom-columns=NAME:.metadata.name,UID:.metadata.uid,DATA_VERSION:.metadata.resourceVersion
```

Save the Job and Secret output. Secret data must never be printed for this test.

## 2. Delete one replaceable Deployment

Choose a stateless Deployment from the managed list:

```bash
TARGET_DEPLOYMENT=<reviewed-stateless-deployment>
kubectl -n kamiwaza-examples delete deployment "${TARGET_DEPLOYMENT}"
```

The platform should move through Progressing while the controller recreates the missing desired object.

## 3. Observe recovery

```bash
kubectl -n kamiwaza-examples get events \
  --sort-by=.metadata.creationTimestamp
kubectl -n kamiwaza-examples rollout status \
  "deployment/${TARGET_DEPLOYMENT}" \
  --timeout=10m
kubectl -n kamiwaza-examples wait \
  --for=condition=Ready \
  kamiwazaplatform/kamiwaza \
  --timeout=10m
```

## 4. Verify invariants

Repeat the baseline commands and compare output:

- The deleted Deployment exists and is available.
- `status.observedGeneration` equals the unchanged root generation.
- `status.currentVersion` is unchanged.
- Existing Secret UIDs and data resource versions are unchanged.
- Successful versioned lifecycle Jobs were not recreated.
- Extension and model roots were not changed by platform drift repair.

A controller restart can be tested separately by restarting the manager Deployment. Reconciliation must derive the next action from Kubernetes state; it must not depend on process-local phase history.
