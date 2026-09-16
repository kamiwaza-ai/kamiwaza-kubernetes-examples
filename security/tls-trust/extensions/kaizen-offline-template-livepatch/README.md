# Kaizen 0.13 catalog template livepatch

**Status:** unsupported historical procedure. Do not run it on an
operator-managed platform.

Tags: #kaizen #historical #unsupported

## Why this procedure is retired

The original procedure changed a live Core catalog row through
`PUT /api/apps/app_templates/{id}`. It applied only to offline
`release/0.13.0` installations and affected only later launches.

Current operator-managed installations do not meet its prerequisites:

- Current Kaizen releases use a pinned release version and component graph.
- The operator owns deployed Kubernetes resources and their rollout.
- Current platform topology has no `core-scheduler` Deployment.
- Current platform topology has no `kamiwaza-user-svc-core` Secret.
- The public entry point is a Gateway API listener, not a discovered ingress
  Service.

A catalog mutation can diverge from the reviewed release artifact. The operator
cannot prove or repair that hidden state. A later catalog sync can also replace
the mutation.

## Current release path

Put startup probes, memory requests, runtime limits, and retention defaults in
the reviewed Kaizen release artifact. Publish a new immutable release version.

Apply that version through the extension release workflow. Wait for the
operator to report the release ready. Then verify a new Kaizen deployment and a
new conversation.

Do not rewrite a released catalog template in place. Do not patch generated
Deployments to emulate a release.

## Historical evidence

Git history retains the former `release/0.13.0` commands. They are not a current
runbook and were not validated against the operator-managed topology.

A legacy installation that cannot upgrade needs a separate, approved recovery
runbook for its exact image digests and database revision. Keep that work
isolated from an operator-managed platform.
