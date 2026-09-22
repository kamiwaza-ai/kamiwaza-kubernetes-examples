# Governed protocol endpoint and configuration admission

**Scenario:** run the protocol-aware data plane that the operator renders, prove that it has no Kubernetes authority, and refuse a policy that leaves configuration unbounded.

**Tags:** #operator #transport #data-plane #decision-service #fail-closed

The data plane terminates tool, agent, and model protocols. It does not make authorization, quota, admission, or policy decisions. Every request uses the platform decision service before backend I/O. The workload has no Kubernetes API credential, cluster-scoped object, node component, or admission webhook.

The operator publishes these five provider-neutral authority surfaces as disabled:

- `credentialValidation`
- `policyEvaluation`
- `rateLimiting`
- `budgetControl`
- `contentGuards`

A served model keeps its direct in-cluster address. The governed endpoint is an additional path, not an implicit replacement.

## Files

| File                                                             | Purpose                                                                                       |
| ---------------------------------------------------------------- | --------------------------------------------------------------------------------------------- |
| [transport-policy-values.yaml](transport-policy-values.yaml)     | Complete Helm values with the Core and protocol data-plane transport hops                     |
| [unbounded-channel-refused.yaml](unbounded-channel-refused.yaml) | Complete Helm values that deliberately omit configuration-channel authentication and lifetime |
| [plane-enable-patch.yaml](plane-enable-patch.yaml)               | Explicitly enable the plane on an existing platform                                           |
| [plane-disable-patch.yaml](plane-disable-patch.yaml)             | Disable the plane and withdraw its serving resources                                          |

Both values files are complete `adminPolicy` chart overrides. Do not merge their hop lists by hand. Helm replaces lists, so a plane-only list would silently remove required Core transport hops.

## Prerequisites

Run [../quickstart](../quickstart/) first. Use the same release name and namespaces from that example. The platform manifest must pin `protocolDataPlane/application` to a reviewed digest.

`spec.components.protocolDataPlane.enabled` defaults to `true` in the CRD. These steps state the field explicitly so the result does not depend on defaulting.

## Prove disabled withdrawal

```bash
kubectl -n kamiwaza-examples patch kamiwazaplatform kamiwaza \
  --type merge \
  --patch-file operator/protocol-data-plane/plane-disable-patch.yaml

kubectl -n kamiwaza-examples wait \
  --for=condition=Ready kamiwazaplatform/kamiwaza \
  --timeout=120s

kubectl -n kamiwaza-examples get \
  deployment,service,serviceaccount,configmap \
  kamiwaza-dataplane --ignore-not-found

kubectl -n kamiwaza-examples get kamiwazaplatform kamiwaza \
  -o jsonpath='{.status.protocolDataPlane}{"\n"}'
```

Both final commands must print nothing. Disabling the capability removes the four serving resources and clears `status.protocolDataPlane`. Retained platform data and direct model Services are unchanged.

## Prove unbounded policy refusal

Install the deliberately invalid runtime policy while the plane is disabled:

```bash
helm upgrade kamiwaza-platform-operator "${OPERATOR_CHART}" \
  --namespace kamiwaza-examples-system \
  --reuse-values \
  --values operator/protocol-data-plane/unbounded-channel-refused.yaml \
  --wait \
  --timeout 5m

kubectl -n kamiwaza-examples patch kamiwazaplatform kamiwaza \
  --type merge \
  --patch-file operator/protocol-data-plane/plane-enable-patch.yaml

kubectl -n kamiwaza-examples wait \
  --for=condition=Blocked kamiwazaplatform/kamiwaza \
  --timeout=120s

kubectl -n kamiwaza-examples get kamiwazaplatform kamiwaza \
  -o jsonpath='{range .status.conditions[?(@.type=="Blocked")]}{.status}{"\t"}{.reason}{"\t"}{.message}{"\n"}{end}'

kubectl -n kamiwaza-examples get \
  deployment,service,serviceaccount,configmap \
  kamiwaza-dataplane --ignore-not-found
```

Expected reason: `ConfigChannelUnauthenticated`. No plane object or plane status section may exist. The refusal occurs before rendering.

## Apply the bounded policy

```bash
helm upgrade kamiwaza-platform-operator "${OPERATOR_CHART}" \
  --namespace kamiwaza-examples-system \
  --reuse-values \
  --values operator/protocol-data-plane/transport-policy-values.yaml \
  --wait \
  --timeout 5m

kubectl -n kamiwaza-examples wait \
  --for=condition=Ready kamiwazaplatform/kamiwaza \
  --timeout=180s

kubectl -n kamiwaza-examples rollout status \
  deployment/kamiwaza-dataplane \
  --timeout=180s
```

## Verify the live surface

```bash
# Provider-neutral status.
kubectl -n kamiwaza-examples get kamiwazaplatform kamiwaza \
  -o jsonpath='{.status.protocolDataPlane.converged}{"\t"}{.status.protocolDataPlane.reloadClass}{"\t"}{.status.protocolDataPlane.configurationDigest}{"\n"}'

# All five disabled authority surfaces. Use {@}; {.} prints blank lines for
# scalar list items with some kubectl JSONPath versions.
kubectl -n kamiwaza-examples get kamiwazaplatform kamiwaza \
  -o jsonpath='{range .status.protocolDataPlane.disabledAuthoritySurfaces[*]}{@}{"\n"}{end}'

# Complete plane inventory. All four objects use the same stable name.
kubectl -n kamiwaza-examples get \
  deployment,service,serviceaccount,configmap \
  kamiwaza-dataplane

# No service-account token is mounted.
kubectl -n kamiwaza-examples get deployment kamiwaza-dataplane \
  -o jsonpath='{.spec.template.spec.automountServiceAccountToken}{"\n"}'

# The ServiceAccount cannot read workload or configuration data.
kubectl auth can-i get secrets \
  --as system:serviceaccount:kamiwaza-examples:kamiwaza-dataplane \
  --namespace kamiwaza-examples
kubectl auth can-i get pods \
  --as system:serviceaccount:kamiwaza-examples:kamiwaza-dataplane \
  --namespace kamiwaza-examples
kubectl auth can-i list configmaps \
  --as system:serviceaccount:kamiwaza-examples:kamiwaza-dataplane \
  --namespace kamiwaza-examples
```

Expected values:

- `converged=true`
- `reloadClass=Rollout`
- exactly five disabled authority surfaces
- `automountServiceAccountToken=false`
- all three authorization checks return `no`

An unauthenticated request must fail closed at external authorization rather than reach a backend. Port-forward the Service in one terminal, then send a request in another:

```bash
kubectl -n kamiwaza-examples port-forward service/kamiwaza-dataplane 18080:8080
curl --include --max-time 15 http://127.0.0.1:18080/v1/models
```

The validated response was HTTP `403` with `external authorization failed`.

## Idempotence check

Record the Deployment identity, allow at least one normal platform requeue, then compare it again:

```bash
kubectl -n kamiwaza-examples get deployment kamiwaza-dataplane \
  -o jsonpath='{.metadata.resourceVersion}{"\t"}{.spec.template.metadata.annotations.kamiwaza\.ai/dataplane-config-digest}{"\t"}{.metadata.generation}{"\n"}'
```

An unchanged policy and model inventory must leave all three values unchanged. A content change moves the digest and rolls the Deployment.

## Current fencing gap

The bounded-policy admission above is enforced live. Full configuration-channel fencing is not yet implemented by the shipped workload path.

The operator currently renders a read-only ConfigMap and rolls the Deployment by content digest. `internal/component/dataplane/channel.go` models per-replica mutual TLS, monotonic fencing tokens, signed revisions, and last-known-good expiry, but no production writer or plane process calls that model. Therefore this example does **not** claim live proof of stale-writer rejection or route closure after expiry.

Release acceptance remains blocked until a reviewed data-plane image and operator-owned configuration writer implement that protocol end to end. Unit-only `PlaneChannel` evidence is not a substitute for the live channel.

## Validation evidence

This scenario was run against a fresh k0s installation through the declarative operator lifecycle.

- Disabled selection removed Deployment, Service, ServiceAccount, and ConfigMap and cleared plane status.
- Unbounded values passed Helm schema validation, then live reconciliation blocked with `ConfigChannelUnauthenticated` before rendering any plane resource.
- Bounded values converged the plane and platform to Ready.
- All four rendered objects were namespaced and owned by the same `KamiwazaPlatform` UID.
- The workload mounted only the plane ConfigMap, trust ConfigMap, and an `emptyDir`; it mounted no Secret or projected service-account token.
- Three Kubernetes authorization probes returned `no`.
- An unauthenticated `/v1/models` request returned HTTP `403` before backend dispatch.
- Deployment resource version, content digest, observed generation, and generation remained unchanged across normal requeues.
- Focused operator tests passed for the data-plane component, platform controller, and status aggregation.
