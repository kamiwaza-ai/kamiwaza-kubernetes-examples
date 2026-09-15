# Local model-serving matrix

## Purpose

Run one immutable SmolLM2 artifact through the same `ModelDeployment` API on CPU, NVIDIA, or AMD hardware. Tenant intent declares model identity, engine settings, artifact digest, storage, resources, and accelerator demand. Administrator policy owns serving images and artifact-source transport. Kube-scheduler and administrator-installed device plugins own placement and allocation.

## Grounded design

`ModelDeployment` is the sole model intent. It uses native extended resources, verifies immutable artifact identity before start, and reports missing hardware instead of selecting an undeclared fallback.

## Choose one lane

```bash
kubectl kustomize cpu
kubectl kustomize nvidia
kubectl kustomize amd
```

Apply exactly one lane to namespace `kw-local-models`. Replace `example-rwo`. Administrator policy maps each engine and accelerator resource to a release-reviewed, digest-pinned serving image. Install the matching device plugin before an accelerated lane. Never label or mutate nodes from this example.

```bash
kubectl diff --server-side --field-manager=model-owner -k cpu
kubectl apply --server-side --field-manager=model-owner -k cpu
kubectl -n kw-local-models wait --for=condition=Ready modeldeployment/smollm2 --timeout=20m
kubectl -n kw-local-models logs job/local-model-inference-check
```

The check requires more than one server-sent event and a non-empty final answer. Unavailable accelerator capacity must remain visible as an unschedulable model workload; CPU fallback is a failure.

## Declarative lifecycle

`base/model-deployment.yaml` is `Running`. Apply `lifecycle/paused` or `lifecycle/stopped`, then reapply the selected hardware lane to resume. These states scale the owned workload through reconciliation; they do not call Core or delete pods.

```bash
kubectl apply --server-side --field-manager=model-owner -k lifecycle/paused
kubectl apply --server-side --field-manager=model-owner -k lifecycle/stopped
kubectl apply --server-side --field-manager=model-owner -k cpu
```

A no-op reapply must keep the same deployment identity, PVC, Service, and Ready status. Cleanup deletes the Job and `ModelDeployment`; the independently declared model PVC remains until its data is reviewed.
