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

### Edge TLS must be proven

Each listener requires current `Programmed=True`, `ResolvedRefs=True`, and `Accepted=True` conditions. `Programmed` alone does not prove that references resolved. Otherwise, the outcome is `EdgeListenerUnverified`, and no issuer is derived from the listener.

### Emitted objects must be supported

Scheme redirect and `BackendTLSPolicy` are Extended Gateway API features. `RequireWhenSupported` emits them only when the GatewayClass advertises support. Otherwise, the platform reports `EdgeFeatureUnsupported`.

### "Verify if presented" is not accepted

Only the mode that requires a valid client certificate is expressible. The insecure fallback accepts absent and invalid certificates. A Gateway that reports this mode produces `EdgeInsecureValidationDetected`, and the contract is unsatisfied.

## The Gateway API floor is a hard gate, not advice

An edge client-certificate requirement needs Gateway API **v1.5.0** or later. On older bundles, the API server prunes the frontend validation fields. The Gateway remains admitted but enforces nothing, and the platform can report false success. The platform refuses the requirement during policy load:

```text
edge client certificates require the Gateway API floor:
transport.edge.clientCertificate.mode: mode RequireValid is refused: client
certificates need Gateway API v1.5.0 or later, and the attested range "1.4.0"
is not contained in >=1.5.0; no client-certificate field is written, because a
bundle below the floor prunes it silently and the Gateway would be accepted
while enforcing nothing (EdgeFeatureUnsupported)
```

Attesting nothing is refused the same way. The range comes from the `gatewayAPI` shared-capability attestation in administrator policy, so "we upgraded it" has to be stated where the platform can read it.

The clean validation cluster runs Gateway API `v1.5.0`. Strict server validation accepts the frontend client-certificate fields and rejects an unknown field at the same location.

## Files

| File                                                                                         | Purpose                                                                                      |
| -------------------------------------------------------------------------------------------- | -------------------------------------------------------------------------------------------- |
| [transport-policy-fragment.yaml](transport-policy-fragment.yaml)                             | the edge plane of one transport policy: listener, redirect, backend TLS, client certificates |
| [gateway-listener-contract.yaml](gateway-listener-contract.yaml)                             | reference shape for the administrator's Gateway listeners (not for applying as-is)           |
| [edge-client-authority-collision-refused.yaml](edge-client-authority-collision-refused.yaml) | refused on purpose: the edge client authority shares a ConfigMap with the trust bundle       |

The frontend client-certificate stanza lives in [../cac/gateway-frontend-validation.yaml](../cac/gateway-frontend-validation.yaml), with the CAC/PIV origin contract beside it. It is kept out of the listener file here because those fields need v1.5.0 while the listener fields work on every supported bundle, and one manifest that half-applies is worse than two that state their floor.

## Steps

1. Merge the fragment. Validate `transport-policy-fragment.yaml`, then merge its `transport` section into `AdminCapabilityPolicy`. Bump `adminPolicy.revision` because the policy ConfigMap is immutable.

2. Attest the Gateway API range. When you require edge client certificates, declare `gatewayAPI` at `v1.5.0` or later. Otherwise, remove `clientCertificate`.

3. Create the Gateway. Use `gateway-listener-contract.yaml` as the shape. Make the listener Secret name equal `transport.edge.listenerCertificateSecretName`.

4. Publish edge conformance evidence when `forwardingMode` is set. Gateway API defines no client-certificate header. The platform accepts certificate identity only with revision-bound evidence. Use [the edge conformance evidence record](../cac/edge-conformance-evidence.example.yaml).

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
| `gateway-listener-contract.yaml`               | `kubectl apply --dry-run=server --validate=strict` against Gateway API `v1.5.0`, with its existing namespace. The manifest was accepted. A control with an unknown listener TLS field was rejected, so the check was not vacuous.                                                                                                                            |

The Gateway API floor claim was also checked against the same cluster. The server accepted `../cac/gateway-frontend-validation.yaml` and rejected an unknown field under `spec.tls.frontend.default.validation`. The operator loader separately refused the same requirement when the attested range was `1.4.0`.
