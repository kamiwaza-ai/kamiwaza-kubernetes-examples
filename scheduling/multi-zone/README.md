# Multi-zone scheduling and disruption

## Purpose

Require three standard Kubernetes failure domains for platform workloads and application API pool members. Preserve service through one voluntary worker eviction without weakening topology intent.

## Grounded design

Confluent's [pod-scheduling examples](https://github.com/confluentinc/confluent-kubernetes-examples/tree/master/scheduling/pod-scheduling) expose native Kubernetes placement and PodDisruptionBudget controls. Kamiwaza keeps that strong boundary but applies it to durable capabilities and explicit `KamiwazaNodePool` capacity. The operator reports unsatisfied placement; it never rewrites constraints, node labels, PVC ownership, or node names.

## Prerequisites

- Three schedulable domains labeled `topology.kubernetes.io/zone`.
- Storage class `example-rwo` with topology-aware provisioning.
- Permission to create the namespaced verification `Role` and `RoleBinding`.

Verify labels without changing them:

```bash
kubectl get nodes -L topology.kubernetes.io/zone
```

## Apply and observe

```bash
kubectl diff --server-side --field-manager=platform-operator-user -k .
kubectl apply --server-side --field-manager=platform-operator-user -k .
kubectl -n kw-multi-zone wait --for=condition=Ready kamiwazaplatform/kamiwaza --timeout=30m
kubectl -n kw-multi-zone wait --for=condition=Ready kamiwazanodepool/application-workers --timeout=15m
kubectl -n kw-multi-zone logs job/zone-placement-check
```

Three worker Pods must occupy three different zones under the hard spread constraint. Platform workloads use the same constraint. Operator-owned disruption budgets derive minimum availability from replicas and `maxUnavailable: 1`.

## Bounded disruption

Start `service-continuity-check`, then select one worker Pod and submit one Kubernetes Eviction. Do not delete a controller, finalizer, PVC, or node.

```bash
kubectl -n kw-multi-zone delete job/service-continuity-check --ignore-not-found
kubectl -n kw-multi-zone apply -f availability-checks.yaml
SELECTOR=$(kubectl -n kw-multi-zone get kamiwazanodepool/application-workers -o jsonpath='{.status.labelSelector}')
POD=$(kubectl -n kw-multi-zone get pod -l "${SELECTOR}" -o jsonpath='{.items[0].metadata.name}')
kubectl -n kw-multi-zone create -f - <<EOF
apiVersion: policy/v1
kind: Eviction
metadata:
  name: ${POD}
  namespace: kw-multi-zone
EOF
kubectl -n kw-multi-zone wait --for=condition=Ready pod -l "${SELECTOR}" --timeout=10m
kubectl -n kw-multi-zone logs job/service-continuity-check
```

A denied eviction proves the budget protected minimum service. An accepted eviction must keep the health loop green and replace the member in another allowed domain.

## Insufficient domains

Apply unchanged intent to a two-zone test cluster. Affected Pods must remain Pending with scheduling events that name the topology constraint. `KamiwazaPlatform` or `KamiwazaNodePool` must not report `Ready=True` for the current generation. Reapply must not relax `DoNotSchedule` or remove durable identity.

## Cleanup

```bash
kubectl delete -k .
kubectl -n kw-multi-zone get pvc
```

`RetainData` keeps PVCs. Delete retained storage only through an approved data-destruction procedure.
