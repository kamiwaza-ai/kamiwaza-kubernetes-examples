# Adoption and upgrade journeys

## Purpose

Validate revision-bound adoption and the sole published forward upgrade into platform `1.3.0`. Both journeys preserve data, identities, selectors, and public endpoints. They do not reproduce legacy Helm hooks or Helmfile phases.

## Grounded design

Upgrades are reviewed changes with health checks before and after each boundary. Kamiwaza adds a compatibility matrix, target approval, adoption preview, revision-bound transfer, deterministic migration Jobs, and public conditions.

## Adoption fixture

`adoption/` is a small ownership-contract fixture, not a replacement for full source-release conformance. It reproduces the supported `1.1.0` request selector and retirement tombstone boundary at source revision `0bd9c641fbf990e347dc7b875db7b5425aa51ec7`. Full release certification must use an installation produced by that exact source revision.

Reuse the [shared operator installation](../quickstart/) with `adoption/operator-values.yaml`. Apply the fixture with its source field manager, then prove service before platform intent:

```bash
kubectl apply --server-side --field-manager=legacy-helmfile -k adoption
kubectl -n kw-lifecycle wait --for=condition=complete job/legacy-service-check --timeout=5m
kubectl -n kw-lifecycle get service/core-api pvc/legacy-core-data configmap/not-in-adoption-allowlist -o custom-columns=KIND:.kind,NAME:.metadata.name,UID:.metadata.uid
kubectl apply --server-side --field-manager=platform-operator-user -f adoption/platforms.yaml
```

### Preview gate

```bash
kubectl -n kw-lifecycle get kamiwazaplatform kamiwaza -o jsonpath='{.status.adoption.inventoryRevision}{"\n"}'
kubectl -n kw-lifecycle get kamiwazaplatform kamiwaza -o jsonpath='{range .status.conditions[*]}{.type}{"\t"}{.status}{"\t"}{.reason}{"\t"}{.observedGeneration}{"\n"}{end}'
kubectl -n kw-lifecycle get kamiwazaplatform kamiwaza -o jsonpath='{.status.adoption.resources}{"\n"}'
```

Require `Blocked=True/AdoptionPreviewReady`, a 64-character inventory revision, exactly the allowlisted Service and PVC, source `1.1.0` at `0bd9c641fbf990e347dc7b875db7b5425aa51ec7`, zero conflicts, and no UID or endpoint change. Reapply Preview; inventory revision and objects remain unchanged.

`adoption/disabled.yaml` shows fail-closed behavior without adoption authority. Existing fields must report ownership conflict, not be force-applied.

### Explicit transfer

`adoption/explicit.yaml` intentionally omits `inventoryRevision`; applying it must remain blocked. Copy it to an ignored local file and set `spec.adoption.inventoryRevision` to the latest Preview value. Stop only the reviewed legacy reconciler at handoff, then apply without `--force-conflicts`.

```bash
kubectl apply --server-side --field-manager=platform-operator-user -f adoption/explicit.local.yaml
kubectl -n kw-lifecycle get kamiwazaplatform kamiwaza -w
```

Any resource-version, fingerprint, source, shape, immutable field, or field-manager change invalidates the Preview. The operator must never adopt `not-in-adoption-allowlist` or another aggregate root's child. `DeleteAll` remains disabled.

Restart manager once after `status.adoption.transferStarted=true`. Reconciliation must resume from observed ownership. Require stable PVC UID, endpoint identity, Secret hashes, data probes, and no second root ownership.

## Upgrade journey

This release supports only source `1.1.0` revision `0bd9c641fbf990e347dc7b875db7b5425aa51ec7` with the KubeRay retirement tombstone and migration digest `c903b31ac455403d9d9b5a8c2026e37bfe959e3158f6f78033741fc7a784cd05`. `1.2.0` remains blocked as `KubeRayMigrationUnpublished`. Do not substitute the small adoption fixture for full upgrade proof.

Freeze pre-change application probes, PVC UIDs, Secret hashes, Service cluster IPs/selectors, Extension roots, and ModelDeployment roots. Commit desired-state changes in this dependency order:

1. Upgrade raw CRDs from the signed target release bundle.
2. Upgrade immutable administrator policy and RBAC from `upgrade/operator-values.yaml`.
3. Upgrade one manager/chart revision and wait for leader health.
4. Apply `upgrade/platforms.yaml`, changing `spec.version` to `1.3.0` only after prior gates pass.

```bash
kubectl apply --server-side --field-manager=platform-operator-user -k upgrade
kubectl -n kw-lifecycle get kamiwazaplatform kamiwaza -o jsonpath='{.status.activeTransition}{"\n"}'
kubectl -n kw-lifecycle get kamiwazaplatform kamiwaza -o jsonpath='{range .status.components[*]}{.name}{"\t"}{.state}{"\t"}{.reason}{"\t"}{.activeJob.name}{"\n"}{end}'
kubectl -n kw-lifecycle wait --for=condition=Ready kamiwazaplatform/kamiwaza --timeout=45m
```

Restart manager once during a versioned migration Job and once after one stateful member rolls. Delete no Pod to advance state. Jobs and child status must resume level-based convergence.

Afterward, rerun pre-change service probes and compare identity, PVC, endpoint, extension, and model evidence. Apply `upgrade/platforms.yaml` again. No migration Job reruns and no status timestamp changes unless observed state changes.

Transient dependency failure reports the blocked component and retains `activeTransition`; it must not claim terminal breakage or block independent components. `DeleteAll` is unavailable throughout. Rollback is unsupported because no reviewed reverse datastore migration exists.
