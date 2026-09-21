# Argo CD delivery

Install and operate one Kamiwaza platform from a source Argo CD reads, with waves that order the two layers and a health assessment that tells the truth about a platform.

**Tags:** #gitops #argocd #sync-waves #health #server-side-apply

The operator is under release verification. Run this workflow on a disposable or explicitly approved cluster.

## Prerequisites

- All [operator prerequisites](../../operator/README.md#common-prerequisites) and the [GitOps prerequisites](../README.md#prerequisites).
- Argo CD v3.1 or later for OCI sources. A Git source works on any supported version: replace `repoURL` and `targetRevision`, and nothing else changes.
- A signed, version-pinned release chart published to a registry the cluster can read.
- Platform namespace `kamiwaza-examples`, Extension runtime namespace `kamiwaza-examples-extensions`, manager namespace `kamiwaza-examples-system`, and the image pull Secret in both workload namespaces, all created by the administrator beforehand. `CreateNamespace` is deliberately not set: the operator never creates a target namespace, and neither should its delivery.

## 1. Publish the sources

```bash
helm package <operator-chart-directory>
helm push kamiwaza-platform-operator-0.1.0.tgz \
  oci://registry.example.com/kamiwaza/charts

tar -czf config.tar.gz .
oras push registry.example.com/kamiwaza/kubernetes-examples:1.3.0 \
  config.tar.gz:application/vnd.oci.image.layer.v1.tar+gzip
```

The media type matters. Argo CD accepts `application/vnd.oci.image.layer.v1.tar+gzip` and the Helm chart layer type, and refuses anything else with `oci layer media type … is not in the list of allowed media types`. An artifact pushed by `flux push artifact` carries Flux's own media type, so publish with ORAS if one artifact has to serve both controllers.

## 2. Install the health assessment

```bash
kubectl -n argocd patch configmap argocd-cm \
  --patch-file argocd-cm-health.yaml
kubectl -n argocd rollout restart deployment argocd-server
```

Two entries, and the scenario does not work without either:

- **`KamiwazaPlatform`.** Argo CD has no built-in health for a custom resource, so without this a platform is Healthy the instant the API server accepts it. The Application reports success while the operator has not pulled an image, and the wave after it starts immediately.
- **`Application`.** Argo CD removed health assessment for its own kind in 1.8. The app-of-apps below advances a wave when the previous wave is Healthy, and a child Application with no health assessment is Healthy on creation — so without this entry the waves order nothing.

The platform check reads `observedGeneration` on each condition, so it answers about the revision that was applied rather than about whatever the operator last finished, and it maps `Blocked=True` to `Degraded`. Blocked is the operator's terminal answer — immutable policy, a missing administrator-owned prerequisite, or intent it will not act on — and a sync that waits it out turns a clear answer into a timeout.

## 3. Apply the root Application

```bash
kubectl apply -f root-application.yaml
```

It owns the two children in `applications/`: the manager layer at wave 0 and the intent layer at wave 1.

## 4. Watch the waves

```bash
kubectl -n argocd get applications \
  -o custom-columns='NAME:.metadata.name,SYNC:.status.sync.status,HEALTH:.status.health.status'
```

Wave 1 does not start until wave 0 is Healthy, which is what keeps the first sync honest: wave 0 installs the API that wave 1's resource is written against.

## 5. Server-side apply is required, not preferred

Both children set `ServerSideApply=true`. The platform CRD this chart installs renders to 737 KB, and a client-side apply records the whole object in the `kubectl.kubernetes.io/last-applied-configuration` annotation, which the API server refuses above 262144 bytes:

```
The CustomResourceDefinition "kamiwazaplatforms.platform.kamiwaza.ai" is invalid:
  metadata.annotations: Too long: may not be more than 262144 bytes
```

The same limit applies to Argo CD's own `ApplicationSet` CRD, so its published manifests need `kubectl apply --server-side` too. This is a property of large CRDs rather than of this chart.

## 6. Verify

```bash
./verify.sh
```

It asserts that the health customization is installed, that all three Applications are Healthy, that the platform's `Ready` condition is true, and that `status.currentVersion` is `1.3.0`. The health customization is checked first on purpose: without it the Application waits would pass against a platform that has not started.

## Changing the platform later

Change the source. `selfHeal` is on for both layers and has nothing to fight: this layer owns one resource, and the operator owns everything that resource produces and repairs their drift itself.

## Deleting

`prune` is `false` on the intent layer, and the root Application carries no resource finalizer. Removing the platform from the source does not delete it, because deleting a platform runs the finalizer's retention behavior — a decision that belongs to the [deletion and retention](../../operator/deletion/) workflow rather than to a file disappearing from a source.

## How these inputs were validated

| File                                                     | Validated with                                                                                                                                                                                                                                                                        |
| -------------------------------------------------------- | ------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| [argocd-cm-health.yaml](argocd-cm-health.yaml)           | Applied to a live Argo CD v3.5.3 with `kubectl patch --patch-file`. The platform check was observed reporting `Progressing` while the operator converged, rather than the `Healthy` an uncustomized Argo CD reports on creation.                                                      |
| [root-application.yaml](root-application.yaml)           | Applied to a live cluster with the lab source substituted. It produced both children and reported their aggregate health.                                                                                                                                                             |
| [applications/manager.yaml](applications/manager.yaml)   | Installed the chart on a live cluster from an OCI registry with `ServerSideApply=true`. The requirement was measured directly: `kubectl apply` of the rendered platform CRD fails with `metadata.annotations: Too long`, and `kubectl apply --server-side` of the same file succeeds. |
| [applications/platform.yaml](applications/platform.yaml) | Delivered the published intent layer to a live cluster under a lab overlay that adds only the namespace and the installation's own `clusterID`.                                                                                                                                       |
| [verify.sh](verify.sh)                                   | Run against the converged live installation.                                                                                                                                                                                                                                          |

The lab overlay is not published here. It carries a disposable environment's addresses and locally built images, and nothing in it belongs in a customer installation.
