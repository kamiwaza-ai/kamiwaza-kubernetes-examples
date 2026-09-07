# Multi-tenancy scenarios

These scenarios use real Kamiwaza applications and authorization boundaries.
They do not manufacture tenant-specific Kubernetes APIs that the current
platform does not expose.

| Scenario                                                 | Tenant boundary                                             | Shared resources                                                           |
| -------------------------------------------------------- | ----------------------------------------------------------- | -------------------------------------------------------------------------- |
| [Tomo shared-workroom isolation](tomo-shared-workrooms/) | Authenticated tenant and workroom context enforced by ReBAC | One Kamiwaza platform, one Tomo deployment, administrator-published models |

## Current Kubernetes API boundary

`KamiwazaPlatform.spec.models` remains administrator-owned platform intent.
`ModelDeployment` is subordinate controller-owned state, not a tenant resource.
`KamiwazaExtension` supports owner and workroom attribution through the
authenticated platform extension API, but its Kubernetes namespace is selected
by platform installation configuration rather than by an arbitrary tenant.

The Tomo scenario therefore exercises the supported product boundary:

- one main platform;
- one real Tomo deployment from the shipped application catalog;
- two authenticated tenants with separate claims and ReBAC tuples;
- tenant/workroom-scoped agents, conversations, files, and model use; and
- Kubernetes inspection of the real generated extension and model resources.

A future namespace-per-tenant model or tenant-authored model CRD requires
operator/API design before an example can claim it works.
