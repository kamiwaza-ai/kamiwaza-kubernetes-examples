# Declarative model serving

Add a small CPU-only model to an existing operator-managed platform and observe the durable serving resource.

**Tags:** #operator #models #llamacpp #cpu #drift-repair

## Contract

Platform users declare model intent in `KamiwazaPlatform.spec.models`. The platform controller acquires and registers the model, and the shared manager materializes a subordinate `ModelDeployment`. The serving controller owns the child Deployment and stable Service.

Do not author `ModelDeployment` directly for normal platform use. Kubernetes scheduling and administrator-installed device plugins or DRA drivers own placement and allocation.

## Prerequisites

- The [quickstart](../quickstart/) platform is Ready.
- The cluster can fetch the declared model revision or provides an approved mirror.
- The administrator-owned model registry and its local credential Secret match immutable policy.

## Apply model intent

`kubectl patch --type=merge` replaces the complete `spec.models` list. Merge any existing entries into `model-intent-patch.yaml` before applying it.

```bash
kubectl -n kamiwaza-examples patch kamiwazaplatform kamiwaza \
  --type=merge \
  --patch-file model-intent-patch.yaml
```

## Observe acquisition and serving

```bash
kubectl -n kamiwaza-examples get jobs \
  -l app.kubernetes.io/component=models
kubectl -n kamiwaza-examples get kamiwazaplatform kamiwaza \
  -o jsonpath='{range .status.models[*]}{.name}{"\t"}{.phase}{"\t"}{.reason}{"\t"}{.deploymentId}{"\n"}{end}'
kubectl -n kamiwaza-examples get modeldeployments.serving.kamiwaza.io
```

Wait for every subordinate deployment to report Ready:

```bash
for name in $(kubectl -n kamiwaza-examples get modeldeployments.serving.kamiwaza.io -o name); do
  kubectl -n kamiwaza-examples wait --for=condition=Ready "${name}" --timeout=30m
done
```

A completed acquisition Job is retained as versioned audit evidence and is not recreated on unchanged reconciliation.

## Verify desired-state recovery

Choose the `ModelDeployment` created for this intent and record its UID and deployment ID:

```bash
kubectl -n kamiwaza-examples get modeldeployments.serving.kamiwaza.io \
  -o custom-columns=NAME:.metadata.name,UID:.metadata.uid,DEPLOYMENT_ID:.spec.deploymentId,PHASE:.status.phase
```

Delete only its replaceable child Deployment, not the `ModelDeployment`:

```bash
MODEL_DEPLOYMENT=<name-from-the-previous-command>
kubectl -n kamiwaza-examples delete deployment "${MODEL_DEPLOYMENT}"
```

The serving controller must recreate the Deployment under the same `ModelDeployment` UID and deployment ID. Re-run the custom-column command and wait for Ready. No model re-registration or imperative redeploy is required.

## Remove model intent

Removing the entry stops the deployment but retains downloaded model artifacts. If this is the only entry:

```bash
kubectl -n kamiwaza-examples patch kamiwazaplatform kamiwaza \
  --type=merge \
  --patch '{"spec":{"models":[]}}'
```
