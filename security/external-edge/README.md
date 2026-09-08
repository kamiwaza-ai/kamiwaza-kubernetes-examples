# The external edge: what the platform requires, and what it will not claim

**Scenario:** publish platform paths through a Gateway the administrator owns, with the listener certificate the platform issues, and read back what the platform will and will not assert about that edge. The interesting half is the refusals: an edge the platform cannot prove is an edge the platform reports as unproven.

**Tags:** #security #transport #gateway-api #external-edge #mtls

Every value here is an obviously synthetic placeholder. The only host is the reserved documentation domain `kamiwaza.example.com`, no certificate body or key appears in any file, and the material the platform issues is referenced by object name.

## The division of labour

North-south transport is expressed only through Gateway API standard kinds. The operator creates no `Gateway`, no mesh object, and no implementation-specific routing or policy object.

| Object                            | Who creates it | Purpose                                                                        |
| --------------------------------- | -------------- | ------------------------------------------------------------------------------ |
| `Gateway`                         | administrator  | terminates public TLS; the platform reads its status and never writes it       |
| listener certificate `Secret`     | platform       | the material `certificateRefs` names                                           |
| `HTTPRoute`, `ReferenceGrant`     | platform       | attaches platform paths, permits cross-namespace references                    |
| `BackendTLSPolicy`                | platform       | requires the gateway to originate TLS to a platform Service                    |
| edge client-authority `ConfigMap` | platform       | the `ca.crt` the Gateway references for frontend client-certificate validation |

## Three things the platform refuses to pretend

**It will not assert edge TLS it has not proven.** For every listener it depends on, the proof is `Programmed=True` **and** `ResolvedRefs=True` **and** `Accepted=True`, each at the object's own generation. `Programmed` alone reports that configuration was generated, not that references resolved. Short of that the outcome is `EdgeListenerUnverified`, and no issuer is derived from an assertion that the edge terminated TLS.

**It will not emit an object the implementation would reject.** Scheme redirect and `BackendTLSPolicy` are Extended Gateway API features, so `RequireWhenSupported` emits them where the GatewayClass advertises the feature and reports `EdgeFeatureUnsupported` where it does not.

**It will not accept "verify if presented".** Only the mode that requires a valid client certificate is expressible. The insecure fallback mode admits an absent certificate and an invalid certificate alike; a Gateway reporting it produces `EdgeInsecureValidationDetected` and the published contract is treated as unsatisfied.

## The Gateway API floor is a hard gate, not advice

An edge client-certificate requirement needs Gateway API **v1.5.0** or later. Below that bundle the frontend validation fields are _pruned by the API server rather than rejected_, so the Gateway is admitted and enforces nothing while the platform would report success. The platform therefore refuses the requirement at policy load rather than writing a field that will vanish:

```text
edge client certificates require the Gateway API floor:
transport.edge.clientCertificate.mode: mode RequireValid is refused: client
certificates need Gateway API v1.5.0 or later, and the attested range "1.4.0"
is not contained in >=1.5.0; no client-certificate field is written, because a
bundle below the floor prunes it silently and the Gateway would be accepted
while enforcing nothing (EdgeFeatureUnsupported)
```

Attesting nothing is refused the same way. The range comes from the `gatewayAPI` shared-capability attestation in administrator policy, so "we upgraded it" has to be stated where the platform can read it.

This is not hypothetical. The cluster these examples were validated against runs Gateway API `v1.4.0`, and the API server there rejects `spec.tls` on a `Gateway` outright under strict decoding — the same field that a standard-channel install prunes.

## Files

| File                                                                                         | Purpose                                                                                      |
| -------------------------------------------------------------------------------------------- | -------------------------------------------------------------------------------------------- |
| [transport-policy-fragment.yaml](transport-policy-fragment.yaml)                             | the edge plane of one transport policy: listener, redirect, backend TLS, client certificates |
| [gateway-listener-contract.yaml](gateway-listener-contract.yaml)                             | reference shape for the administrator's Gateway listeners (not for applying as-is)           |
| [edge-client-authority-collision-refused.yaml](edge-client-authority-collision-refused.yaml) | refused on purpose: the edge client authority shares a ConfigMap with the trust bundle       |

The frontend client-certificate stanza lives in [../cac/gateway-frontend-validation.yaml](../cac/gateway-frontend-validation.yaml), with the CAC/PIV origin contract beside it. It is kept out of the listener file here because those fields need v1.5.0 while the listener fields work on every supported bundle, and one manifest that half-applies is worse than two that state their floor.

## Steps

1. **Merge the fragment.** `transport-policy-fragment.yaml` has `transport` at the root, which is what the published schema declares and what the operator's loader accepts, so validate it before merging. Merge the section into the `AdminCapabilityPolicy` document the operator chart mounts and bump `adminPolicy.revision`. The policy ConfigMap is immutable, so a changed document needs a new revision.

2. **Attest the Gateway API range.** Declare the `gatewayAPI` shared capability with a range at or above `v1.5.0` if you require edge client certificates. Below it, drop `clientCertificate` or the policy is refused.

3. **Create the Gateway.** Use `gateway-listener-contract.yaml` as the shape; the listener Secret name must match `transport.edge.listenerCertificateSecretName`.

4. **Publish the edge conformance evidence** if `forwardingMode` is set. Gateway API standardizes no client-certificate header, so certificate identity reaches the origin only through administrator-owned edge behaviour, and the platform credits it only against recorded, revision-bound evidence. The record shape is [../cac/edge-conformance-evidence.example.yaml](../cac/edge-conformance-evidence.example.yaml).

## Verification

```bash
# The three conditions the platform credits, per listener, at the observed generation.
kubectl -n kamiwaza-examples get gateway kamiwaza-gateway \
  -o jsonpath='{range .status.listeners[*]}{.name}{"\t"}{range .conditions[*]}{.type}={.status}{" "}{end}{"\n"}{end}'

# The transport outcome and every advisory attached to it.
kubectl -n kamiwaza-examples get kamiwazaplatform kamiwaza \
  -o jsonpath='{range .status.components[?(@.name=="trust")]}{.phase}{"\t"}{.reason}{"\t"}{.message}{"\n"}{end}'
kubectl -n kamiwaza-examples get kamiwazaplatform kamiwaza \
  -o jsonpath='{range .status.advisories[?(@.capability=="trust")]}{.reason}{"\t"}{.message}{"\n"}{end}'

# The standard objects the platform owns at the edge.
kubectl -n kamiwaza-examples get httproute,backendtlspolicy,referencegrant
kubectl -n kamiwaza-examples get configmap kamiwaza-edge-client-ca
kubectl -n kamiwaza-examples get secret kamiwaza-gateway-tls
```

## Failure reasons

| Reason                           | Trigger                                                                            | Retry class                                             |
| -------------------------------- | ---------------------------------------------------------------------------------- | ------------------------------------------------------- |
| `EdgeListenerUnverified`         | listener status absent or stale                                                    | transient; a regulated profile stays Blocked            |
| `EdgeFeatureUnsupported`         | a required Gateway API feature is not advertised, or the bundle is below the floor | terminal until the implementation or the policy changes |
| `EdgeInsecureValidationDetected` | the Gateway reports insecure frontend validation                                   | terminal until the Gateway changes                      |

## On an installation that has not migrated

Nothing here changes it. With no `transport` section in administrator policy the platform reports no hop plane, emits no listener certificate intent, and publishes no edge objects for this contract — exactly what it did before. Adopting the edge is merging the fragment and bumping the revision, and it is reversible by removing them.

## How this example was validated

| File                                           | Validated with                                                                                                                                                                                                                                                                                                                                               |
| ---------------------------------------------- | ------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------ |
| `transport-policy-fragment.yaml`               | The operator's own loader, `adminpolicy.LoadTransportPolicy`, then `Policy.ValidateCrossReferences` — accepted in the Full and regulated profiles with `>=1.5.0 <2.0.0` attested, and refused with `EdgeFeatureUnsupported` at `1.4.0` and with nothing attested. Also the published `transport-security.schema.yaml` (`jsonschema`, Draft 2020-12) — valid. |
| `edge-client-authority-collision-refused.yaml` | Same loader — shape accepted. Same cross-reference rules — **refused on purpose** in both profiles with `EdgeInsecureValidationDetected` naming the shared ConfigMap. Same schema — valid, which is the point: the schema cannot express a rule needing two sections at once.                                                                                |
| `gateway-listener-contract.yaml`               | `kubectl apply --dry-run=server --validate=strict` against a live cluster's Gateway API `v1.4.0` CRDs, with the namespace substituted for one that exists — accepted. The control, the same object with one unknown field under `listeners[].tls`, was rejected as `unknown field "spec.listeners[1].tls.bogusField"`, so the check is not vacuous.          |

The Gateway API floor claim was checked the same way, on the same cluster: `../cac/gateway-frontend-validation.yaml` is rejected there as `unknown field "spec.tls"`, because that bundle is `v1.4.0`.
