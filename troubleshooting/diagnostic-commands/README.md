# Diagnostic commands

**Scenario:** inspect one operator-managed Kamiwaza platform without changing cluster state.

Tags: #troubleshooting #diagnostics #health-check.

## Quick start

Run the script directly when the cluster contains one `KamiwazaPlatform`:

```bash
./troubleshooting/diagnostic-commands/kamiwaza-diagnostics.sh
```

Select the platform when the cluster contains more than one:

```bash
KAMIWAZA_NAMESPACE=tenant-a \
KAMIWAZA_PLATFORM=kamiwaza \
./troubleshooting/diagnostic-commands/kamiwaza-diagnostics.sh
```

The script reports:

- `KamiwazaPlatform` generation, Ready condition, reason, and component messages.
- pod readiness and container restarts.
- persistent volume claim state.
- `ModelDeployment` generation and Ready state.
- installed extension phase and Ready state.
- namespace warning events.

Exit code `0` means no health error. Warning events and container restarts produce warnings but keep exit code `0`. Exit code `1` means a current resource is not ready. Exit code `2` means platform selection, API access, or a prerequisite failed.

## Platform contract

Set the names once for the individual commands:

```bash
NAMESPACE=tenant-a
PLATFORM=kamiwaza
```

Read the platform summary:

```bash
kubectl get kamiwazaplatform "$PLATFORM" -n "$NAMESPACE" -o wide
```

Read all conditions and component messages:

```bash
kubectl get kamiwazaplatform "$PLATFORM" -n "$NAMESPACE" \
  -o jsonpath='{range .status.conditions[*]}{.type}{"\t"}{.status}{"\t"}{.reason}{"\t"}{.message}{"\n"}{end}{range .status.components[*]}{.name}{"\t"}{.message}{"\n"}{end}'
```

A current platform has matching `.metadata.generation` and `.status.observedGeneration`. Its Ready condition is `True`.

## Workloads

List pod readiness and restarts:

```bash
kubectl get pods -n "$NAMESPACE" -o wide
```

List operator-managed platform workloads:

```bash
kubectl get pods -n "$NAMESPACE" \
  -l app.kubernetes.io/managed-by=kamiwaza-platform-operator \
  -o wide
```

List extension workloads:

```bash
kubectl get pods -n "$NAMESPACE" \
  -l app.kubernetes.io/component=extension \
  -o wide
```

List model-serving workloads:

```bash
kubectl get pods -n "$NAMESPACE" \
  -l app.kubernetes.io/name=model-serving \
  -o wide
```

## Model deployments

```bash
kubectl get modeldeployments -n "$NAMESPACE" -o wide
kubectl describe modeldeployments -n "$NAMESPACE"
```

Each model deployment must have matching desired and observed generations. Its Ready condition must be `True`.

## Extensions

List current extension installations:

```bash
kubectl get kamiwazaextensions -n "$NAMESPACE"
```

The compatibility resource is deprecated. It remains the served installation status for released extensions until migration completes.

## Persistent storage

```bash
kubectl get pvc -n "$NAMESPACE"
```

Investigate every claim whose status is not `Bound`.

## Operator control plane

Find the manager without assuming its namespace:

```bash
kubectl get deployments -A \
  -l app.kubernetes.io/name=kamiwaza-platform-operator
```

Read manager logs after you identify the manager namespace:

```bash
OPERATOR_NAMESPACE=kamiwaza-system
kubectl logs -n "$OPERATOR_NAMESPACE" \
  deployment/kamiwaza-platform-operator \
  --tail=100
```

## Warning events

```bash
kubectl get events -n "$NAMESPACE" \
  --field-selector type=Warning \
  --sort-by=.lastTimestamp
```

Events are historical. Compare each event with current conditions and current pod state before you classify a current failure.

## Validation evidence

On 2026-09-16, the exact script selected `kamiwaza-examples/kamiwaza` on a clean k0s validation cluster. It reported `AllComponentsReady`, 37 ready pods, 13 bound persistent volume claims, three ready model deployments, and one ready extension. One prior container restart and historical warning events produced warnings. The script completed with exit code `0`.

All commands in this example are read-only.
