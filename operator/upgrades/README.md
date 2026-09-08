# Controlled platform upgrade

Request the exact supported forward upgrade and observe preflight, versioned Jobs, and staged convergence.

**Tags:** #operator #upgrade #migration #day2

The current operator release converges to `1.3.0`. It supports a `1.1.0` source only at the exact revision and source-controller state published in `dist/compatibility.json`. A `1.2.0` source with active KubeRay `1.6.2` is blocked. No reverse migration is advertised.

The commands use `kamiwaza-examples` for an isolated rehearsal. Replace it only
after selecting and recording the reviewed production namespace.

## Prerequisites

- Adoption of the supported source is complete or the source installation already satisfies the published ownership contract.
- A current backup exists outside the cluster, including recovery credentials.
- The maintenance window covers the forward-only migration boundary.
- The cluster administrator has upgraded all three CRDs before rolling out a manager that requires them.
- The immutable policy explicitly allows `1.3.0` in `operations.approvedForwardOnlyUpgradeTargets`.

An available image tag is not upgrade evidence. Use only the source/target edge and migration digest in the installed release compatibility artifact.

## 1. Review compatibility and live state

```bash
cat "${OPERATOR_RELEASE_DIR}/dist/compatibility.json"
kubectl -n kamiwaza-examples get kamiwazaplatform kamiwaza \
  -o custom-columns=DESIRED:.spec.version,CURRENT:.status.currentVersion,PHASE:.status.phase,TRANSITION:.status.activeTransition.type
kubectl -n kamiwaza-examples get deployment extension-operator kuberay-operator \
  --ignore-not-found
```

The exact source revision, legacy extension-controller handoff, and KubeRay tombstone state must match the published edge.

## 2. Upgrade administrator-owned APIs

The manager has no CRD permissions. Run the release-provided CRD upgrade procedure with an explicit disposable or target context:

```bash
KUBECONFIG="${KUBECONFIG:?Set the reviewed target context}" \
  "${OPERATOR_RELEASE_DIR}/scripts/upgrade-crds.sh"
```

Wait for all three CRDs to be Established and verify `v1alpha1` remains served and stored before rolling out the manager.

## 3. Approve the forward target

Merge this setting into the complete immutable admin policy used by the manager:

```yaml
adminPolicy:
  operations:
    approvedForwardOnlyUpgradeTargets:
      - 1.3.0
```

Apply the change through the administrator-owned operator release process. Do not use a tenant resource to widen this policy.

## 4. Request the upgrade

```bash
kubectl -n kamiwaza-examples patch kamiwazaplatform kamiwaza \
  --type=merge \
  --patch '{"spec":{"version":"1.3.0"}}'
```

The controller checks API compatibility, immutable policy, source-controller state, the migration digest, and prerequisites before changing platform children.

## 5. Observe without bypassing blockers

```bash
kubectl -n kamiwaza-examples get kamiwazaplatform kamiwaza -w
kubectl -n kamiwaza-examples get jobs \
  -l app.kubernetes.io/managed-by=kamiwaza-platform-operator
kubectl -n kamiwaza-examples get kamiwazaplatform kamiwaza \
  -o jsonpath='{range .status.conditions[*]}{.type}{"\t"}{.status}{"\t"}{.reason}{"\t"}{.message}{"\n"}{end}'
```

A preflight blocker leaves existing workloads and endpoints unchanged. Correct the named source state, prerequisite, or immutable policy. Never edit status, delete lifecycle Jobs, or substitute an unpublished source edge.

Failed lifecycle Jobs remain as evidence. Reconciliation observes or retries the same deterministic Job and does not advance dependent components.

## 6. Verify completion

```bash
kubectl -n kamiwaza-examples wait \
  --for=condition=Ready \
  kamiwazaplatform/kamiwaza \
  --timeout=45m
kubectl -n kamiwaza-examples get kamiwazaplatform kamiwaza \
  -o custom-columns=DESIRED:.status.desiredVersion,CURRENT:.status.currentVersion,PHASE:.status.phase,GENERATION:.metadata.generation,OBSERVED:.status.observedGeneration
```

Success requires both desired and current versions to be `1.3.0`, Ready true, observed generation current, platform smoke passing, and the pre-upgrade PVC/Secret/endpoint identities preserved.

## Rollback boundary

Before the Core database migration Job starts, restore `spec.version` to `status.currentVersion` and follow the source release procedure. After that Job starts, recovery requires the administrator's pre-upgrade database backup and the edge-specific migration procedure. This release publishes no automated downgrade.
