# MCP federation

## Purpose

Expose two independently owned MCP tool extensions through one governed Streamable HTTP endpoint. Source names remain stable. Every public tool name is source-prefixed. Authentication and authorization stay with the platform decision service.

## Contract status

`protocols.kamiwaza.io/v1alpha1 MCPFederation` and `adminPolicy.protocols` are proposed operator contracts. The current operator can render the two `Extension` packages but does not install the federation CRD or program this route. Render with Kustomize now. Do not apply the combined scenario until API schema, CEL validation, status, route translation, and protocol checks exist.

No public field names a routing implementation. Release-owned image inventory selects the implementation separately.

## Grounded design

MCP `2025-11-25` uses JSON-RPC and Streamable HTTP. HTTP clients send both `application/json` and `text/event-stream` in `Accept`. Servers validate `Origin`, negotiate protocol version, manage `MCP-Session-Id`, and use `Last-Event-ID` only to resume the named stream.

References:

- <https://modelcontextprotocol.io/specification/2025-11-25>
- <https://modelcontextprotocol.io/specification/2025-11-25/basic/transports>

## Contract boundaries

- `MCPFederation` contains one stable path and an explicit ordered source list.
- Each source references one same-namespace `Extension` endpoint by name. It cannot name a Service, Pod, host, or native routing resource.
- V1 has no label selector. Adding a label cannot silently enroll a tool server.
- All public tool names use `<source>.<tool>`. A collision cannot redirect a call to another source.
- The decision service filters discovery and decides every call. Its outage denies before backend I/O.
- The operator keeps source endpoints namespace-local and generates NetworkPolicy that admits only protocol-plane workloads. Source endpoints are never published directly.
- One source outage removes only that source's tools and reports `SourceUnavailable`. Healthy sources continue.
- The protocol plane owns transport sessions, not tool state or authorization policy.

## Files

| File                         | Purpose                                                                    |
| ---------------------------- | -------------------------------------------------------------------------- |
| `admin-policy-fragment.yaml` | MCP version, origin, source-count, session, and payload ceilings           |
| `extensions.yaml`            | Two digest-verified tool packages with colliding `lookup` names            |
| `federation.yaml`            | Proposed provider-neutral aggregate intent                                 |
| `mcp-check.yaml`             | Negotiation, discovery, source routing, denial, origin, and session checks |

## Prerequisites

- Operator configured to watch `kw-mcp-federation` and allow extension packages from `example.invalid` for this lab.
- `platform.yaml` carries one intentionally non-pullable, provider-neutral image pin only to satisfy the current CRD shape. Replace `spec.images.pinned` with the complete reviewed release inventory and replace `example-rwo` before apply.
- Operator-projected ConfigMap `kamiwaza-trust-bundle` with key `ca-certificates.crt` for protocol-plane server verification.
- Existing Secret `mcp-check-token` with key `token`. Use a short-lived principal grant for discovery plus four public tools. Do not grant `records.restricted` or `catalog.restricted`.
- No Secret value in Git, a custom resource, command output, or status.

## Render now

```bash
kubectl kustomize .
```

## Apply after operator support exists

Merge the administrator fragment into operator values before applying tenant intent.

```bash
kubectl diff --server-side --field-manager=platform-operator-user -k .
kubectl apply --server-side --field-manager=platform-operator-user -k .
kubectl -n kw-mcp-federation wait --for=condition=Ready extension/records-tools --timeout=15m
kubectl -n kw-mcp-federation wait --for=condition=Ready extension/catalog-tools --timeout=15m
kubectl -n kw-mcp-federation wait --for=condition=Ready mcpfederation/team-tools --timeout=10m
kubectl -n kw-mcp-federation logs job/mcp-check
```

The check requires protocol `2025-11-25`, a session ID, exactly four authorized source-prefixed tools, correct call attribution, a denied restricted tool, rejected origin, and explicit session deletion.

## Failure and recovery

Pause only `records-tools`. `MCPFederation` reports that source unavailable, removes `records.*` from discovery, and continues serving `catalog.*`. Existing calls to the unavailable source fail with a bounded protocol error. Authorization denials stay denials.

Pause both sources. The endpoint remains addressable but returns a protocol-level unavailable error. Restore each `Extension.spec.state` to `running`. The same route returns without a new path, grant, or federation object.

A configuration change updates `status.configurationDigest`. A source catalog change updates `status.catalogDigest`. Reapplying identical intent changes neither digest nor workload template.

## Cleanup

```bash
kubectl delete -k .
```

Source extension deletion follows normal extension retention. Federation deletion never deletes either source or its durable data.
