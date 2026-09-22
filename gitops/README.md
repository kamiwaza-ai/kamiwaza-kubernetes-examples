# GitOps

Deliver a Kamiwaza platform from a source of truth instead of from a terminal. One scenario per delivery controller, and the same platform underneath both.

**Tags:** #gitops #flux #argocd #continuous-delivery

---

## Scenarios

| Scenario         | Path                 | Tags                                   |
| ---------------- | -------------------- | -------------------------------------- |
| Flux delivery    | [`flux/`](flux/)     | #gitops #flux #helm #kustomize #health |
| Argo CD delivery | [`argocd/`](argocd/) | #gitops #argocd #sync-waves #health    |

Both scenarios deliver the intent in [`platform/`](platform/), which is the published [quickstart](../operator/quickstart/) package rather than a copy of it. Only the delivery differs.

---

## What a delivery controller has to get right

The platform is a two-layer installation, and both layers are the same whoever applies them:

1. **The manager layer** installs the published API schemas and one manager, from the release chart, with immutable administrator policy as chart input.
2. **The intent layer** applies one `KamiwazaPlatform` against the API the first layer installed.

Three properties are not automatic in either controller, and each scenario states how it gets them:

- **Ordering.** The intent layer must not be applied before the API exists. Flux uses `dependsOn`; Argo CD uses sync waves in an app-of-apps.
- **Health.** Neither controller knows what a healthy `KamiwazaPlatform` is. Without a custom health assessment, both report success the moment the API server accepts the resource — before an image has been pulled. Flux uses CEL expressions; Argo CD uses a Lua health check.
- **Terminal failure.** `Blocked=True` is the operator's answer, not a delay: immutable policy, a missing administrator-owned prerequisite, or intent it will not act on. A delivery that waits out a blocked platform turns a clear answer into a timeout.

## Nothing here is a platform difference

The platform is delivery-agnostic by requirement, and the scenarios exist partly to keep it honest. Running them found two defects that a terminal install never reaches:

- The operator chart rendered a duplicate `app.kubernetes.io/component` key. Helm's own loader keeps the last one and installs; Flux's Helm post-renderer parses strictly and refused the chart outright. Fixed in the operator chart, with a conformance test that renders the chart and rejects any document a strict parser will not take.
- Deleting a platform and applying it again — what a delivery controller does on re-provision — left the new platform permanently blocked on the previous one's signer objects. Fixed in the operator: ownership now recognizes the declared installation identity, which recreation preserves, and deleting a platform removes its signer.

Neither was a GitOps problem. Both were platform defects that a GitOps path happened to reach first.

---

## Prerequisites

Both scenarios assume the [common operator prerequisites](../operator/README.md#common-prerequisites) and, in addition:

| Requirement                | Notes                                                                                                                               |
| -------------------------- | ----------------------------------------------------------------------------------------------------------------------------------- |
| A delivery controller      | Flux v2.5 or later for CEL health expressions; Argo CD v3.1 or later for OCI sources.                                               |
| A source the cluster reads | An OCI registry in these scenarios. A Git source is a drop-in replacement for the source object; the layers above it do not change. |
| Namespaces                 | The platform namespace and the manager namespace are administrator-owned and are created before delivery starts.                    |
| Image pull credentials     | A Secret in the platform namespace. It is named by policy and never carried in a delivery source.                                   |

---

## Related

- [`../operator/quickstart/`](../operator/quickstart/) — the same installation applied by hand, with the field-by-field rationale.
- [`../operator/deletion/`](../operator/deletion/) — deletion and retention, which neither scenario performs by pruning.
- [`../operator/upgrades/`](../operator/upgrades/) — changing platform intent, which under GitOps is a change to the intent layer.
