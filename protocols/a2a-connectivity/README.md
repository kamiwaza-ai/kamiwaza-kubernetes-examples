# A2A connectivity

## Purpose

Publish two independently owned A2A agents through governed provider-neutral routes. Preserve agent identity, task ownership, streaming semantics, and authorization without exposing internal Services, prompts, tools, memory, or model configuration.

## Contract status

`protocols.kamiwaza.io/v1alpha1 A2ARoute` and `adminPolicy.protocols.a2a` are proposed operator contracts. The current operator can render the two `Extension` packages but does not install this route CRD or program A2A routes. Render with Kustomize now. Do not apply the combined scenario until API schema, CEL rules, status, route translation, and protocol checks exist.

No public field names a routing implementation. Release-owned image inventory selects the implementation separately.

## Grounded design

A2A 1.0 treats agents as opaque, independently owned systems. Agent Cards describe interfaces and skills. Messages create or continue tasks. Task state and artifacts remain with the target agent. HTTP+JSON paths include `message:send`, `message:stream`, task lookup, and explicit cancellation.

References:

- <https://a2a-protocol.org/v1.0.0/specification/>
- <https://github.com/a2aproject/A2A/blob/main/specification/a2a.proto>

## Contract boundaries

- One `A2ARoute` maps one stable path to one same-namespace `Extension` endpoint.
- Route intent cannot name a Service, Pod, host, or implementation-native route.
- Extension identity is authoritative. Agent Card text, skills, URLs, and signatures are untrusted descriptive input.
- Public cards replace internal interface URLs with the governed HTTPS route and platform security scheme.
- The decision service authorizes discovery, send, stream, get, subscribe, cancel, and notification operations before backend I/O.
- The operator keeps target endpoints namespace-local and generates NetworkPolicy that admits only protocol-plane workloads. Target endpoints are never published directly.
- The target extension owns task state. The protocol plane owns transient transport state only.
- Stream disconnect does not cancel work. Reconnect resumes the same task without duplicate execution.
- One target outage degrades only its route. Other agent, MCP, and model routes continue.

## Files

| File                         | Purpose                                                               |
| ---------------------------- | --------------------------------------------------------------------- |
| `admin-policy-fragment.yaml` | A2A version, binding, payload, task, identity, and failure ceilings   |
| `extensions.yaml`            | Two digest-verified agents with retained task storage                 |
| `routes.yaml`                | Two proposed provider-neutral route objects                           |
| `a2a-check.yaml`             | Card, message, task, stream, cancellation, and unauthenticated checks |

## Prerequisites

- StorageClass `example-rwo` for each agent's retained task volume.
- Operator configured to watch `kw-a2a` and allow extension packages from `example.invalid` for this lab.
- Existing Secret `a2a-check-token` with key `token` for a short-lived principal granted the documented operations on both routes.
- `platform.yaml` carries one intentionally non-pullable, provider-neutral image pin only to satisfy the current CRD shape. Replace `spec.images.pinned` with the complete reviewed release inventory before apply.
- Operator-projected ConfigMap `kamiwaza-trust-bundle` with key `ca-certificates.crt` for protocol-plane server verification.

## Render now

```bash
kubectl kustomize .
```

## Apply after operator support exists

Merge the administrator fragment into operator values before applying tenant intent.

```bash
kubectl diff --server-side --field-manager=platform-operator-user -k .
kubectl apply --server-side --field-manager=platform-operator-user -k .
kubectl -n kw-a2a wait --for=condition=Ready extension/reviewer --timeout=15m
kubectl -n kw-a2a wait --for=condition=Ready extension/researcher --timeout=15m
kubectl -n kw-a2a wait --for=condition=Ready a2aroute/reviewer --timeout=10m
kubectl -n kw-a2a wait --for=condition=Ready a2aroute/researcher --timeout=10m
kubectl -n kw-a2a logs job/a2a-check
```

The check requires public agent cards with governed URLs, a completed task, task lookup, one streamed result, explicit cancellation of a working task, stable task IDs, and rejection without authentication.

## Failure and recovery

Start a `hold` task, then pause only its target `Extension`. The route reports `TargetUnavailable`. Task identity and retained state remain. Other routes continue. Restore the extension to `running`, fetch the same task ID, and finish or cancel it without route changes.

Drop a streaming connection after receiving an event ID. Reconnect or subscribe with the same authorized task identity. The target must not run the message twice, and the disconnect must not change task state to canceled.

If the decision service is unavailable, discovery and task operations deny before backend I/O. A cached Agent Card never acts as an authorization grant.

## Cleanup

```bash
kubectl delete -k .
kubectl -n kw-a2a get pvc
```

Route deletion removes only route and transient connection state. Extension task PVCs remain until the approved data-destruction procedure removes them.
