# ReBAC grant changes: plan, diff, apply

**Scenario:** change who may reach a Kamiwaza resource by planning the change, reviewing its diff, and only then applying it — through the grant service, which is the only writer to the relationship store. The example is built around the case that surprises people: two producers can own the same relationship edge, so one producer's removal does not revoke access.

**Tags:** #security #rebac #authz #producer-ownership #grants

## What this example replaces

The previous version of this directory taught tenant tuple bootstrap: copy a manifest into the application repo, run `scripts/rebac_tenant.py bootstrap` against the live relationship store, and revoke by tuple identity. That shape is wrong now for two reasons, and neither is about tenants.

- It made the operator a second writer to the store. The grant service owns its outbox and its backend projection; a CLI that writes tuples beside it produces state no producer reconciles and no audit attributes.
- It revoked by tuple identity. An edge can have several owners. Deleting the tuple to undo your own grant deletes somebody else's grant at the same time, silently and unattributably.

Enabling relationship decisions with Helm values is still here, because that part was never wrong. Everything about writing tuples directly is gone.

## The contract is the authority

Operations, headers, status codes, field names, and both vocabularies come from `specs/002-identity-transport-runtime/contracts/grant-service.openapi.yaml` in the platform operator repository. Read it before you rely on anything below.

| Operation                            | What it does                                                             |
| ------------------------------------ | ------------------------------------------------------------------------ |
| `POST /api/v1/grants/changes:plan`   | Validates a bundle and returns its diff. Writes nothing.                 |
| `POST /api/v1/grants/changes:apply`  | Acquires this producer's ownership of the declared edges, idempotently.  |
| `POST /api/v1/grants/changes:remove` | Releases **only this producer's** ownership of the named entries.        |
| `GET /api/v1/grants/operations/{id}` | Reports per-edge outcomes, owner counts, and the consistency checkpoint. |

Two properties of that document matter before you start:

- **No custom resource stores relationship tuples, and the operator holds no grant authority.** There is no `Grant` CRD to apply, and no `kubectl` verb that changes who may reach a resource. Editing objects in a namespace is a statement about Kubernetes objects; it is not a statement about who may see what.
- **`Idempotency-Key` is required on `:apply` and `:remove`.** A retry must reuse the key of the attempt it retries. A fresh key is a second operation.

## Prerequisites

- Kamiwaza deployed with full auth (Keycloak plus PostgreSQL) and relationship decisions enabled. ReBAC is not available in lite mode; the core chart fails template rather than rendering a half-enabled state.
- A bearer token holding the dedicated authorization-administration authority. Kubernetes namespace administration does not satisfy it, whatever the role is named.
- `curl`, `jq`, and either `yq` or `python3` with PyYAML.
- A platform that serves the four operations above. `HTTP 404` from `:plan` means your release does not serve this contract; it does not mean the grant is fine.

## Step 0 — select the profile

Merge `core-values-snippet.yaml` into Deploy `cluster/values/overrides.yaml` (or another later values layer) and re-sync.

`AUTH_GATEWAY_GRANT_PRODUCER_PROFILE=producer_owned` is the whole switch. Unset, blank, `legacy`, or any unrecognised value is exactly today's grant behaviour — an unrecognised value logs one warning and stays legacy — so rolling a new image never changes how an existing installation's grant paths behave. On an installation that has not selected it, an edge carries no owners and the producer-ownership properties below are not in effect.

`AUTH_GATEWAY_ROLE_SEPARATION_PROFILE=least_privilege` is in the same snippet for a reason. Under the legacy profile the coarse Kamiwaza `admin` role satisfies authorization administration and short-circuits the ownership lookup, so any admin can change any producer's grants. Read the note in the snippet before selecting it: it removes the coarse role's ambient resource access, so the explicit relationships have to exist first.

Verify the signal reached the process that serves the operations:

```bash
kubectl -n kamiwaza exec deploy/core-scheduler -c core -- \
  env | grep -E '^(AUTH_REBAC_ENABLED|AUTH_GATEWAY_GRANT_PRODUCER_PROFILE|AUTH_GATEWAY_ROLE_SEPARATION_PROFILE)=' | sort
```

## Step 1 — plan

A bundle is **desired state**, not a list of commands. `grant-manifest.example.yaml` is one administrator-automation bundle: the set of edges this producer wants to own. An edge it stops declaring is an edge it stops owning.

```bash
cd security/rebac
export API_BASE=https://<your platform>/api
export GRANT_ADMIN_TOKEN=<your token>          # supplied by you, never stored here
./grant-change.sh plan grant-manifest.example.yaml
```

`plan` writes the plan under `out/` and mutates nothing. `out/` is ignored by Git: a plan names principals and resources, and it is not review material for anyone outside the review.

## Step 2 — diff

```bash
./grant-change.sh diff grant-manifest.example.yaml
```

This renders the plan that was written, not a fresh one, because the artefact a human reviews has to be the artefact the apply is bound to. `:apply` and `:remove` both carry `approvedPlanDigest`, and the service refuses a digest that is not the digest of the plan for that bundle revision. That binding is the whole point of the ordering: an authorization change applied without a diff is one nobody reviewed, and a change applied against a stale digest is one somebody reviewed while it said something else.

## Step 3 — apply, then observe the checkpoint

```bash
./grant-change.sh apply grant-manifest.example.yaml
./grant-change.sh observe <operationID>
```

An accepted apply returns `202` with state `Accepted`, `Applying`, or `CheckpointPending`. **None of those mean the change is live.** A change is live when the operation reports `Succeeded` with a checkpoint. Until then, the backend may have accepted a write whose effect a reader cannot yet observe, and code that acts on "the apply returned 202" acts on access that may not be in force.

- `503` from `:apply` or `:remove` means the projection or the checkpoint is unavailable and **the operation is not complete**. It is not a failure to retry blindly and it is not a success.
- A checkpoint you cannot read is a checkpoint you do not have. `grant-change.sh observe` exits non-zero for every state that is not `Succeeded`-with-checkpoint, including a failure to read the operation at all, so a script cannot mistake silence for success.
- The checkpoint's `token` is `writeOnly` in the contract, so no response carries it. What an observer gets is the state and `checkpoint.observedAt`.

## The case this example exists for: two producers, one edge

`grant-manifest-second-producer.example.yaml` declares the same edge as `analytics-editor-on-shared-workroom` in the first bundle: same principal, same resource, same relation. Different `entryID`, because an entry ID names an intent inside one bundle rather than the edge itself.

Plan and apply the second bundle after the first:

```bash
./grant-change.sh plan grant-manifest-second-producer.example.yaml
```

```text
ENTRY                                        ACTION    OWNERS-AFTER BACKEND-WRITE
reporting-editor-on-shared-workroom          Acquire   2            no
```

`ownerCount` is the count **after** the action. Two owners, and no backend write: the edge already exists, so this producer's `Acquire` is metadata only. Access was already live and nothing about it changed.

Now the first producer stops wanting that edge. Bump its bundle to a new revision with the entry dropped, plan the new revision, and read the diff:

```bash
# grant-manifest.example.yaml, edited: revision: rev-0002, workroom entry deleted
./grant-change.sh plan grant-manifest.example.yaml
```

```text
ENTRY                                        ACTION    OWNERS-AFTER BACKEND-WRITE
analytics-reader-on-quarterly-metrics        NoChange  1            no
analytics-operator-on-metrics-connector      NoChange  1            no
analytics-editor-on-shared-workroom          Release   1            no
```

`Release`, one owner left, no backend write. Then execute it:

```bash
./grant-change.sh remove grant-manifest.example.yaml analytics-editor-on-shared-workroom
./grant-change.sh observe <operationID>
```

```text
state: Succeeded
ENTRY                                        ACTION    OWNERS-AFTER EDGE-STATE
analytics-editor-on-shared-workroom          Release   1            Ready
checkpoint observed at <timestamp>; the change is live
```

**The user still has access, and that is correct.** Your removal succeeded: it released your producer's claim, which is the only claim it was ever entitled to release. The remaining owner did not ask you to revoke anything, and a removal that took the edge would have made a silent, unattributed change to another producer's state — after which that producer's next reconcile either recreates the edge, so the deletion accomplished nothing but an audit gap, or does not, so a relationship nobody decided to revoke is gone.

The plan said this before anything was written. `Release` with `ownerCount 1` and no backend write is the diff for "this changes ownership, not access". Read it, and "my remove did nothing" stops being a mystery.

Access ends when the last owner releases it. The second producer drops the entry from its own next revision:

```text
ENTRY                                        ACTION    OWNERS-AFTER BACKEND-WRITE
reporting-editor-on-shared-workroom          Revoke    0            yes
```

`Revoke`, no owners left, and a backend write because the edge is deleted.

### The six actions

Every action is keyed on two facts: whether **this** producer owns the edge, and whether anyone else does.

| Action     | When                                                             | `ownerCount` (after) | `backendChangeRequired` |
| ---------- | ---------------------------------------------------------------- | -------------------- | ----------------------- |
| `Acquire`  | This producer does not own it yet                                | current + 1          | only if the edge is new |
| `NoChange` | This producer already owns it and is the only owner              | unchanged            | no                      |
| `Retain`   | This producer owns it and at least one other producer co-owns it | unchanged            | no                      |
| `Release`  | This producer releases it and at least one owner remains         | current − 1, min 1   | no                      |
| `Revoke`   | This producer was the last owner                                 | 0                    | yes                     |
| `Conflict` | Plan only: the entry is refused and no action would be taken     | —                    | —                       |

A `Release` or `Retain` in a diff is the signal that somebody else is holding the same edge. If that is a surprise, stop and find out which producer before you change anything: it is usually a lane you did not know was projecting.

### Producer lanes

Producer attribution lives in the edge's own metadata `source`. The lanes are distinct and each reconciles against its own upstream:

| Lane                     | `source`                   |
| ------------------------ | -------------------------- |
| Resource owner / subject | `subject_administration`   |
| IdP group projection     | `idp`                      |
| Local group              | `local_group`              |
| Brokered federation      | `brokered`                 |
| Bootstrap                | `bootstrap`                |
| Workload                 | `workload`                 |
| Administrator automation | `administrator_automation` |

An absent `source` is the subject-administration lane, which is what the resource-owner and subject-grant paths write. This is the same attribution identity removal uses: removing a person takes that person's subject-administration tuples and retains the tuples another producer owns, each retention audited with its producer lane. A bundle applied through this workflow is the `administrator_automation` lane and cannot release any other lane's claim.

## The vocabularies are closed

`resourceType` and `relation` are closed enumerations in the contract. An entry naming anything else is refused at plan time, with one blocker per rejected entry and no partial apply — a manifest is planned as a whole. Plan the refused example rather than trusting a list:

```bash
./grant-change.sh plan grant-manifest-refused.example.yaml
```

```text
blockers (2) — nothing is applied while any blocker stands:
  unknown_relation: entry unknown-relation names a relation the contract does not declare
  unknown_resource_type: entry unknown-resource-type names a resource type the contract does not declare
```

Blocker codes to expect: `unknown_resource_type`, `unknown_relation`, `unknown_principal`, `relation_not_writable`, `duplicate_entry_id`, `invalid_manifest`.

`relation_not_writable` is the one that catches people. A resource type in the contract's vocabulary is not automatically a resource type with a writable relation, and a relation in the contract's vocabulary is not writable for every resource type. In the shipped internal schema `Platform`, `Tenant`, and `Application` have no writable relation at all, so an entry against them parses and is then refused; `Operator` is writable for a `Connector` and not for a `Model`. Use `Dataset`, `Workroom`, `Model`, or `Connector`, and let the plan tell you which relation each one accepts.

Closed vocabularies are not bureaucracy. An open one means a typo becomes a relation nobody grants and nobody audits, and a relation the enforcement side never checks is a grant that reads as applied and enforces nothing.

## Tenants

Tenant scope comes from the token, not from this workflow: the platform reads the active tenant from the `tenant_id` / `tenant` claims, and `core.scheduler.rebac.defaultTenantId` is the default used by bootstrap jobs and as a reference id, not a per-user assignment. Per-user tenants need per-user or per-group claim mappers in Keycloak. Registering a tenant id is `tenant-registry-snippet.yaml`, and rejecting a token whose `tenant_id` is not registered is `tenant-registry-enforcement-snippet.yaml`. Neither is a grant: `Tenant` has no writable relation in the shipped internal schema, so tenant-scoped access is granted on the resources inside the tenant, as ordinary bundle entries. What is gone is bootstrapping tenant tuples by CLI — that is a plan, a diff, and an apply like every other grant change.

## Verification

| Check                       | Command                                                                     | Expected                                                         |
| --------------------------- | --------------------------------------------------------------------------- | ---------------------------------------------------------------- |
| Signals reached the process | the `env` command in Step 0                                                 | all three variables present with the values you set              |
| Plan writes nothing         | `./grant-change.sh plan grant-manifest.example.yaml` twice                  | identical `planDigest` both times; no operation is created       |
| Closed vocabulary           | `./grant-change.sh plan grant-manifest-refused.example.yaml`                | two blockers, exit status 1                                      |
| Diff binds the apply        | apply with a hand-edited `planDigest` in `out/*.plan.json`                  | `409`, and nothing written                                       |
| Co-ownership survives       | the two-producer sequence above                                             | `Release` with `ownerCount 1`, and the principal keeps access    |
| Checkpoint gates liveness   | `./grant-change.sh observe <operationID>` before the checkpoint is observed | non-zero exit and an explicit "do not treat this change as live" |
| No CRD holds tuples         | `kubectl api-resources \| grep -i grant`                                    | no result                                                        |

## What you supply

Everything specific to your installation, because none of it belongs in this repository:

- **The bearer token.** Held by the caller, passed to `curl` through a configuration file on standard input so it never appears in process arguments, and never written to `out/`, echoed, or logged.
- **`API_BASE`.** The default is `https://kamiwaza.example.invalid/api`, a reserved non-resolvable name (RFC 6761) that fails loudly rather than reaching anything.
- **Real principals and resources.** Every `principalID` in these files is a synthetic UUID identifying nobody, and every `resourceID` names nothing real. A principal is an opaque platform identifier: no email, username, certificate field, or directory name goes into a bundle.
- **Your own `bundleID` and `revision` discipline.** The digest binding only protects you if the revision changes whenever the entries change. A changed file under an unchanged revision is what a stale approval looks like.
- **Review.** The workflow makes a diff available before a write. It cannot make somebody read it.

## How this example was validated

| File                                          | Validated with                                                                                                                                                                                                                                           |
| --------------------------------------------- | -------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| `grant-manifest.example.yaml`                 | The platform's own manifest loader, `kamiwaza.services.authz.grants.producer_ownership.parse_grant_manifest` — three entries, no blockers. Also the published contract's `GrantManifest` schema (`jsonschema`, Draft 2020-12, `$ref`s resolved) — valid. |
| `grant-manifest-second-producer.example.yaml` | Same loader — one entry, no blockers. Same schema — valid.                                                                                                                                                                                               |
| `grant-manifest-refused.example.yaml`         | Same loader — **refused on purpose**, blockers `unknown_relation` and `unknown_resource_type`. Same schema — invalid at exactly those two closed enumerations.                                                                                           |
| `tenant-registry-snippet.yaml`                | The platform's own registry loader, `kamiwaza.services.authz.tenant_registry` — both ids load, and an unregistered id is rejected under enforcement.                                                                                                     |
| `core-values-snippet.yaml`                    | `yamllint` with this repository's configuration. Its chart keys were read from `charts/core/values.yaml`.                                                                                                                                                |
| `tenant-registry-enforcement-snippet.yaml`    | `yamllint` with this repository's configuration. Its chart key was read from `charts/core/values.yaml`.                                                                                                                                                  |
| `grant-change.sh`                             | `shellcheck` clean at every severity, `shfmt -s -i 2` clean, and the whole plan → diff → apply → observe → remove sequence run end to end.                                                                                                               |

The manifest loader ran first and found a real defect: an entry named `Operator` on a `Model`, which the contract's schema accepts because both words are in its vocabularies, and which the loader refuses as `relation_not_writable`. The contract schema alone would not have caught it. That is why the loader claim above is the one that matters and the schema claim is secondary.

Nothing in this directory is a Kubernetes object, so nothing was checked with `kubectl apply --dry-run=client`, and there is no kustomization to build. The values snippets are Helm values fragments for the Deploy umbrella; Helm has no fragment loader to validate a values fragment against, so they were checked as YAML and against the chart's own keys.

The sample outputs above were produced by running `grant-change.sh` against a local stub implementing the four operations and the ownership rules, so the workflow, the exit statuses, and the shapes are real. They are not evidence from a live grant service, and this example does not claim a live run.

## Files

| File                                          | Purpose                                                                            |
| --------------------------------------------- | ---------------------------------------------------------------------------------- |
| `grant-change.sh`                             | `plan` → `diff` → `apply` / `remove` / `observe`, with the digest binding enforced |
| `grant-manifest.example.yaml`                 | One administrator-automation bundle: three edges, one of them co-owned             |
| `grant-manifest-second-producer.example.yaml` | A second producer declaring one of the same edges                                  |
| `grant-manifest-refused.example.yaml`         | A bundle refused at plan time: unknown relation, unknown resource type             |
| `core-values-snippet.yaml`                    | Relationship decisions, the producer-ownership profile, and role separation        |
| `tenant-registry-snippet.yaml`                | Which `tenant_id` claims this installation admits                                  |
| `tenant-registry-enforcement-snippet.yaml`    | Reject a token whose `tenant_id` is not registered                                 |

## On an installation that has not migrated

Nothing here changes it. With `AUTH_GATEWAY_GRANT_PRODUCER_PROFILE` unset, edges carry no owners, existing grant paths behave exactly as they do today, and the workflow in this directory is not available — which is why the first thing `grant-change.sh` reports on a platform that does not serve the contract is `HTTP 404` and an explicit statement that no grant was applied.
