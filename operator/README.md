# Platform operator scenarios

These scenarios exercise the declarative Kamiwaza lifecycle provided by the Kamiwaza Platform Operator. They use one shared manager with separate controllers for `KamiwazaPlatform`, `KamiwazaExtension`, and subordinate `ModelDeployment` resources.

The operator is under release verification. Use these workflows on disposable or explicitly approved clusters until your Kamiwaza release publishes the operator as a supported lifecycle authority. Existing Helmfile installations remain Helmfile-managed unless you complete the explicit adoption workflow.

## Responsibilities

| Actor                 | Owns                                                                                                                                  |
| --------------------- | ------------------------------------------------------------------------------------------------------------------------------------- |
| Cluster administrator | CRDs, operator installation, immutable policy, watched namespaces, shared prerequisites, external Secrets, and optional RBAC overlays |
| Platform user         | `KamiwazaPlatform` and `KamiwazaExtension` intent in approved namespaces                                                              |
| Shared manager        | Platform children, extension children, subordinate model workloads, status, and continuous drift repair within installed authority    |

The manager never installs CRDs, StorageClasses, ingress controllers, certificate controllers, device plugins, or registries during reconciliation.

## Scenario index

| Scenario                                    | Start here when                                                        | Destructive                                                     |
| ------------------------------------------- | ---------------------------------------------------------------------- | --------------------------------------------------------------- |
| [Quickstart](quickstart/)                   | Installing one fresh `1.3.0` platform in a bounded namespace           | No                                                              |
| [Namespace scopes](namespace-scopes/)       | Choosing manager placement and watch authority                         | No                                                              |
| [Transport scopes](transport-scopes/)       | Pairing transport policy with the manager's watch scope                | No                                                              |
| [Protocol data plane](protocol-data-plane/) | Running the governed endpoint and fencing its configuration channel    | No                                                              |
| [Operator chart upgrades](chart-upgrades/)  | Upgrading the shared manager chart, CRDs, policy, or RBAC              | Helm rollback does not reverse CRDs or application migrations   |
| [Model serving](model-serving/)             | Observing `ModelDeployment`, the only served-model surface             | Deletes a replaceable child Deployment                          |
| [Extensions](extensions/)                   | Deploying an independent extension root through the shared manager     | No                                                              |
| [Drift repair](drift-repair/)               | Proving reconciliation after an owned Deployment is deleted            | Deletes a replaceable Deployment                                |
| [Adoption](adoption/)                       | Previewing transfer from an explicitly supported Helmfile installation | Preview is read-only; explicit transfer changes field ownership |
| [Upgrades](upgrades/)                       | Requesting the exact supported `1.1.0` to `1.3.0` edge                 | Forward-only after the documented migration boundary            |
| [Deletion and retention](deletion/)         | Removing a platform root while retaining data by default               | Root deletion; `DeleteAll` is intentionally not automated here  |
| [Development registry](registry/)           | Supplying an administrator-owned OCI registry in an isolated lab       | No platform owner reference; not a production default           |

Product-level tenant and workroom isolation lives under
[multi-tenancy](../multi-tenancy/), not under operator installation examples.

## Common prerequisites

- A dedicated target such as `kamiwaza-examples`; never use an existing `kamiwaza` namespace for smoke tests.
- Kubernetes `1.34`, `1.35`, or `1.36`, matching the current chart contract.
- `kubectl` and Helm 3.
- Access to a signed operator chart or a reviewed local operator checkout.
- A dynamic RWO StorageClass.
- The routing and trust prerequisites selected by immutable admin policy. The example values use Istio, Gateway API, cert-manager, and trust-manager.
- Registry credentials for the digest-pinned operator and platform images.
- A DNS name routed to the selected gateway.

Start with [quickstart](quickstart/). Every other scenario states whether it requires a fresh or existing installation.
