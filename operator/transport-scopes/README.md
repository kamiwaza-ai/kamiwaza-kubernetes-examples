# Transport under a strict and a relaxed scope

**Scenario:** the same transport contract on two installations that differ only in how much the manager may see: one namespace or two explicitly approved namespaces. Namespace scope and transport policy are separate decisions that have to agree, and this directory is where they meet.

**Tags:** #operator #transport #namespaces #rbac #trust-distribution

## Two decisions, not one

[Namespace scopes](../namespace-scopes/) is the chart side: where the manager runs and which namespaces it may watch. This directory is the policy side: where the trust distribution is published and which identities are accepted. Choosing one does not choose the other, and getting them out of step is the failure this example exists to prevent.

| Scope                              | Chart side                                                                                                                                         | Transport side                                                                     |
| ---------------------------------- | -------------------------------------------------------------------------------------------------------------------------------------------------- | ---------------------------------------------------------------------------------- |
| strict, single namespace           | [`same-namespace-values.yaml`](../namespace-scopes/same-namespace-values.yaml)                                                                     | [`strict-single-namespace-transport.yaml`](strict-single-namespace-transport.yaml) |
| relaxed, separately placed manager | [`bounded-values.yaml`](../namespace-scopes/bounded-values.yaml) or [`all-namespaces-values.yaml`](../namespace-scopes/all-namespaces-values.yaml) | [`relaxed-manager-scope-transport.yaml`](relaxed-manager-scope-transport.yaml)     |

## Why the distribution has to be published per namespace

Because a `BackendTLSPolicy` certificate-authority reference is **namespace-local**. It cannot point at a central namespace, so a consumer in a namespace that has no copy of the distribution has no authority to verify its backend against — and the manager being _able_ to see that namespace does not put a copy in it.

`trust.targetNamespaces` is therefore not a convenience list. Every namespace whose workloads perform protected transport has to appear in it, and it has to be within what the chart's `adminPolicy.allowedTargetNamespaces` approves, which in turn has to be within `manager.watchNamespaces` unless the watch is cluster-wide.

A cross-namespace copy cannot carry an owner reference, so it carries the platform UID, the policy revision, and the content digest instead, with deterministic field ownership. The root finalizer prunes it when the namespace or the platform leaves scope — which means **removing a namespace from the approved list is a deletion**, not a no-op.

## What does not widen with the scope

Three things, and they are the reason a relaxed scope is a defensible choice rather than a loose one:

- **Authority keys.** They exist only in exact-name Secrets in the manager/security namespace, read through the API by the isolated signer. A target-namespace administrator cannot read or mount one at any scope, and the policy has no field that would let them.
- **Identity verification.** Trust-domain membership is not authorization. A hop that requires a workload identity names the exact identities it accepts, an empty accepted set is invalid rather than permissive, and there is no "anything in this trust domain" value for a wider cache to unlock.
- **Secret mutation.** With `watchAnyNamespace: true` the cache is cluster-wide and non-sensitive target rules become a ClusterRole, but Secret mutation stays in namespaced Roles limited to the approved targets.

All-namespace watch is an explicit relaxed authority boundary. It is not a fallback for a missing RoleBinding in bounded mode.

## The signer's name is scope-aware

The signer's objects are qualified by the platform's namespace and name — `kamiwaza-<namespace>-<platform>-transport-signer` — because the security namespace is shared. Two platforms managed by one manager would otherwise render one signer over the other's, and the loser would be signing with the winner's authority. That is a relaxed-scope hazard specifically: at single-namespace scope there is only ever one.

## Files

| File                                                                             | Purpose                                                                    |
| -------------------------------------------------------------------------------- | -------------------------------------------------------------------------- |
| [strict-single-namespace-transport.yaml](strict-single-namespace-transport.yaml) | Helm values for one watched namespace, publishing into exactly it          |
| [relaxed-manager-scope-transport.yaml](relaxed-manager-scope-transport.yaml)     | Helm values for a separately placed manager with two approved targets      |
| [scope-conflict-refused-values.yaml](scope-conflict-refused-values.yaml)         | refused on purpose, by the chart's own gate: both scopes asked for at once |

## Apply one scope

Complete the [fresh install](../fresh-install/) first. Keep its image, storage,
registry, and profile values. Then apply one namespace policy and its matching
transport policy:

```bash
export OPERATOR_CHART=../../kamiwaza-platform-operator/charts/kamiwaza-platform-operator

# Strict: manager and platform share one watched namespace.
helm upgrade kamiwaza-platform-operator "${OPERATOR_CHART}" \
  --namespace kamiwaza-examples-system \
  --reuse-values \
  --values operator/namespace-scopes/same-namespace-values.yaml \
  --values operator/transport-scopes/strict-single-namespace-transport.yaml \
  --wait --timeout 5m

# Relaxed: separately placed manager watches two approved namespaces.
helm upgrade kamiwaza-platform-operator "${OPERATOR_CHART}" \
  --namespace kamiwaza-examples-system \
  --reuse-values \
  --values operator/namespace-scopes/bounded-values.yaml \
  --values operator/transport-scopes/relaxed-manager-scope-transport.yaml \
  --wait --timeout 5m
```

Apply only one command for the scope you want. Each command sets one policy
revision and matching target list. The chart rejects a transport target outside
the selected watch and mutation boundaries.

## The refusal

```bash
helm template kamiwaza-platform-operator "${OPERATOR_CHART}" \
  --namespace kamiwaza-examples-system \
  --values operator/transport-scopes/scope-conflict-refused-values.yaml
```

```text
Error: execution error at (kamiwaza-platform-operator/templates/deployment.yaml:1:4):
manager.watchAnyNamespace=true requires manager.watchNamespaces to be empty
```

The chart refuses rather than picking one, because either choice would be an authority boundary nobody selected. Two neighbouring refusals from the same gate:

- `manager.watchAnyNamespace=true requires explicit adminPolicy.allowedTargetNamespaces` — a cluster-wide cache still needs its mutation targets named. Read authority and write authority are separate.
- `adminPolicy target namespace <name> is outside manager.watchNamespaces` — a bounded manager cannot be given a target it cannot watch, which would install a RoleBinding for a namespace nothing reconciles.

## Verification

```bash
# Read controller placement, cluster-wide watch, policy revision, and readiness.
kubectl -n kamiwaza-examples get kamiwazaplatform kamiwaza \
  -o go-template='{{.status.controllerNamespace}}{{"\t"}}{{if .status.watchAnyNamespace}}true{{else}}false{{end}}{{"\t"}}{{.status.adminPolicyRevision}}{{"\t"}}{{range .status.conditions}}{{if eq .type "Ready"}}{{.status}}{{end}}{{end}}{{"\n"}}'

# Strict scope publishes only to `kamiwaza-examples`.
kubectl -n kamiwaza-examples get configmap kamiwaza-trust-bundle \
  -o jsonpath='{.metadata.namespace}{"\t"}{.metadata.labels.transport\.kamiwaza\.io/bundle-digest}{"\t"}{.metadata.annotations.transport\.kamiwaza\.io/policy-revision}{"\n"}'
kubectl -n kamiwaza-examples-tenant get configmap kamiwaza-trust-bundle

# Relaxed scope publishes the same digest and revision to both approved
# namespaces.
for namespace in kamiwaza-examples kamiwaza-examples-tenant; do
  kubectl -n "${namespace}" get configmap kamiwaza-trust-bundle \
    -o jsonpath='{.metadata.namespace}{"\t"}{.metadata.labels.transport\.kamiwaza\.io/bundle-digest}{"\t"}{.metadata.annotations.transport\.kamiwaza\.io/policy-revision}{"\n"}'
done

# Target-namespace workloads cannot read either authority key. Both commands
# must print `no`.
kubectl auth can-i --as=system:serviceaccount:kamiwaza-examples:default \
  get secret kamiwaza-kamiwaza-examples-kamiwaza-client-authority \
  -n kamiwaza-examples-system
kubectl auth can-i --as=system:serviceaccount:kamiwaza-examples:default \
  get secret kamiwaza-kamiwaza-examples-kamiwaza-server-authority \
  -n kamiwaza-examples-system

# Signer runs in controller namespace and is named for its platform.
kubectl -n kamiwaza-examples-system get \
  deployment/kamiwaza-kamiwaza-examples-kamiwaza-transport-signer \
  service/kamiwaza-kamiwaza-examples-kamiwaza-transport-signer
```

## On an installation that has not migrated

Nothing here changes it. Scope already exists on every installation because manager installation selects it. Transport only exists after the matching Helm values are applied. An installation with no `adminPolicy.transport` publishes no distribution into any namespace.

## How this example was validated

| File                                     | Validated with                                                                                                                                                                                                  |
| ---------------------------------------- | --------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| `strict-single-namespace-transport.yaml` | `helm lint` and `helm template` with `same-namespace-values.yaml`; live strict-scope reconciliation; signer readiness; one trust distribution; target-ServiceAccount denial for exact authority Secret names.   |
| `relaxed-manager-scope-transport.yaml`   | `helm lint` and `helm template` with `bounded-values.yaml`; live bounded reconciliation; matching trust-distribution digests in both approved namespaces; authority keys retained only in controller namespace. |
| `scope-conflict-refused-values.yaml`     | `helm template` against the operator chart; refused on purpose with the message above. A valid single-scope control renders successfully.                                                                       |

These files are Helm values, not Kubernetes objects. `helm lint` and `helm template` validate their structure before reconciliation. Live checks prove the target list agrees with installed read and mutation boundaries.
