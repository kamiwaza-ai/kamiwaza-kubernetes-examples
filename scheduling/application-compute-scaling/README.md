# Application compute scaling

## Purpose

Declare external application-compute scale authority on `KamiwazaPlatform`.
A native `autoscaling/v2` HPA writes the component's owned
`PlatformScaleTarget`; the operator remains the sole writer of the worker
Deployment replica field.

## Grounded design

`spec.components.applicationAPI.compute.replicas` initializes the component at
one replica and remains the fixed count if authority returns to `Fixed`.
`spec.scaling.components` selects `External` authority for
`applicationCompute`. The HPA targets
`platform.kamiwaza.ai/v1alpha1/PlatformScaleTarget` named
`kamiwaza-application-compute`, not the internal worker Deployment.

The operator derives target safety bounds, owns target identity and status, and
applies valid desired scale to the worker. The HPA owns only its metrics policy
and writes only the standard `/scale` subresource. This keeps component scale
independent without splitting child-workload ownership.

## Prerequisites

- Resource metrics available through `metrics.k8s.io`; the operator does not install Metrics Server.
- Worker containers have CPU requests, so utilization has a denominator.
- A real delegated workload. Request-surface health checks do not consume worker CPU and are not a valid scaling exercise.
- HPA controller authorization to read and update the target's `/scale` subresource.

Create both watched namespaces before installing the shared operator. Helm
cannot create namespaced RBAC in a namespace that does not exist:

```bash
kubectl apply --server-side --field-manager=platform-operator-user \
  -f namespace.yaml -f extension-namespace.yaml
```

Then reuse the [shared operator installation](../../operator/quickstart/) with
this scenario's `operator-values.yaml`. Replace `example-rwo` and
`scale.example.invalid`, then apply:

```bash
kubectl diff --server-side --field-manager=platform-operator-user -k .
kubectl apply --server-side --field-manager=platform-operator-user -k .
kubectl -n kw-compute-scale wait --for=condition=Ready kamiwazaplatform/kamiwaza --timeout=30m
kubectl -n kw-compute-scale get platformscaletarget/kamiwaza-application-compute
kubectl -n kw-compute-scale get hpa/application-compute deployment/core-raycluster-worker
kubectl -n kw-compute-scale get --raw '/apis/metrics.k8s.io/v1beta1/namespaces/kw-compute-scale/pods'
```

Run a representative delegated workload and watch the facade, autoscaler, and
worker:

```bash
kubectl -n kw-compute-scale get platformscaletarget/kamiwaza-application-compute,hpa/application-compute,deployment/core-raycluster-worker -w
```

Desired worker replicas must stay between `1` and `4` and return toward `1`
after sustained low utilization under Kubernetes HPA defaults. The target
status reports actual replicas and the worker selector. Request-surface
readiness remains independent from worker scaling.

## Fixed capacity

To restore fixed capacity, change `applicationCompute` authority to `Fixed` and
set `spec.components.applicationAPI.compute.replicas` to the required count.
Delete the HPA before removing `autoscaler.yaml` from the kustomization:

```bash
kubectl -n kw-compute-scale delete horizontalpodautoscaler/application-compute
```

Reapply the kustomization. The operator repairs the scale target to the fixed
count and continues owning the worker Deployment.
Do not use `kubectl scale` or edit the generated Deployment.

## Missing metrics

Remove the test cluster's metrics adapter only in a disposable environment.
HPA conditions must report unavailable metrics. The operator preserves the last
valid target count and does not add a retry loop, guessed replica count, or
fallback scaler.

## Cleanup

```bash
kubectl -n kw-compute-scale delete horizontalpodautoscaler/application-compute
kubectl -n kw-compute-scale delete kamiwazaplatform/kamiwaza
kubectl -n kw-compute-scale get platformscaletarget,hpa,deployment,pvc
```

The platform owner reference removes the scale target and worker. The
separately authored HPA is removed explicitly. `RetainData` preserves platform
storage.
