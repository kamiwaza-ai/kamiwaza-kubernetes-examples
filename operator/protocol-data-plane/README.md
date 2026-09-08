# The governed endpoint, and the fence around its configuration

**Scenario:** run the protocol-aware data plane the operator renders, and understand the one guard that decides whether it may be programmed at all. Configuration is authority-shaped — whoever can write it decides where traffic goes — so the channel that carries it is fenced, per-replica authenticated, and bounded in time.

**Tags:** #operator #transport #fencing #data-plane #decision-service #fail-closed

No provider name, version, or native resource type appears in this directory, and none appears in platform status. The hop names and the status fields describe roles, so an installation that changes plane implementation changes no tenant-visible field.

## What the plane is, and what it is not

It terminates tool, agent, and model protocols and holds **no authority of its own**. Every surface by which it could make an authorization, quota, admission, or policy decision is rendered disabled, and any that is requested blocks reconciliation instead of being reported as advisory. It watches no Kubernetes API, holds no credential for one, introduces no cluster-scoped object, no node component, and no admission webhook, and it sits behind the customer's own ingress, gateway, and mesh rather than replacing any of them.

The five plane-side surfaces the platform disables and publishes as disabled: `credentialValidation`, `policyEvaluation`, `rateLimiting`, `budgetControl`, `contentGuards`.

The plane is also **not a replacement for the direct path**. A served model keeps publishing its own in-cluster address, so both paths can carry traffic at once, and the platform reports what it observed on each rather than inferring one from the other.

## The fence

| Property                                   | What it prevents                                                                       |
| ------------------------------------------ | -------------------------------------------------------------------------------------- |
| per-replica mutual TLS on the channel      | one compromised or superseded replica accepting configuration on behalf of the others  |
| one monotonic fencing token per commit     | a superseded writer committing after a takeover, using its own stale view of the Lease |
| the writer bound to the token it presents  | a second process copying a token it observed                                           |
| a signed revision digest                   | a commit whose content does not match what was approved                                |
| a bounded last-known-good lifetime         | an admitted configuration serving after the credential that authorized it expired      |
| every check before any route is programmed | a stale writer whose rejection lands after traffic has already been rerouted           |

A refused commit changes nothing: the previous revision, the credential bindings, and the watermark are left exactly as they were. Every one of those failures publishes `ConfigChannelUnauthenticated`, and it is terminal.

**The bound comes from policy, not from this component.** It is `maxConnectionAge` on the `ControlPlaneToProtocolDataPlane` hop, or where that hop expresses mutual TLS without a stated age, the referenced client identity's validity. An absent or unparseable bound is refused rather than defaulted, because a default invented here would be an expiry policy the platform chose for an administrator who never stated one.

Past the bound, the protected routes **close**. Serving a route whose authorization configuration has passed its bounded lifetime answers requests against a decision nobody has confirmed is still current, and an unreachable model is a smaller failure than an unauthorized answer. The expired revision is retained so an operator can still see which one it was.

## The decision hop is the other load-bearing one

`ProtocolDataPlaneToDecisionService` carries the authorization answer for every request. It is mutually authenticated, bounded, and fail-closed: unreachable or past its deadline means the request is denied with `DecisionServiceUnavailable` **before any backend I/O**, not answered on a stale opinion.

Edge credentials are never replayed upstream. Every hop authenticates independently with its own platform-issued identity, so a token accepted at the edge does not become an upstream credential.

## Files

| File                                                             | Purpose                                                                            |
| ---------------------------------------------------------------- | ---------------------------------------------------------------------------------- |
| [transport-policy-fragment.yaml](transport-policy-fragment.yaml) | the plane's hops, with the fencing bound on the configuration hop                  |
| [unbounded-channel-refused.yaml](unbounded-channel-refused.yaml) | refused on purpose, by the channel rather than by the loader: no bound, no channel |
| [plane-enable-patch.yaml](plane-enable-patch.yaml)               | select the plane explicitly on an existing platform                                |
| [plane-disable-patch.yaml](plane-disable-patch.yaml)             | run without it                                                                     |

## Read this before enabling anything

`spec.components.protocolDataPlane.enabled` **defaults to `true`** in this CRD, because the governed endpoint is a platform requirement rather than an option. A platform object applied against this CRD without stating the field is defaulted to enabled by the API server. So `plane-enable-patch.yaml` makes the selection explicit and reviewable; it does not turn on something that was off. Check what your object says rather than assuming:

```bash
kubectl -n kamiwaza-examples get kamiwazaplatform kamiwaza \
  -o jsonpath='{.spec.components.protocolDataPlane.enabled}{"\n"}'
```

With the plane disabled the operator renders no plane workload, constructs no configuration channel, publishes no `status.protocolDataPlane`, and reports no plane reason — not an empty object a reader has to interpret. A commit presented to a channel that was never constructed is an error rather than a rejection, because the caller reached a path a disabled capability should never reach.

Enabling it is refused **with nothing mutated** when reviewed release data names no digest for the plane image, when any plane-side authority surface is requested, or when the replica count contradicts the profile. A blocked installation is one an operator can read, not one half applied.

## Steps

1. **Bound the channel first.** Merge `transport-policy-fragment.yaml`'s section into the `AdminCapabilityPolicy` document the operator chart mounts and bump `adminPolicy.revision`. Without the bound the plane blocks with `ConfigChannelUnauthenticated`, which is the correct outcome and not a bug to work around.

2. **Pin the image.** The platform names the image it runs: `capability: protocolDataPlane`, `role: application`, by digest. See [../quickstart/kamiwaza-platform.yaml](../quickstart/kamiwaza-platform.yaml).

3. **State the selection.**

```bash
kubectl -n kamiwaza-examples patch kamiwazaplatform kamiwaza \
  --type merge --patch-file operator/protocol-data-plane/plane-enable-patch.yaml
```

## Verification

```bash
# Everything the platform publishes about the plane. Four fields, and a fifth
# would be a design change: there is deliberately no provider identity here.
kubectl -n kamiwaza-examples get kamiwazaplatform kamiwaza \
  -o jsonpath='{.status.protocolDataPlane.converged}{"\t"}{.status.protocolDataPlane.reloadClass}{"\t"}{.status.protocolDataPlane.configurationDigest}{"\n"}'

# The positive list of disabled authority surfaces. All five, every time.
kubectl -n kamiwaza-examples get kamiwazaplatform kamiwaza \
  -o jsonpath='{range .status.protocolDataPlane.disabledAuthoritySurfaces[*]}{.}{"\n"}{end}'

# The workload, its Service, and its ServiceAccount all carry one name.
kubectl -n kamiwaza-examples get deployment,service,serviceaccount kamiwaza-dataplane

# No API credential is mounted into the plane's pod, which is condition two of
# the decision that allows the operator to render it at all.
kubectl -n kamiwaza-examples get deployment kamiwaza-dataplane \
  -o jsonpath='{.spec.template.spec.automountServiceAccountToken}{"\n"}'

# The configuration digest is recorded on the pod template, so an unchanged
# digest leaves that template byte for byte identical and nothing rolls:
# record it, reconcile, and compare.
kubectl -n kamiwaza-examples get deployment kamiwaza-dataplane \
  -o jsonpath='{.spec.template.metadata.annotations.kamiwaza\.ai/dataplane-config-digest}{"\n"}'
```

## Failure reasons

| Reason                            | Trigger                                                                                     | Retry class                                             |
| --------------------------------- | ------------------------------------------------------------------------------------------- | ------------------------------------------------------- |
| `ConfigChannelUnauthenticated`    | no per-replica identity, no fencing, a stale writer after takeover, or no bounded lifetime  | blocked before route programming; terminal              |
| `DecisionServiceUnavailable`      | the decision call is unreachable, late, or unauthenticated                                  | the request is denied; retry follows the observed cause |
| `ProviderAuthoritySurfaceEnabled` | a plane-side authority surface is enabled                                                   | blocked until it is disabled                            |
| `ProviderIntentUntranslatable`    | the selected plane has no pre-dispatch decision hook or cannot present a client certificate | regulated refuses; Full reports the degraded capability |

## On an installation that has not migrated

The plane is the one capability in this batch whose CRD default is on, so state the field rather than inferring it. With it disabled, nothing in this directory is in effect: no channel, no status, no reason, and the direct served-model path is untouched. With it enabled but no bound in policy, the plane is blocked and no route is programmed — closed rather than serving unfenced configuration.

## How this example was validated

| File                                                  | Validated with                                                                                                                                                                                                                                                                                                                                                                                                                    |
| ----------------------------------------------------- | --------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| `transport-policy-fragment.yaml`                      | The operator's own loader, then `Policy.ValidateCrossReferences` — accepted in the Full and regulated profiles. Then `dataplane.ChannelLifetimeFrom` — a stated bound of `30m0s` — and `dataplane.ChannelFor` with the plane enabled — a channel constructed, not blocked. Also `transport-security.schema.yaml` (`jsonschema`, Draft 2020-12) — valid.                                                                           |
| `unbounded-channel-refused.yaml`                      | Same loader — accepted. Same cross-reference rules — accepted. Then `dataplane.ChannelFor` — **refused on purpose**: no channel constructed, blocked, `reason=ConfigChannelUnauthenticated`, message `administrator policy sets no bounded lifetime for the control-plane-to-data-plane configuration hop, so an admitted configuration could keep serving after the credential that authorized it expired`. Same schema — valid. |
| `plane-enable-patch.yaml`, `plane-disable-patch.yaml` | `kubectl apply --dry-run=server --validate=strict` against a live cluster, merged into a complete platform object — both accepted. The control, the same merge with `bogusField` under `protocolDataPlane`, was rejected as `unknown field "spec.components.protocolDataPlane.bogusField"`.                                                                                                                                       |

The refused fragment is the one worth reading twice: it is schema-valid, the loader accepts it, and every cross-reference rule passes. Its refusal comes from the channel guard, which is why the check above constructs the guard rather than trusting the contract text. The same call with the plane disabled produced no channel, no outcome, and no reason, which is the dual-topology claim in this README verified rather than asserted.
