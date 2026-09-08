# Declarative model serving

Observe how a served model is deployed in this release, and prove the serving surface recovers its own desired state after a child object is destroyed.

**Tags:** #operator #models #serving #drift-repair

## What this example replaces

The previous version of this directory patched `KamiwazaPlatform.spec.models` with a model entry and then read `status.models`. Neither field exists: the platform CRD declares no model intent at all, and a conformance test asserts it stays that way so that declaring a platform cannot deploy a model by default. The patch file that carried that entry has been removed rather than left to be applied against a field the API server would reject.

## Contract

`ModelDeployment` in `serving.kamiwaza.io` is the only surface that deploys a served model. One object is one deployment, keyed by `spec.deploymentId`, serving `spec.modelId`, with `spec.engineName` naming the engine that authored `spec.carriedPodTemplate`.

The template is engine-authored. The application writes it when a model is deployed through it, which is why this repository publishes no hand-written one: a Pod template that has never served a request would be a guess rather than an example, and the failure would land on whoever applied it.

The platform contributes serving **policy** to a requested deployment and creates none:

| The platform does                                                                       | Where it lands                               |
| --------------------------------------------------------------------------------------- | -------------------------------------------- |
| Applies platform Pod hardening                                                          | `spec.carriedPodTemplate.spec`               |
| Projects the published trust distribution                                               | `spec.carriedPodTemplate`                    |
| Routes artifact-pull egress through the approved enforcing proxy                        | the `pull-model` init container              |
| Supplies approved registry credentials as environment from the policy-named Secret      | the `pull-model` init container              |
| Refuses a template that tried to supply its own trust path, with `VerificationRejected` | the request's outcome, before any credential |

Two properties follow, and both are observable:

- **It is write-free when converged.** The policy pass compares the template before and after and patches only when something changed, so an unchanged reconcile writes nothing.
- **Credentials are attached after verification, never before.** Trust is projected first; a template that supplied its own trust path is refused before a registry credential is ever placed in a container that would use it over a channel the platform did not verify.

The platform's own component outcome for this is `modelServing`, with reason `ModelServingDeclarative` and the message `model serving follows requested ModelDeployment resources`. Where administrator policy approves no enforcing proxy, the same message continues `; no enforcing proxy is approved, so served model runtimes have no external path` — which is a statement about outbound reachability, not a failure.

## Prerequisites

- The [quickstart](../quickstart/) platform is Ready.
- At least one `ModelDeployment` exists in the namespace, created by the application when a model was deployed through it. This example observes and stresses what exists; it does not author one.
- The administrator-owned model registry and its local credential Secret match immutable policy.

## Observe what is requested and what is serving

```bash
kubectl -n kamiwaza-examples get modeldeployments.serving.kamiwaza.io \
  -o custom-columns=NAME:.metadata.name,UID:.metadata.uid,DEPLOYMENT_ID:.spec.deploymentId,MODEL:.spec.modelId,ENGINE:.spec.engineName,PHASE:.status.phase,READY:.status.readyReplicas

kubectl -n kamiwaza-examples get kamiwazaplatform kamiwaza \
  -o jsonpath='{range .status.components[?(@.name=="models")]}{.name}{"\t"}{.phase}{"\t"}{.reason}{"\t"}{.message}{"\n"}{end}'
```

An empty list is a complete answer: it means nothing has requested a served model, not that serving is broken.

Wait for every requested deployment to report Ready:

```bash
for name in $(kubectl -n kamiwaza-examples get modeldeployments.serving.kamiwaza.io -o name); do
  kubectl -n kamiwaza-examples wait --for=condition=Ready "${name}" --timeout=30m
done
```

## Read the policy the platform applied

The hardening and the pull-credential wiring are visible on the request itself, which is the point of applying them there rather than to a copy:

```bash
MODEL_DEPLOYMENT=<name-from-the-previous-command>

# Hardened Pod security context on the engine-authored template.
kubectl -n kamiwaza-examples get modeldeployments.serving.kamiwaza.io "${MODEL_DEPLOYMENT}" \
  -o jsonpath='{.spec.carriedPodTemplate.spec.securityContext}{"\n"}'

# The registry credentials reach the pull container as environment from the
# policy-named Secret. The names of the Secret and its keys are visible; the
# credential itself is not, and never appears in a container argument.
kubectl -n kamiwaza-examples get modeldeployments.serving.kamiwaza.io "${MODEL_DEPLOYMENT}" \
  -o jsonpath='{range .spec.carriedPodTemplate.spec.initContainers[?(@.name=="pull-model")]}{range .env[*]}{.name}{"\t"}{.valueFrom.secretKeyRef.name}{"\t"}{.valueFrom.secretKeyRef.key}{"\n"}{end}{end}'
```

## Verify desired-state recovery

Delete only the replaceable child Deployment, never the `ModelDeployment`:

```bash
kubectl -n kamiwaza-examples delete deployment "${MODEL_DEPLOYMENT}"
```

The serving controller must recreate the Deployment under the same `ModelDeployment` UID and deployment ID. Re-run the custom-column command and wait for Ready. No model re-registration and no imperative redeploy is required, and the identity does not change — which is what makes this recovery rather than a new deployment.

## Stop a deployment without destroying it

`spec.state` is what the owner wants the deployment to be doing, and `stopped` is not deletion: artifacts and identity are retained.

```bash
kubectl -n kamiwaza-examples patch modeldeployments.serving.kamiwaza.io "${MODEL_DEPLOYMENT}" \
  --type=merge --patch '{"spec":{"state":"stopped"}}'
```

`running`, `paused`, and `stopped` are the values this release serves. An unrecognised value is treated as unsupported rather than defaulted to `running`, because guessing would start a workload somebody asked to stop.

Deleting the `ModelDeployment` is how a deployment goes away. That is a separate decision from stopping it, and it is the application's decision to make where the application created the object.
