# Egress: closed by default, opened by named destination classes

**Scenario:** let the platform reach the outside world without giving any workload an open path. Egress starts closed, opens one named destination class at a time, and enforces each class differently depending on who dials it.

**Tags:** #security #transport #egress #mtls #oauth #enforcing-proxy

Every host in this directory is under `example.invalid`, which RFC 6761 guarantees cannot resolve. No credential, certificate body, private host, or working proxy endpoint appears anywhere: credentials are exact-name Secret references the administrator creates, and authorities are referenced as objects.

## The shape

Administrator policy declares destination classes. A `KamiwazaExtension` or `ModelDeployment` then selects a class **by name** and defines no host, credential, proxy, or exception of its own. No selected class means no external allowance.

Four networks are denied in every profile and no policy can shorten the list: loopback, link-local, cloud metadata, and unapproved private ranges.

## `enforcementMode` follows who dials

This is the field to read first, and it is not a preference.

| Mode                        | For                                                | What enforces the destination                                                                                                                                        |
| --------------------------- | -------------------------------------------------- | -------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| `PolicyAwareDialer`         | a client the platform builds                       | the platform's resolver and dialer validate name, port, every resolved address, every redirect, and DNS re-resolution before connecting or loading a credential      |
| `PolicyAwareDialerViaProxy` | a platform client that must egress through a proxy | the same dialer, through the named proxy                                                                                                                             |
| `EnforcingProxy`            | an arbitrary model or extension image              | an administrator-owned proxy whose protected evidence proves it enforces destination policy, while the image's own direct external egress is denied by NetworkPolicy |

The arbitrary-image classes are `ExtensionExternalAPI` and `PackageRepository`. Giving either a policy-aware dialer is refused: the dialer is code inside the platform's own clients, and it cannot be given to an image the platform did not build. Declaring it anyway would publish an enforcement nobody performs, which is worse than none because status would report the destination as bounded.

## Client authentication is a separate axis from transport

One closed typed union covers internal hops and egress destinations alike: `None`, `MutualTLS`, `WorkloadIdentityX509`, `OAuth2ClientCredentials`, `CertificateBoundOAuth`, `WorkloadIdentityJWT`. Exactly one variant block is permitted, and fields from any other variant are rejected.

Three rules bite in practice:

- **A client identity belongs to exactly one destination class.** Sharing it makes one far side's compromise a credential for the other, and makes rotating one destination's identity a rotation of the other whether it was ready or not.
- **`maxConnectionAge` may not exceed the credential's lifetime.** A connection older than the certificate presented in its handshake is an authenticated session whose authentication has expired. The bound is the certificate's, not a token's: a token is re-fetched inside a live connection.
- **Credentials load after the destination is verified**, never before, and never appear in a container argument or a log line.

## Files

| File                                                                       | Purpose                                                                                      |
| -------------------------------------------------------------------------- | -------------------------------------------------------------------------------------------- |
| [transport-policy-fragment.yaml](transport-policy-fragment.yaml)           | five destination classes, two client identities, one enforcing proxy, the denied network set |
| [shared-client-identity-refused.yaml](shared-client-identity-refused.yaml) | refused on purpose: one client identity bound to two destination classes                     |
| [arbitrary-image-dialer-refused.yaml](arbitrary-image-dialer-refused.yaml) | refused on purpose: a policy-aware dialer declared for an arbitrary image                    |

## Steps

1. **Declare the authorities first.** Every `requiredAuthorities` entry has to name an authority the policy declares, or the whole policy is refused at load with `EgressAuthorityMissing`. Anchors union, so a far side mid-rotation can be covered by two entries at once.

2. **Merge the fragment** into the `AdminCapabilityPolicy` document the operator chart mounts and bump `adminPolicy.revision`.

3. **Select classes from workload intent.** An extension or model deployment names the classes it needs. It cannot add a host, and it cannot widen a class it selects.

4. **Prove the proxy** if any class uses `EnforcingProxy` or `PolicyAwareDialerViaProxy`. The proxy's `evidenceRef` is protected evidence that it enforces destination policy itself; a proxy that only forwards is not enforcement. Absent or stale evidence reports `EgressEnforcementUnavailable`, and a bounded profile stays closed rather than falling back to direct egress.

## Verification

```bash
# Public egress evidence: class identifiers, enforcement state, and the policy
# digest. Exact host and port matrices and proxy endpoints are deliberately
# absent here -- they stay in administrator policy and in protected evidence.
kubectl -n kamiwaza-examples get kamiwazaplatform kamiwaza \
  -o jsonpath='{range .status.advisories[?(@.capability=="trust")]}{.reason}{"\t"}{.message}{"\n"}{end}'

# An extension's own transport condition, which is where a selected class that
# cannot be satisfied surfaces.
kubectl -n kamiwaza-examples get kamiwazaextension -o jsonpath='{range .items[*]}{.metadata.name}{"\t"}{range .status.conditions[?(@.type=="TransportReady")]}{.status}{"\t"}{.reason}{"\t"}{.message}{end}{"\n"}{end}'

# The floor that keeps an arbitrary image off the internet. Its egress rules
# should reach the approved proxy and nothing else.
kubectl -n kamiwaza-examples get networkpolicy
```

## Failure reasons

| Reason                         | Trigger                                                                    | Retry class                                   |
| ------------------------------ | -------------------------------------------------------------------------- | --------------------------------------------- |
| `DestinationUndeclared`        | the workload selected no approved class                                    | terminal until intent changes                 |
| `DestinationDenied`            | host, port, redirect, resolved address, or DNS rebind violates the class   | terminal for that request                     |
| `EgressAuthorityMissing`       | a class requires an authority the policy does not declare                  | terminal until policy changes                 |
| `EgressAuthorityInvalid`       | malformed material, or no valid anchor                                     | terminal until the source changes             |
| `EgressEnforcementUnavailable` | the dialer or the enforcing proxy is unreachable, or its evidence is stale | transient; a bounded profile stays closed     |
| `EgressTrustPending`           | the distribution or its cross-namespace copy is not published yet          | transient with bounded backoff                |
| `EgressTrustReadFailed`        | API timeout or throttling                                                  | transient with exponential backoff and jitter |
| `EgressTrustForbidden`         | the exact-name read or publication was denied by RBAC                      | terminal until installation policy changes    |
| `PlaintextDenied`              | a plaintext or private destination has no allowed exception                | terminal until policy changes                 |

## On an installation that has not migrated

Nothing here changes it. With no `transport.egress` section the installation keeps whatever outbound behaviour it has today; this contract replaces an unrestricted allowance rather than tightening one silently, so the tightening only happens when the section is merged. The first symptom of adopting it is a workload reporting `DestinationUndeclared` — which is the contract working, and is fixed by naming the class that workload needs.

## How this example was validated

| File                                  | Validated with                                                                                                                                                                                                                                                               |
| ------------------------------------- | ---------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| `transport-policy-fragment.yaml`      | The operator's own loader, `adminpolicy.LoadTransportPolicy`, then `Policy.ValidateCrossReferences` — accepted in the Full and regulated profiles. Also `transport-security.schema.yaml` (`jsonschema`, Draft 2020-12) — valid.                                              |
| `shared-client-identity-refused.yaml` | Same loader — shape accepted. Same cross-reference rules — **refused on purpose**: `client identity "shared-egress" is already bound to destination class "enterprise-directory"` (`ClientIdentityInvalid`). Same schema — valid.                                            |
| `arbitrary-image-dialer-refused.yaml` | Same loader — shape accepted. Same cross-reference rules — **refused on purpose**: `destination kind PackageRepository is dialled by an arbitrary image, which requires EnforcingProxy rather than PolicyAwareDialer` (`EgressEnforcementUnavailable`). Same schema — valid. |

Nothing in this directory is a Kubernetes object, so nothing was checked with `kubectl`, and there is no kustomization to build.
