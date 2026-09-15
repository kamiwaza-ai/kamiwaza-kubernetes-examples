# Organization deployment profiles

## Purpose

Compare three complete desired states for one organization. Directory names are organization postures, not new public API enums. Current `KamiwazaPlatform.spec.profile` admits only `Full`, so all three manifests state `Full` honestly.

## Grounded design

Each posture is a reviewable manifest. Tenant intent stays small; immutable administrator values own infrastructure trust, routing, registries, image policy, namespace scope, destructive actions, and external telemetry approval.

## Comparison

| Control                    | Development                | Production                              | Restricted                 |
| -------------------------- | -------------------------- | --------------------------------------- | -------------------------- |
| Optional catalog           | disabled                   | enabled                                 | disabled                   |
| External observability     | disabled                   | approved sink                           | disabled                   |
| Failure domains            | cluster defaults           | hard three-zone spread                  | cluster defaults           |
| Application workers        | none                       | three, `maxUnavailable: 1`              | none                       |
| Shared storage             | disabled                   | disabled until an approved class exists | disabled                   |
| Destructive operations     | disabled                   | disabled                                | disabled                   |
| Cross-namespace extensions | disabled                   | disabled                                | disabled                   |
| Credentials                | existing Secret references | existing Secret references              | existing Secret references |
| Images                     | digest-pinned              | digest-pinned                           | digest-pinned              |

`Restricted` demonstrates fewer enabled capabilities and no external destination. It does not claim regulatory certification.

## Policy limitation exposed by this example

`operator-values.yaml` is one global safe union for three watched namespaces. Current administrator policy has no named per-namespace deployment-profile catalog and the public profile enum has no `Development`, `Production`, or `Restricted` values. Therefore the operator cannot enforce every row above as a namespace-specific ceiling. It can validate each submitted manifest, but a tenant allowed to edit its platform may request another option inside the global union.

Treat that as a failed profile-isolation requirement. Do not compensate with separate undocumented values, mutating admission scripts, or tenant naming conventions. A future operator contract needs immutable administrator-selected profile IDs or separate scoped manager installations before `Restricted` can be an enforced claim.

## Apply and verify

Replace domains, storage classes, registry references, existing Secret objects, and the external telemetry endpoint. Reuse the [shared operator installation](../quickstart/) with `operator-values.yaml`, then apply exactly one complete entry point:

```bash
PROFILE=production
kubectl diff --server-side --field-manager=platform-operator-user -k ${PROFILE}
kubectl apply --server-side --field-manager=platform-operator-user -k ${PROFILE}
kubectl -n kw-profile-${PROFILE} wait --for=condition=Ready kamiwazaplatform/kamiwaza --timeout=30m
kubectl -n kw-profile-${PROFILE} logs job/profile-check
kubectl diff --server-side --field-manager=platform-operator-user -k ${PROFILE}
```

The final diff must be empty. Negative tests request an unapproved domain, storage class, image repository, external sink, private destination, adoption, or `DeleteAll`. Admission or reconciliation must reject each with a current-generation policy condition and must not create the requested child object.

## Promotion

Promotion means reviewing the complete destination directory and reconciling it in its own namespace. Never patch a development object into production. Review image digests, existing Secret readiness, storage topology, three-zone capacity, Gateway attachment, external sink health, and retained-data ownership before applying production desired state.

## Cleanup

```bash
kubectl delete -k development
kubectl -n kw-profile-development get pvc
```

`RetainData` leaves PVCs. Remove retained data only through an approved lifecycle procedure.
