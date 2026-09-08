# Failure modes: what the platform says when something it does not own is missing

**Scenario:** read the transport plane's failure surface before you meet it in production. Every dependency the platform does not own — an external PKI, a certificate controller, the signer, the decision service, an enforcing proxy, a Gateway — has a named outcome, a retry class, and an owner.

**Tags:** #security #transport #failure #fail-closed #reasons

Three refused documents are published here alongside a loadable one, because the refusals are the part that teaches. Every value is a placeholder; no credential or certificate body appears in any file.

## The two kinds of failure, and why they are not the same

**Terminal** means retrying the same input cannot clear it: rejected material, a denied authorization decision, a policy that refuses what it was asked. The object stays failed and the platform stops asking.

**Transient** means the dependency is unavailable rather than wrong: a refused dial, a timeout, DNS, a 5xx, throttling, a conflict. The object stays in a non-terminal phase with a reason that names the dependency, and backoff is bounded with jitter so a dependency shared by many objects is not hit by a synchronised herd when it recovers.

Getting this backwards is expensive in both directions. A terminal failure retried forever hides a decision somebody has to make; a transient failure marked terminal turns a thirty-second outage into a manual recovery. An X.509 verification failure is terminal. A dial failure to the same endpoint is transient.

**One dependency's outage does not abort the rest of the reconcile.** A later independent step still runs, so a Core API blip does not silently skip provisioning that had nothing to do with it.

## The failure surface, by dependency

| Dependency                                  | When it is missing or wrong                                                     | Reason                                                                                | Class                                               |
| ------------------------------------------- | ------------------------------------------------------------------------------- | ------------------------------------------------------------------------------------- | --------------------------------------------------- |
| external PKI (`AdministratorSupplied`)      | chain unordered, unvalidatable, or a required key absent                        | `SuppliedMaterialInvalid`                                                             | terminal until the material changes                 |
| external PKI                                | inside the expiry warning window                                                | `SuppliedMaterialExpiring`                                                            | advisory before expiry, blocking after              |
| certificate controller (`ControllerIssued`) | certificate intent created and never fulfilled                                  | `IssuerIntentUnfulfilled`                                                             | transient, escalating on a bounded deadline         |
| the isolated signer                         | unreachable, slow, or answering with something unparseable                      | `WorkloadIdentityUnavailable`, `WorkloadIdentityTimeout`, `WorkloadIdentityMalformed` | transient, transient, terminal                      |
| the signer                                  | token, CSR, peer identity, or source policy invalid                             | `WorkloadIdentityRejected`                                                            | terminal until the input changes                    |
| the decision service                        | unreachable or past its deadline                                                | `DecisionServiceUnavailable`                                                          | the request is denied before any backend I/O        |
| an enforcing proxy                          | unreachable, or its evidence stale                                              | `EgressEnforcementUnavailable`                                                        | transient; a bounded profile stays closed           |
| the Gateway                                 | status absent or stale                                                          | `EdgeListenerUnverified`                                                              | transient; regulated stays Blocked                  |
| the Gateway                                 | a required Extended feature is not advertised, or the bundle is below the floor | `EdgeFeatureUnsupported`                                                              | terminal until the implementation or policy changes |
| the trust distribution                      | not published yet / read failed / read forbidden                                | `EgressTrustPending`, `EgressTrustReadFailed`, `EgressTrustForbidden`                 | transient, transient with jitter, terminal          |
| the configuration channel                   | no per-replica identity, no fencing, or no bounded last-known-good lifetime     | `ConfigChannelUnauthenticated`                                                        | blocked before any route is programmed              |

There is no unauthenticated fallback anywhere in that table. Every one of these fails closed.

## What cannot be shown from a repository

A dependency outage is a runtime condition. Nothing in this directory can make a signer time out or a proxy disappear, and a file claiming to demonstrate one would be a claim rather than a demonstration. What is published here is the half that _is_ checkable without a cluster: the documents the platform refuses at policy load, before anything is written.

The runtime half is proven in the operator's own conformance suite, which exercises unavailable, timeout, and malformed-response paths against fakes and interceptors rather than a live provider. Read the reason table above, and expect the reason rather than a stack trace.

## Files

| File                                                                                 | Purpose                                                                                    |
| ------------------------------------------------------------------------------------ | ------------------------------------------------------------------------------------------ |
| [administrator-supplied-fragment.yaml](administrator-supplied-fragment.yaml)         | the issuance mode with the largest failure surface, loadable, with its four outcomes named |
| [unresolved-authority-refused.yaml](unresolved-authority-refused.yaml)               | refused on purpose: a destination requires an authority nothing declares                   |
| [plaintext-without-exemption-refused.yaml](plaintext-without-exemption-refused.yaml) | refused on purpose, and refused earlier: a plaintext hop with no exemption                 |

`AdministratorSupplied` is here rather than in the migration directory for one reason: it is the only mode where the platform **renews nothing**, and says so. Expiry becomes your calendar's problem, and the platform's job shrinks to warning you inside `expiryWarningBefore`. An installation that adopts it and does not read that warning has a working cluster until the day it does not.

## Verification

```bash
# The reason and message on the transport component, which is where a terminal
# refusal lands.
kubectl -n kamiwaza-examples get kamiwazaplatform kamiwaza \
  -o jsonpath='{range .status.components[?(@.name=="trust")]}{.phase}{"\t"}{.reason}{"\t"}{.message}{"\n"}{end}'

# Advisories: one line per unproven or exempt control, so every open action is
# visible at once rather than one per reconcile in the log.
kubectl -n kamiwaza-examples get kamiwazaplatform kamiwaza \
  -o jsonpath='{range .status.advisories[*]}{.capability}{"\t"}{.reason}{"\t"}{.message}{"\n"}{end}'

# The required-Secret contract the platform publishes under AdministratorSupplied,
# so the exact names and keys it consumes are readable rather than guessed.
kubectl -n kamiwaza-examples describe kamiwazaplatform kamiwaza | sed -n '/Conditions/,$p'

# Events, for the transitions status does not keep.
kubectl -n kamiwaza-examples get events --field-selector involvedObject.kind=KamiwazaPlatform
```

A blocked platform is a result, not a signal to bypass policy. Correct the dependency, the policy, or the intent the reason names.

## On an installation that has not migrated

Nothing here changes it. None of these reasons can be reported by an installation with no `transport` section, because none of the planes that produce them are declared. The first of them an installation sees is the one belonging to the plane it just adopted.

## How this example was validated

| File                                       | Validated with                                                                                                                                                                                                                      |
| ------------------------------------------ | ----------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| `administrator-supplied-fragment.yaml`     | The operator's own loader, `adminpolicy.LoadTransportPolicy`, then `Policy.ValidateCrossReferences` — accepted. Also `transport-security.schema.yaml` (`jsonschema`, Draft 2020-12) — valid.                                        |
| `unresolved-authority-refused.yaml`        | Same loader — shape accepted. Same cross-reference rules — **refused on purpose**: `authority "enterprise-root-2028" is not declared` (`EgressAuthorityMissing`). Same schema — valid.                                              |
| `plaintext-without-exemption-refused.yaml` | Same loader — **refused at load**: `transport.internal.hops[0].exemption: plaintext transport requires an exemption (PlaintextDenied)`. Same schema — invalid at `transport/internal/hops/0`, `'exemption' is a required property`. |

The loader and the schema disagree usefully on the first two files: both are schema-valid and both are refused by the cross-reference rules, because a rule that needs two sections of one document at once is not expressible in the schema. Where a claim rests on one of them, the table says which.
