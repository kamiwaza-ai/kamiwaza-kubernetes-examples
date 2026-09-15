# Application NodePool scaling

## Purpose

Set baseline application API capacity with `spec.replicas`, then let a Kubernetes `autoscaling/v2` HPA use the `KamiwazaNodePool` scale subresource. No platform mutation or fallback scaler.

## Grounded design

Confluent's [pod scheduling examples](https://github.com/confluentinc/confluent-kubernetes-examples/tree/master/scheduling/pod-scheduling) keep workload placement in Kubernetes APIs. Kamiwaza also makes capacity a first-class namespaced resource. Native HPA owns replica demand; the operator only projects desired and observed scale. This avoids a second autoscaling controller inside the platform operator.

## Prerequisites

- Resource metrics available through `metrics.k8s.io`; the operator does not install Metrics Server.
- Worker containers declare CPU requests, so utilization has a denominator.
- Platform request load reaches work executed by this pool. A fixed request surface that never dispatches work to pool members does not satisfy this example.

## Baseline and apply

Install the operator with `operator-values.yaml`, replace `example-rwo` and `scale.example.invalid`, then apply:

```bash
kubectl apply --server-side --field-manager=platform-operator-user -k .
kubectl -n kw-nodepool-scale wait --for=condition=Ready kamiwazaplatform/kamiwaza --timeout=30m
kubectl -n kw-nodepool-scale wait --for=condition=Ready kamiwazanodepool/application-workers --timeout=15m
kubectl -n kw-nodepool-scale get kamiwazanodepool/application-workers -o jsonpath='{.spec.replicas}{" desired, "}{.status.replicas}{" observed\n"}'
kubectl -n kw-nodepool-scale get --raw '/apis/metrics.k8s.io/v1beta1/namespaces/kw-nodepool-scale/pods'
```

Both counts start at `1`. Reapply must not change them.

## Scale exercise

`bounded-request-load` makes real HTTP requests for 180 seconds. Watch HPA, NodePool, worker Pods, and service health:

```bash
kubectl -n kw-nodepool-scale delete job/bounded-request-load --ignore-not-found
kubectl -n kw-nodepool-scale apply -f autoscaling.yaml
kubectl -n kw-nodepool-scale get hpa/application-workers kamiwazanodepool/application-workers -w
kubectl -n kw-nodepool-scale wait --for=jsonpath='{.status.replicas}'=2 kamiwazanodepool/application-workers --timeout=10m
kubectl -n kw-nodepool-scale wait --for=condition=complete job/bounded-request-load --timeout=5m
kubectl -n kw-nodepool-scale logs job/bounded-request-load
kubectl -n kw-nodepool-scale get hpa/application-workers -o yaml
```

Observed replicas must rise above `1`, remain within `4`, and return to `1` after the 300-second stabilization window. `Ready` must match the current NodePool generation. Voluntary disruption must keep the single-member baseline available under `maxUnavailable: 0`.

The operator must publish `status.labelSelector` with the immutable labels used by actual pool Pods. The scale subresource maps that value to `status.selector` for HPA. If the selector names labels absent from Pod templates, HPA reports missing metrics and this scenario fails. Do not hide that contract defect with imperative `kubectl scale`, direct Deployment edits, or a custom poller.

## Missing metrics

Remove the test cluster's metrics adapter only in a disposable environment. HPA status must state that metrics are unavailable while the NodePool remains at its last declared baseline. No fixed retry or guessed replica fallback belongs here.

## Cleanup

```bash
kubectl -n kw-nodepool-scale delete hpa/application-workers job/bounded-request-load
kubectl -n kw-nodepool-scale delete kamiwazanodepool/application-workers kamiwazaplatform/kamiwaza
kubectl -n kw-nodepool-scale get pvc
```

`RetainData` preserves platform storage.
