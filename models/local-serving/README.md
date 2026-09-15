# Local model-serving matrix

## Purpose

Run one immutable SmolLM2 artifact through the same `ModelDeployment` API on CPU, NVIDIA, or AMD hardware. Each lane uses kube-scheduler and an administrator-installed device plugin; the operator never inventories or binds nodes.

## Grounded design

Confluent's [pod scheduling examples](https://github.com/confluentinc/confluent-kubernetes-examples/tree/master/scheduling/pod-scheduling) make hardware and placement choices explicit. Kamiwaza keeps native scheduling fields and improves lifecycle ownership: a persistent `ModelDeployment` is the sole model intent, immutable artifact identity is checked before start, and missing hardware stays an actionable scheduling condition instead of triggering a controller-side fallback.

## Choose one lane

```bash
kubectl kustomize cpu
kubectl kustomize nvidia
kubectl kustomize amd
```

Apply exactly one lane to namespace `kw-local-models`. Replace `example-rwo`. CPU uses the release-reviewed Kamiwaza llama.cpp image. NVIDIA and AMD use current upstream multi-architecture and amd64-only image-index digests respectively; review and repin them with your release. Install the matching device plugin before the accelerated lane. Never label or mutate nodes from this example.

```bash
kubectl diff --server-side --field-manager=model-owner -k cpu
kubectl apply --server-side --field-manager=model-owner -k cpu
kubectl -n kw-local-models wait --for=condition=Ready modeldeployment/smollm2 --timeout=20m
kubectl -n kw-local-models logs job/local-model-inference-check
```

The check requires more than one server-sent event and a non-empty final answer. Unavailable accelerator capacity must remain visible as an unschedulable model workload; CPU fallback is a failure.

## Declarative lifecycle

`base/model-deployment.yaml` is `running`. Apply `lifecycle/paused` or `lifecycle/stopped`, then reapply the selected hardware lane to resume. These states scale the owned workload through reconciliation; they do not call Core or delete pods.

```bash
kubectl apply --server-side --field-manager=model-owner -k lifecycle/paused
kubectl apply --server-side --field-manager=model-owner -k lifecycle/stopped
kubectl apply --server-side --field-manager=model-owner -k cpu
```

A no-op reapply must keep the same deployment identity, PVC, Service, and Ready status. Cleanup deletes the Job and `ModelDeployment`; the independently declared model PVC remains until its data is reviewed.
