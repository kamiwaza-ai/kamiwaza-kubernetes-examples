# Application compute scaling

## Purpose

Declare bounded application-compute autoscaling on `KamiwazaPlatform`. The
operator renders one `autoscaling/v2` HPA and leaves the worker Deployment
replica field to that controller.

## Grounded design

Capacity and bounded CPU autoscaling live under
`spec.components.applicationAPI.compute`. Capability-wide placement and
disruption remain beside it under `applicationAPI`. Fixed `replicas` and
`autoscaling` are mutually exclusive. The operator owns the generated worker
and HPA; users do not author either object.

## Prerequisites

- Resource metrics available through `metrics.k8s.io`; the operator does not install Metrics Server.
- Worker containers have CPU requests, so utilization has a denominator.
- A real delegated workload. Request-surface health checks do not consume worker CPU and are not a valid scaling exercise.

Reuse the [shared operator installation](../../operator/quickstart/) with this
scenario's `operator-values.yaml`. Replace `example-rwo` and
`scale.example.invalid`, then apply:

```bash
kubectl diff --server-side --field-manager=platform-operator-user -k .
kubectl apply --server-side --field-manager=platform-operator-user -k .
kubectl -n kw-compute-scale wait --for=condition=Ready kamiwazaplatform/kamiwaza --timeout=30m
kubectl -n kw-compute-scale get hpa/core-raycluster-worker deployment/core-raycluster-worker
kubectl -n kw-compute-scale get --raw '/apis/metrics.k8s.io/v1beta1/namespaces/kw-compute-scale/pods'
```

The HPA target is the operator-owned stable worker Deployment. Run a
representative delegated workload and watch both objects:

```bash
kubectl -n kw-compute-scale get hpa/core-raycluster-worker deployment/core-raycluster-worker -w
```

Worker replicas must stay between `1` and `4` and return toward `1` after
sustained low utilization under Kubernetes HPA defaults. Request-surface
readiness remains independent from worker scaling.

## Fixed capacity

To use fixed capacity instead, replace the entire `autoscaling` block in
`platform.yaml` with `replicas: 2`. Do not declare both. Reapply the platform;
the operator removes its HPA before it owns the Deployment replica field.
Do not use `kubectl scale` or edit the generated Deployment.

## Missing metrics

Remove the test cluster's metrics adapter only in a disposable environment.
HPA conditions must report unavailable metrics. The operator does not add a
retry loop, guessed replica count, or fallback scaler.

## Cleanup

```bash
kubectl -n kw-compute-scale delete kamiwazaplatform/kamiwaza
kubectl -n kw-compute-scale get hpa,deployment,pvc
```

The platform owner reference removes the HPA and worker. `RetainData` preserves
platform storage.
