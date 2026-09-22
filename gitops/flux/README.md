# Flux delivery

Install and operate one Kamiwaza platform from a source Flux reads, with ordering between the two layers and a health assessment the platform actually satisfies.

**Tags:** #gitops #flux #helm #kustomize #health

The operator is under release verification. Run this workflow on a disposable or explicitly approved cluster.

## Prerequisites

- All [operator prerequisites](../../operator/README.md#common-prerequisites) and the [GitOps prerequisites](../README.md#prerequisites).
- Flux v2.5 or later. `.spec.healthCheckExprs` does not exist before it, and without it this scenario has no way to tell whether a platform is healthy.
- A signed, version-pinned release chart published to a registry the cluster can read.
- Platform namespace `kamiwaza-examples`, Extension runtime namespace `kamiwaza-examples-extensions`, manager namespace `kamiwaza-examples-system`, and the image pull Secret in both workload namespaces, all created by the administrator beforehand. Delivery does not create them: the operator never creates a target namespace, and a credential does not belong in a delivery source.

## 1. Publish the sources

Two artifacts: the chart, and the configuration this repository holds.

```bash
helm package <operator-chart-directory>
helm push kamiwaza-platform-operator-0.1.0.tgz \
  oci://registry.example.com/kamiwaza/charts

flux push artifact oci://registry.example.com/kamiwaza/kubernetes-examples:1.3.0 \
  --path=. \
  --source="$(git config --get remote.origin.url)" \
  --revision="$(git branch --show-current)@sha1:$(git rev-parse HEAD)"
```

A Git source is the alternative: replace the `OCIRepository` in `bootstrap.yaml` with a `GitRepository` and point the two `Kustomization` objects at it. Nothing above the source object changes.

## 2. State the release inputs

`manager/helmrelease.yaml` carries the chart version, the manager image digest, and immutable administrator policy. Replace the all-zero placeholder digest with the manager digest from your signed release metadata, and replace the lab domain and StorageClass with your own. Both files are read before anything is applied:

```bash
kubectl kustomize manager
kubectl kustomize ../platform
```

## 3. Apply the bootstrap

```bash
kubectl apply -f bootstrap.yaml
```

Three objects: the source, and one `Kustomization` per layer. Everything else arrives from the source.

## 4. Watch the ordering hold

```bash
flux -n flux-system get kustomizations
```

Before the manager layer is ready, the platform layer states why it has not run:

```
kamiwaza-manager    Unknown   Reconciliation in progress
kamiwaza-platform   False     dependency 'flux-system/kamiwaza-manager' is not ready
```

This is the point of `dependsOn`. Without it the first apply of the platform fails on a kind that does not exist yet and succeeds on a later interval — it converges, but it reports a failure that is not one, and a first install looks broken.

## 5. Watch the health gate

The platform layer waits on the expressions in `bootstrap.yaml`, not on the apply:

```bash
kubectl -n flux-system get kustomization kamiwaza-platform \
  -o jsonpath='{.status.conditions[?(@.type=="Healthy")].message}{"\n"}'
```

Two properties are worth understanding before copying the expressions:

**`exists`, not `filter(...).all(...)`.** The common spelling of a Ready check is `status.conditions.filter(e, e.type == 'Ready').all(e, e.status == 'True')`. An empty list satisfies `all`, and a platform has no conditions at all for the first seconds of its life, so that spelling reports a brand-new platform as healthy and the wait returns before the operator has looked at it once.

**The generation comparison.** The operator stamps `observedGeneration` on every condition. Comparing it to `metadata.generation` makes the answer about the revision that was just applied, rather than about whatever the operator last finished — which matters on every change after the first.

## 6. Read a blocked platform as a result

`Blocked=True` is the operator's terminal answer: immutable policy, an administrator-owned prerequisite, or intent it will not act on. The `failed` expression turns it into a failed reconciliation rather than a 60-minute wait:

```
health check failed after 57ms: failed early due to stalled resources:
  [KamiwazaPlatform/kamiwaza-examples/kamiwaza status: 'Failed']
```

Then read the reason from the platform itself and fix the cause, which is a prerequisite or a policy decision, never something to bypass:

```bash
kubectl -n kamiwaza-examples get kamiwazaplatform kamiwaza \
  -o jsonpath='{range .status.conditions[*]}{.type}{"\t"}{.status}{"\t"}{.reason}{"\t"}{.message}{"\n"}{end}'
```

## 7. Verify

```bash
./verify.sh
```

It asserts the delivery and the platform: the source is ready, both layers are ready, the platform's `Ready` condition is true, `status.currentVersion` is `1.3.0`, and the operator has observed the current generation. The platform layer's own `Ready` condition is part of the assertion, because it is true only if the health expressions matched — a scenario that checked the platform alone would also pass with expressions that match nothing.

## Changing the platform later

Change the source, not the cluster. A new intent revision is applied by the platform layer; a new chart version or a policy change is a `HelmRelease` upgrade. The operator repairs drift in its own children, so nothing here competes with it: this layer owns one resource, and the operator owns everything that resource produces.

## Deleting

`prune` is `false` on the platform layer on purpose. Removing the resource from the source does not delete the platform, because deleting a platform runs the finalizer's retention behavior, and that decision belongs in the [deletion and retention](../../operator/deletion/) workflow rather than to a file disappearing from a source.

## How these inputs were validated

| File                                                             | Validated with                                                                                                                                                                                                                                                                                                                                                                                                                       |
| ---------------------------------------------------------------- | ------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------ |
| [bootstrap.yaml](bootstrap.yaml)                                 | Applied to a live cluster with the lab source and paths substituted, and the CEL expressions carried over byte for byte. Ordering observed: the platform layer reported `dependency 'flux-system/kamiwaza-manager' is not ready` until the manager layer was ready. The `failed` expression observed: a platform blocked on `WorkloadIdentityRejected` failed the health check in 57ms instead of waiting out the 60-minute timeout. |
| [manager/helmrelease.yaml](manager/helmrelease.yaml)             | `kubectl kustomize manager` renders; installed on a live cluster through `helm-controller`, which reported `Helm upgrade succeeded`. The first attempt failed with `mapping key "app.kubernetes.io/component" already defined` — a chart defect this scenario found and the operator fixed, not a property of this file.                                                                                                             |
| [../platform/kustomization.yaml](../platform/kustomization.yaml) | `kubectl kustomize ../platform` renders the published quickstart intent unchanged. Delivered to a live cluster under a lab overlay that adds only the namespace and the installation's own `clusterID`.                                                                                                                                                                                                                              |
| [verify.sh](verify.sh)                                           | Run against the converged live installation.                                                                                                                                                                                                                                                                                                                                                                                         |

The lab overlay is not published here. It carries a disposable environment's addresses and locally built images, and nothing in it belongs in a customer installation.
