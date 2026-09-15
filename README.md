# Kamiwaza Kubernetes examples

Scenario workflows for running **[Kamiwaza](https://kamiwaza.ai)** on Kubernetes through the Kamiwaza Platform Operator. Each use case defines prerequisites, ordered steps, manifests, and verification.

**These examples do not define release support.** Use the versions, image digests, compatibility artifact, and security requirements shipped with your Kamiwaza release. Lab defaults must be replaced before production use.

---

## Official documentation

- Platform deployment and architecture: the **[Kamiwaza docs](https://docs.kamiwaza.ai)** and the documentation shipped with your Kamiwaza release.
- This repository adds executable scenario workflows; it does not replace release documentation or expand the operator's published compatibility matrix.

---

## Prerequisites

Assumed for most scenarios unless stated otherwise:

| Requirement        | Notes                                                                                                      |
| ------------------ | ---------------------------------------------------------------------------------------------------------- |
| Kubernetes cluster | Use a version supported by the selected operator release. The current chart accepts `1.34` through `1.36`. |
| `kubectl`          | Configure it for an explicitly reviewed cluster context.                                                   |
| Helm 3             | Required only for the canonical operator installation and operator upgrades.                               |
| Kustomize          | Available through `kubectl apply -k` for scenario resources.                                               |

Install the shared manager once through the
[operator quickstart](operator/quickstart/#4-install-the-shared-manager).
Every other scenario reuses that release and identifies any administrator
policy that must be applied before its namespaced resources.

**Clone this repository:**

```bash
git clone <YOUR_GIT_REMOTE>/kamiwaza-kubernetes-examples.git
cd kamiwaza-kubernetes-examples
```

Use your organization’s fork when changes require separate review.

---

## Scenario index

Category indexes:

- **Platform operator:** [operator/README.md](operator/README.md)
- **Federation:** [federation/README.md](federation/README.md)
- **Multi-tenancy:** [multi-tenancy/README.md](multi-tenancy/README.md)
- **Monitoring:** [monitoring/README.md](monitoring/README.md)
- **Networking:** [networking/README.md](networking/README.md)
- **Operations:** [operations/README.md](operations/README.md)
- **Protocols:** [protocols/README.md](protocols/README.md)
- **Security:** [security/README.md](security/README.md)
- **Troubleshooting:** [troubleshooting/README.md](troubleshooting/README.md)

| Scenario                                               | Path                                                                                                                                   | Tags                                                        |
| ------------------------------------------------------ | -------------------------------------------------------------------------------------------------------------------------------------- | ----------------------------------------------------------- |
| Fresh operator installation                            | [operator/quickstart](operator/quickstart)                                                                                             | #operator #quickstart #fresh-install                        |
| Reviewed image inventory for platform intent           | [operator/reviewed-image-inventory](operator/reviewed-image-inventory)                                                                 | #operator #images #supply-chain #fips                       |
| Operator namespace scopes                              | [operator/namespace-scopes](operator/namespace-scopes)                                                                                 | #operator #rbac #multi-tenant                               |
| Operator Helm chart upgrade                            | [operator/chart-upgrades](operator/chart-upgrades)                                                                                     | #operator #helm #crd                                        |
| Declarative model serving                              | [operator/model-serving](operator/model-serving)                                                                                       | #operator #models #serving #drift-repair                    |
| Independent extension lifecycle                        | [operator/extensions](operator/extensions)                                                                                             | #operator #extensions                                       |
| Operator drift repair                                  | [operator/drift-repair](operator/drift-repair)                                                                                         | #operator #day2 #reconciliation                             |
| Existing installation adoption                         | [operator/adoption](operator/adoption)                                                                                                 | #operator #migration #adoption                              |
| Controlled operator upgrade                            | [operator/upgrades](operator/upgrades)                                                                                                 | #operator #upgrade #migration                               |
| Platform deletion and retention                        | [operator/deletion](operator/deletion)                                                                                                 | #operator #deletion #retention                              |
| Administrator-owned development registry               | [operator/registry](operator/registry)                                                                                                 | #operator #registry #development                            |
| Transport under a strict and a relaxed scope           | [operator/transport-scopes](operator/transport-scopes)                                                                                 | #operator #transport #namespaces #rbac                      |
| Governed endpoint and configuration fencing            | [operator/protocol-data-plane](operator/protocol-data-plane)                                                                           | #operator #transport #fencing #data-plane                   |
| Cross-Kamiwaza federation                              | [federation/cross-kamiwaza](federation/cross-kamiwaza)                                                                                 | #federation #multi-cluster #spiffe #fail-closed             |
| Multi-node protocol plane                              | [networking/multi-node-protocol-plane](networking/multi-node-protocol-plane)                                                           | #networking #availability #protocols #disruption            |
| MCP federation                                         | [protocols/mcp-federation](protocols/mcp-federation)                                                                                   | #protocols #mcp #tools #authorization                       |
| A2A connectivity                                       | [protocols/a2a-connectivity](protocols/a2a-connectivity)                                                                               | #protocols #a2a #agents #tasks                              |
| Tomo shared-workroom tenant isolation                  | [multi-tenancy/tomo-shared-workrooms](multi-tenancy/tomo-shared-workrooms)                                                             | #multi-tenancy #tomo #rebac #models                         |
| Grafana + Prometheus monitoring                        | [monitoring/grafana-prometheus](monitoring/grafana-prometheus)                                                                         | #monitoring #prometheus #grafana #loki                      |
| Service access patterns                                | [networking/external-access](networking/external-access)                                                                               | #networking #port-forward #ingress                          |
| Backup and restore                                     | [operations/backup-restore](operations/backup-restore)                                                                                 | #operations #backup #postgres #etcd                         |
| Kaizen offline template livepatch                      | [security/tls-trust/extensions/kaizen-offline-template-livepatch](security/tls-trust/extensions/kaizen-offline-template-livepatch)     | #security #tls #kaizen #offline #livepatch                  |
| Kaizen offline frontend font hotfix                    | [security/tls-trust/extensions/kaizen-offline-frontend-font-hotfix](security/tls-trust/extensions/kaizen-offline-frontend-font-hotfix) | #kaizen #offline #frontend #nextjs                          |
| Consent modal + classification banners                 | [security/consent-banner](security/consent-banner)                                                                                     | #security #compliance #helm-values                          |
| CAC / PIV login (external authentication edge)         | [security/cac](security/cac)                                                                                                           | #security #cac #piv #external-edge #gateway-api             |
| Custom TLS trust + BYO ingress cert                    | [security/tls-trust](security/tls-trust)                                                                                               | #security #tls #pki #ca-trust #bedrock                      |
| ReBAC grant changes: plan, diff, apply                 | [security/rebac](security/rebac)                                                                                                       | #security #rebac #authz #producer-ownership #grants         |
| LDAP + Keycloak federation (read-only, pinned)         | [security/ldap](security/ldap)                                                                                                         | #security #ldap #keycloak #read-only #pinned                |
| External edge: listener, redirect, client certificates | [security/external-edge](security/external-edge)                                                                                       | #security #transport #gateway-api #external-edge            |
| Egress destination classes and enforcing proxy         | [security/egress](security/egress)                                                                                                     | #security #transport #egress #enforcing-proxy               |
| Transport failure modes and their reasons              | [security/failure-modes](security/failure-modes)                                                                                       | #security #transport #failure #fail-closed                  |
| Staged transport migration                             | [security/migration](security/migration)                                                                                               | #security #transport #migration #profiles                   |
| Authority rotation and connection drain                | [security/rotation-drain](security/rotation-drain)                                                                                     | #security #transport #rotation #drain                       |
| Diagnostic commands                                    | [troubleshooting/diagnostic-commands](troubleshooting/diagnostic-commands)                                                             | #troubleshooting #diagnostics #health-check                 |
| Debug container (offline + Claude Code)                | [troubleshooting/debug-container](troubleshooting/debug-container)                                                                     | #troubleshooting #debug-container #claude #bedrock #offline |

---

## Scenario practices used here

- **One scenario = one directory** with a `README.md` (goal, prerequisites, steps, verification).
- **Kustomize** for ConfigMaps built from files (keeps large blobs out of hand-edited YAML).
- **Lab defaults** are clearly labeled and must be replaced before use outside a disposable cluster.
- **Helm releases** are version-pinned; local chart examples require a commit-pinned checkout. Render or lint values before install, use atomic installs, and follow the release CRD-upgrade procedure because Helm does not upgrade or delete CRDs.
- **Kubernetes resources** use `kubectl diff` before server-side apply with an explicit field manager. Do not force field conflicts outside a reviewed adoption transfer.
- **Secrets stay out of Git, custom resources, command output, and status.** Examples create only Secret references or interactive lab inputs.
- **Use real shipped components.** When a release includes an application such as Tomo, deploy that catalog artifact and inspect its generated resources instead of inventing a demonstration extension.
- **Keep supported and proposed contracts distinct.** Runnable examples use released APIs. A contract-design example must identify every proposed API, render offline, and remain blocked from server-side apply until its CRD, validation, status, controller, and conformance checks exist.

---

## Contributing

Add a subdirectory with `README.md` plus manifests or scripts. Prefer small, composable steps and document ordering (e.g. ConfigMap before Deployment volume mount).

**Lint and format** ([pre-commit](https://pre-commit.com)):

- Run `pre-commit install` from the repository root, then `pre-commit run --all-files`.
