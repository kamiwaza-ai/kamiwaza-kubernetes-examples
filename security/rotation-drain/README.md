# Rotation and drain: how a certificate change costs a restart, or does not

**Scenario:** rotate a platform authority without dropping a request, and know before you start which workloads restart, which reload in place, and which drain their connections. The cost is a property of the consuming workload, not of the platform, so the platform publishes the matrix rather than assuming.

**Tags:** #security #transport #rotation #drain #reload-class

## Three reload classes, one downgrade

| Class              | Meaning                                                                 | Requirement                                                                                                                                                 |
| ------------------ | ----------------------------------------------------------------------- | ----------------------------------------------------------------------------------------------------------------------------------------------------------- |
| `Reload`           | the process re-reads its certificate and trust files without restarting | must be **proven** in conformance, by rotating material and observing a successful handshake with no restart                                                |
| `Rollout`          | the process reads material at start                                     | the platform rolls it exactly once per content digest change; an unchanged digest rolls nothing                                                             |
| `ConnectionScoped` | established connections keep the material they were established with    | the consumer enforces a maximum connection age no greater than the remaining credential lifetime, and drains or reauthenticates before expiry or revocation |

The downgrade is the whole reason the classes are declared rather than inferred: **an unproven `Reload` claim is treated as `Rollout`**, and so is an unrecognised or absent one. A class the platform cannot enforce would otherwise leave a process running on retired material. Verified against the platform's own function:

```text
Reload declared, proven      -> Reload
Reload declared, unproven    -> Rollout
SomethingElse declared       -> Rollout
```

Projected volumes are never mounted with a `subPath`, because a `subPath` mount is not refreshed when its source changes — a detail that silently converts every `Reload` consumer into one serving expired material.

## The drain arithmetic, computed rather than described

Two numbers bound a connection-scoped consumer: the connection age its policy declares, and the credential's **remaining** lifetime. The enforced ceiling is the smaller of the two, and the drain window is one ceiling long. Recomputed here from the functions that enforce it:

| Class              | Declared age | Remaining credential life | Enforced maximum age | Drain grace |
| ------------------ | ------------ | ------------------------- | -------------------- | ----------- |
| `ConnectionScoped` | 30m          | 1h30m                     | 30m                  | 30m         |
| `ConnectionScoped` | 30m          | 10m                       | **10m**              | 10m         |
| `ConnectionScoped` | unset        | 1h30m                     | 1h30m                | 1h30m       |
| `ConnectionScoped` | 30m          | expired                   | 0                    | 0           |
| `Rollout`          | 30m          | 1h30m                     | 0 (not applicable)   | 0           |

Read the second row: a certificate near expiry shortens the connections it authenticated, not the other way round. Read the fourth: when the credential has expired or its deadline cannot be observed, nothing is held and whatever remains drains now. A declared grace shorter than the window is honoured; a longer one is clamped, because a grace beyond the window would keep a request running on an expired credential, and a zero grace would cut off a request that could still have finished inside the credential's remaining life.

Policy has to agree with itself for any of this to hold, which is why a connection age longer than its client identity's validity is refused at policy load rather than at handshake time.

## Rotation is a protocol, selected by one field

**`RenewCertificate`** reissues the authority certificate over the existing key. Existing leaves still verify, so: publish the new authority certificate, republish the distribution, roll the `Rollout`-class consumers. **One rollout.**

**`ReplaceKey`** means a new authority key, so every leaf must be reissued and the old anchor must stay trusted until that is done. Three phases, and the order is not optional:

1. **Trust the new anchor.** The distribution carries the retiring and the replacement anchor at once, and consumers roll or reload until every one of them trusts both. The platform's own client identity is not rotated in this phase, so the operator cannot lock itself out of the workloads it manages.
2. **Issue under the new key.** Leaves are reissued and consumers pick them up.
3. **Drop the retired anchor.** Only after every consumer is _observed_ on the new generation.

Phase 3 requires proof and is never run on a timer. Rotation state is derived from observed per-workload generation rather than an in-memory step counter, so a manager that restarts mid-rotation resumes from what it observes instead of restarting the protocol. While phase 3 is withheld, the reason is `AuthorityAnchorRetentionRequired` and it names the consumers that are not yet proven.

**Rotation is not revocation.** A certificate issued under the retiring client authority stays valid until it expires or until phase 3 drops the anchor. Where revocation is actually required it is an authority-side action _plus_ phase 3.

Automatic renewal, manual rotation, and the rollouts they cause are all confined to `maintenanceWindows` when set. A window shorter than the reconcile interval slips the work to the next window rather than skipping it.

## Files

| File                                                             | Purpose                                                                                        |
| ---------------------------------------------------------------- | ---------------------------------------------------------------------------------------------- |
| [transport-policy-fragment.yaml](transport-policy-fragment.yaml) | rotation policy, short-lived workload identity, and connection ages that fit their credentials |
| [rotate-authority-request.yaml](rotate-authority-request.yaml)   | a merge patch requesting one manual rotation of one authority role                             |
| [connection-age-refused.yaml](connection-age-refused.yaml)       | refused on purpose: a 4000h connection age against a 2160h certificate                         |

## Requesting a rotation

```bash
kubectl -n kamiwaza-examples patch kamiwazaplatform kamiwaza \
  --type merge --patch-file security/rotation-drain/rotate-authority-request.yaml
```

`transport.kamiwaza.io/rotate-authority` is `Server` or `Client` — two roles, never one, so a leaked client-authority key cannot mint a server identity and revoking client trust does not invalidate every server certificate. `transport.kamiwaza.io/rotate-operation` is `RenewCertificate` or `ReplaceKey`.

The request is carried out once. A ledger beside the authorities records which request was honoured, so an annotation left in place does not rotate again on the next reconcile; asking for the same operation again means removing the annotation and setting it once more.

## Verification

```bash
# The reload class and, for a connection-scoped consumer, the enforced ceiling.
# Both are annotations on the pod template, so they are readable per workload
# rather than aggregated into one number.
kubectl -n kamiwaza-examples get deployment -o jsonpath='{range .items[*]}{.metadata.name}{"\t"}{.spec.template.metadata.annotations.transport\.kamiwaza\.io/reload-class}{"\t"}{.spec.template.metadata.annotations.transport\.kamiwaza\.io/max-connection-age}{"\n"}{end}'

# Rotation phase and what phase 3 is waiting for.
kubectl -n kamiwaza-examples get kamiwazaplatform kamiwaza \
  -o jsonpath='{range .status.advisories[?(@.capability=="trust")]}{.reason}{"\t"}{.message}{"\n"}{end}'

# The published distribution's digest. An unchanged digest must roll nothing:
# record it, reconcile, and compare.
kubectl -n kamiwaza-examples get configmap kamiwaza-trust-bundle \
  -o jsonpath='{.metadata.labels.transport\.kamiwaza\.io/bundle-digest}{"\t"}{.metadata.annotations.transport\.kamiwaza\.io/policy-revision}{"\n"}'
```

## Failure reasons

| Reason                             | Trigger                                                                 | Retry class                     |
| ---------------------------------- | ----------------------------------------------------------------------- | ------------------------------- |
| `AuthorityRotationPhase`           | a rotation phase is in progress; carries the phase                      | transient                       |
| `AuthorityAnchorRetentionRequired` | phase 3 withheld because a consumer is not proven on the new generation | transient                       |
| `ReloadUnproven`                   | an in-place reload claim has no conformance evidence                    | advisory; treated as `Rollout`  |
| `ClientIdentityPending`            | a referenced identity is validly requested but not issued yet           | transient                       |
| `ClientIdentityInvalid`            | material malformed, expired, revoked, or policy-incompatible            | terminal until material changes |
| `SuppliedMaterialExpiring`         | unrenewable administrator material inside its warning window            | advisory, blocking after expiry |

## On an installation that has not migrated

Nothing here changes it. With no `transport` section there are no platform authorities to rotate, no reload classes published, and no drain bounds enforced; the annotations the verification commands read are simply absent. Under `AdministratorSupplied` the same three phases apply but the administrator performs them, and the platform reports which phase it observes rather than driving one.

## How this example was validated

| File                             | Validated with                                                                                                                                                                                                                                       |
| -------------------------------- | ---------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| `transport-policy-fragment.yaml` | The operator's own loader, `adminpolicy.LoadTransportPolicy`, then `Policy.ValidateCrossReferences` — accepted in the Full and regulated profiles. Also `transport-security.schema.yaml` (`jsonschema`, Draft 2020-12) — valid.                      |
| `connection-age-refused.yaml`    | Same loader — shape accepted. Same cross-reference rules — **refused on purpose**: `connection age 4000h exceeds the 2160h lifetime of client identity "core-client"` (`ClientIdentityInvalid`). Same schema — valid.                                |
| `rotate-authority-request.yaml`  | `kubectl apply --dry-run=server --validate=strict` against a live cluster, merged into a complete platform object, with the namespace substituted for one that exists — accepted. The control, the same object with one unknown field, was rejected. |

Every number in the drain table above was recomputed from `trust.MaximumConnectionAge`, `trust.BoundedDrainGrace`, and `trust.EffectiveReloadClass` rather than transcribed, and the reload-class rows are that function's own output.
