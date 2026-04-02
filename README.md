# Kamiwaza Kubernetes examples

Scenario workflows for running **[Kamiwaza](https://kamiwaza.ai)** on Kubernetes next to the **[Kamiwaza Deploy](https://github.com/kamiwaza/deploy)** Helm charts. This repository uses a scenario-first structure: curated directories per use case, explicit prerequisites, ordered steps, and verification.

**These manifests are references for learning and lab environments.** Harden secrets, DNs, hostnames, and TLS before production.

---

## Official documentation

- Platform deployment and architecture: **Kamiwaza Deploy** repo (`cluster/helmfile.yaml.gotmpl`, `docs/`).
- This repo does **not** replace those docs; it adds copy-paste scenarios you can run after (or beside) a normal install.

---

## Prerequisites (typical workflow)

Assumed for most scenarios unless stated otherwise:

| Requirement          | Notes                                                                    |
| -------------------- | ------------------------------------------------------------------------ |
| Kubernetes cluster   | CNCF-conformant; Kind is common for local dev.                           |
| `kubectl`            | Configured for your cluster context.                                     |
| Helm 3               | Used with **Helmfile** from the Deploy repo for app scenarios.           |
| Kustomize            | Via `kubectl apply -k` (built into recent `kubectl`).                    |
| Namespace `kamiwaza` | Created by Deploy Helmfile’s `prepare` hook before the umbrella release. |

```bash
kubectl create namespace kamiwaza --dry-run=client -o yaml | kubectl apply -f -
kubectl config set-context --current --namespace=kamiwaza
```

**Clone this repository** (standalone or next to Deploy):

```bash
git clone <YOUR_GIT_REMOTE>/kamiwaza-kubernetes-examples.git
cd kamiwaza-kubernetes-examples
```

Use your organization’s fork or this copy when vendored inside the Deploy monorepo.

---

## Scenario index

Category indexes:

- **Security matrix:** [security/README.md](security/README.md)
- **Deployment matrix:** [deployment/README.md](deployment/README.md)

| Scenario                                            | Path                                                           | Tags                                |
| --------------------------------------------------- | -------------------------------------------------------------- | ----------------------------------- |
| Environment profile matrix (lite/full/dev/dev-full) | [deployment/env-profile-matrix](deployment/env-profile-matrix) | #deployment #topology #helmfile     |
| Consent modal + classification banners              | [security/consent-banner](security/consent-banner)             | #security #compliance #helm-values  |
| CAC / PIV login (mTLS forwarding)                   | [security/cac](security/cac)                                   | #security #cac #mtls #helm-values   |
| ReBAC (relationship-based access control)           | [security/rebac](security/rebac)                               | #security #rebac #auth #helm-values |
| LDAP + Keycloak federation                          | [security/ldap](security/ldap)                                 | #security #ldap #keycloak           |

---

## Scenario practices used here

- **One scenario = one directory** with a `README.md` (goal, prerequisites, steps, verification).
- **Kustomize** for ConfigMaps built from files (keeps large blobs out of hand-edited YAML).
- **Optional values snippets** (`*-snippet.yaml`) to merge into Deploy `cluster/values/overrides.yaml` rather than forking charts.
- **Lab defaults** clearly labeled: demo passwords, `*.kamiwaza.test`, `dc=kamiwaza,dc=local` (aligned with stock Kind / Kamiwaza Deploy dev install).

---

## Contributing

Add a subdirectory with `README.md` plus manifests or scripts. Prefer small, composable steps and document ordering (e.g. ConfigMap before Deployment volume mount).

**Lint and format** ([pre-commit](https://pre-commit.com)):

- **Inside the Deploy repo** (git root = deploy): `make pre-commit-install` then hooks run on commit for paths under `kamiwaza-kubernetes-examples/`; `make lint-pre-commit` runs all hooks once.
- **Standalone clone** (git root = this tree): `pre-commit install` from the repository root, then `pre-commit run --all-files`.
