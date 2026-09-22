# Migration: from an installation with no transport policy to one a regulated profile accepts

**Scenario:** adopt the transport contract on a cluster that is already running, in three stages, without a flag day. Each stage is a policy document you can load before you apply it, and each one is reversible by going back to the previous revision.

Tags: #security #transport #migration #dual-topology #profiles.

## The first thing to know: not adopting it changes nothing

An installation with no `transport` section in administrator policy reports no hop plane, emits no transport floor, publishes no listener certificate intent for this contract, and behaves exactly as it did before the contract existed. The absence of the section is the signal, and its absence means today's behaviour.

That is the property to preserve while you migrate. Every stage below is additive, and the way back is the previous policy revision.

## The three stages

| Stage                                                          | What it adds                                                             | Loads in Full | Loads in regulated |
| -------------------------------------------------------------- | ------------------------------------------------------------------------ | ------------- | ------------------ |
| [stage-1-encrypt-only.yaml](stage-1-encrypt-only.yaml)         | one field: platform-issued authorities and every published default       | yes           | yes                |
| [stage-2-named-exceptions.yaml](stage-2-named-exceptions.yaml) | every hop named, including the two this installation cannot protect yet  | yes           | **no**             |
| [stage-3-regulated.yaml](stage-3-regulated.yaml)               | the same installation with nothing left that a regulated profile refuses | yes           | yes                |

### Stage 1 is genuinely one field

```yaml
transport:
  issuance:
    mode: PlatformIssued
```

That is a complete, working, encrypted installation. The operator becomes its own certificate authority, so no certificate controller and no external PKI is required; every plane it does not mention takes a published default; and egress stays closed because no destination class is declared. Closed is the right direction to start from.

### Stage 2 is where a real migration lives for a while

Stage 2 exists to keep `Plaintext` and `MeshDelegated` hops visible. A policy limited to protected hops pushes unprotected hops out of policy and status.

- A `Plaintext` hop requires an `exemption` with a justification of at least eight characters, and the justification appears in status for as long as the exception is active. Give it an `expires` date so it cannot quietly become permanent.
- A `MeshDelegated` hop requires `evidenceSource: AdminAttested`, and the platform reports it as attested rather than observed. No standard object can corroborate a mesh's protection, so the platform records whose word it is.

The same document is refused by a regulated profile, and the refusal is per installation rather than per process:

```text
regulated profiles refuse plaintext and private-address exceptions:
transport.internal.hops[4].transport: a regulated profile refuses plaintext
transport, and hop CoreToObjectStorage declares it (PlaintextDenied)
```

A regulated profile also refuses administrator-attested hops (`HopUnprotected`) and shortened denied-network sets. It requires the workload ingress floor. Stage 3 states the default TLS 1.2 floor for audit visibility.

### Stage 3 is not an editing exercise

The stage-2 diff is short. The object-storage version now terminates TLS, so its plaintext exception is gone. The platform now protects the compute hop, so mesh delegation is gone. The TLS floor is explicit for audit visibility.

Every removed exception was removed because the thing it excused was fixed. Deleting the exceptions without fixing them yields a policy that loads and an installation that does not work.

## Rotation is part of migration, once

Stage 3 selects `expirationPolicy: ReplaceKey`, which is the three-phase protocol: trust the new anchor, issue under it, then drop the retired anchor **only** once every consumer is proven to be on the new generation. Phase 3 is never run on a timer, rotation state is derived from observed per-workload generation rather than a step counter, and an operator restart mid-rotation resumes from what it observes. See [../rotation-drain/](../rotation-drain/) for the mechanics and the drain arithmetic.

Rotation is not revocation. An identity issued under the retiring authority stays valid until that anchor is dropped.

## Steps

```bash
# 1. Load the stage you are about to apply, before you apply it. The fragment
#    has `transport` at the root because that is what the published schema
#    declares and what the operator's loader accepts.

# 2. Merge the stage into the AdminCapabilityPolicy document the operator chart
#    mounts, and bump adminPolicy.revision. The policy ConfigMap is immutable,
#    so a changed document needs a new revision.

# 3. Watch the plane converge, and read what it says about itself.
kubectl -n kamiwaza-examples get kamiwazaplatform kamiwaza \
  -o jsonpath='{range .status.components[?(@.name=="trust")]}{.state}{"\t"}{.reason}{"\t"}{.message}{"\n"}{end}'

# 4. Read every active exception and attested hop. This is the migration
#    backlog: each line is either a fix or a decision.
kubectl -n kamiwaza-examples get kamiwazaplatform kamiwaza \
  -o jsonpath='{range .status.advisories[?(@.capability=="trust")]}{.reason}{"\t"}{.message}{"\n"}{end}'

# 5. Confirm which policy revision is in force, so what you are reading is what
#    you applied.
kubectl -n kamiwaza-examples get kamiwazaplatform kamiwaza \
  -o jsonpath='{.status.adminPolicyRevision}{"\n"}'
```

Expect `PlaintextExceptionActive` and `HopAttestedOnly` in step 4 while you are in stage 2. They are advisories, not failures: they are how the exceptions stay counted.

On the live validation platform, stage 2 also reported unprotected hops for selected capabilities outside this migration slice. Those advisories remain migration backlog rather than being hidden.

## A note on the profile field

The strict posture in this document is the **regulated cross-reference profile**, which administrator policy is evaluated against. On the platform resource itself, `spec.profile` currently admits `Full` only, so a regulated installation is not selectable there in this release: what you can do today is validate a policy against the regulated rules before you rely on them. Do not read stage 3 as "select the regulated profile" — read it as "this policy has nothing left that the regulated rules refuse".

The namespace-scope axis is separate and is in [../../operator/transport-scopes/](../../operator/transport-scopes/).

## Files

| File                                                           | Purpose                                                             |
| -------------------------------------------------------------- | ------------------------------------------------------------------- |
| [stage-1-encrypt-only.yaml](stage-1-encrypt-only.yaml)         | the one-field policy: encrypted, defaulted, egress closed           |
| [stage-2-named-exceptions.yaml](stage-2-named-exceptions.yaml) | every hop named, with one justified exemption and one attested hop  |
| [stage-3-regulated.yaml](stage-3-regulated.yaml)               | the same installation with the exceptions fixed rather than deleted |

## How this example was validated

| File                            | Validated with                                                                                                                                                                                                                                             |
| ------------------------------- | ---------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| `stage-1-encrypt-only.yaml`     | The operator's own loader, `adminpolicy.LoadTransportPolicy`, then `Policy.ValidateCrossReferences` in the Full profile — accepted. Also `transport-security.schema.yaml` (`jsonschema`, Draft 2020-12) — valid.                                           |
| `stage-2-named-exceptions.yaml` | Same loader — accepted. Cross-reference rules — accepted in the Full profile, and **refused in the regulated profile**: `a regulated profile refuses plaintext transport, and hop CoreToObjectStorage declares it (PlaintextDenied)`. Same schema — valid. |
| `stage-3-regulated.yaml`        | Same loader — accepted. Cross-reference rules — accepted in **both** the Full and the regulated profile. Same schema — valid.                                                                                                                              |

The three revisions were also applied in order on the clean cluster. Stage 1 reached `TransportReady`. Stage 2 reported `PlaintextExceptionActive` and `HopAttestedOnly`. Stage 3 removed both advisories. Rolling back the Helm release restored the original policy revision and platform readiness.

The stage-2 pair is the load-bearing result here: one document, two profiles, two different answers, from the operator's own rules rather than from this README's description of them.
