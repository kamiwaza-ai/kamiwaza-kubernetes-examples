# Multi-node protocol plane

## Purpose

Keep model, MCP, and A2A request paths available while one protocol-plane Pod is replaced or one node is drained. The platform declares one failure-domain key. The operator derives replica count, placement, disruption budget, and rollout behavior from that availability claim.

## Contract status

`KamiwazaPlatform.spec.availability.failureDomainKey` and the three-replica HA floor already exist. The current renderer also uses zero unavailable and one surge replica. It does not yet project the failure domain into the protocol-plane Pod topology constraint or create its PodDisruptionBudget. This example intentionally makes those missing obligations executable. `protocol-plane-shape-check` must fail until both exist.

No tenant replica field is proposed. One top-level availability claim remains the source of truth.

## Grounded design

- Kubernetes topology spread supplies `maxSkew`, `minDomains`, and `DoNotSchedule`: <https://kubernetes.io/docs/concepts/scheduling-eviction/topology-spread-constraints/>.
- A PodDisruptionBudget with `maxUnavailable: 1` limits voluntary disruption but cannot prevent node failure: <https://kubernetes.io/docs/tasks/run-application/configure-pdb/>.
- MCP Streamable HTTP defines session identity and stream reconnection. A transport disconnect is not a request cancellation: <https://modelcontextprotocol.io/specification/2025-11-25/basic/transports>.

## Prerequisites

- Three schedulable nodes across three distinct `topology.kubernetes.io/zone` values.
- `platform.yaml` carries one intentionally non-pullable, provider-neutral image pin only to satisfy the current CRD shape. Replace `spec.images.pinned` with the complete reviewed release inventory and replace `example-rwo` before apply.
- Existing Secret `protocol-check-token` in `kw-protocol-ha` with a short-lived bearer token authorized for the read-only `/v1/models` check.
- Operator-projected ConfigMap `kamiwaza-trust-bundle` with key `ca-certificates.crt` for protocol-plane server verification.
- Administrator permission to create the read-only Node `ClusterRole` in `availability-check.yaml`.

Verify capacity without changing labels:

```bash
kubectl get nodes -L topology.kubernetes.io/zone
```

## Render and apply

```bash
kubectl kustomize .
kubectl diff --server-side --field-manager=platform-operator-user -k .
kubectl apply --server-side --field-manager=platform-operator-user -k .
kubectl -n kw-protocol-ha wait --for=condition=Ready kamiwazaplatform/kamiwaza --timeout=30m
kubectl -n kw-protocol-ha logs job/protocol-plane-shape-check
```

Expected owned resources:

- Deployment, Service, ConfigMap, and ServiceAccount named `kamiwaza-dataplane`.
- Three ready Pods in three zones.
- Hard spread: `maxSkew: 1`, `minDomains: 3`, `DoNotSchedule`.
- PodDisruptionBudget `kamiwaza-dataplane` with `maxUnavailable: 1`.
- Rolling update with `maxUnavailable: 0` and `maxSurge: 1`.
- Equal `kamiwaza.ai/dataplane-config-digest` values on every ready Pod.

## Bounded disruption

Start the continuity Job, then use one scoped Eviction. The Job samples the governed model inventory for five minutes and fails on any unavailable or malformed response.

```bash
kubectl -n kw-protocol-ha delete job/protocol-plane-continuity-check --ignore-not-found
kubectl -n kw-protocol-ha apply -f availability-check.yaml
POD=$(kubectl -n kw-protocol-ha get pods -l app.kubernetes.io/component=dataplane -o jsonpath='{.items[0].metadata.name}')
kubectl -n kw-protocol-ha create -f - <<EOF
apiVersion: policy/v1
kind: Eviction
metadata:
  name: ${POD}
  namespace: kw-protocol-ha
EOF
kubectl -n kw-protocol-ha wait --for=condition=Ready pod -l app.kubernetes.io/component=dataplane --timeout=10m
kubectl -n kw-protocol-ha logs job/protocol-plane-continuity-check
```

For a full node-drain exercise, use a disposable cluster and drain only one reviewed node. Confirm unrelated workloads and disruption budgets first. Always uncordon the node after the check.

## Stateful protocol checks

Run the MCP and A2A scenarios through the same Service during one allowed disruption. Reconnect MCP with its `MCP-Session-Id` and `Last-Event-ID`. Resume the same A2A task or subscription. The result must not duplicate, and stream disconnect must not become task cancellation.

## Insufficient capacity

Apply unchanged intent to a two-zone test cluster. Protocol-plane Pods that cannot satisfy `minDomains: 3` remain Pending. Platform status reports `AvailabilityClaimUnsupported` or `Unschedulable` for the observed generation. The operator must not lower replicas, remove `minDomains`, or switch to `ScheduleAnyway`.

## Cleanup

```bash
kubectl delete -k .
kubectl delete clusterrolebinding/kw-protocol-ha-check clusterrole/kw-protocol-ha-check
kubectl -n kw-protocol-ha get pvc
```

`RetainData` preserves durable platform data.
