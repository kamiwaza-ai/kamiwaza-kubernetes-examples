# Running MCP servers in Kamiwaza

**Scenario:** the three shapes an MCP server takes in a platform installation, and how an
MCP client connects to one it did not start itself.

**Tags:** #protocols #mcp #oauth #extensions #data-plane

The same server code runs in all three shapes. What changes is who authenticates the
caller, and therefore what has to be published for a client to find its way in.

| Shape | Who runs it | Who authenticates | MCP endpoint |
| --- | --- | --- | --- |
| **A. Platform extension** | The extension controller, from a pinned package | The platform edge | `https://<domain>/extensions/<name>/mcp` |
| **B. Raw workload** | You, as an ordinary Deployment | The platform edge, or the server itself | `https://<domain>/<your prefix>/mcp` |
| **C. Local process** | The MCP host on your machine | Nobody — one member, one pipe | standard input and output |

Related scenarios: [operator/extensions](../../operator/extensions) for the extension
lifecycle itself, and [operator/protocol-data-plane](../../operator/protocol-data-plane)
for the governed endpoint that fronts tool, agent, and model protocols.

## Prerequisites

- A reconciled `KamiwazaPlatform` with a domain:
  `kubectl -n kamiwaza get kamiwazaplatform -o jsonpath='{.items[0].spec.domain}'`.
- The shared manager watching `kamiwaza-examples`, for shape A.
- For shape C, Python 3.12 and a personal access token from the platform.

## Files

| File | Purpose |
| --- | --- |
| [extension-kamiwaza-mcp.yaml](extension-kamiwaza-mcp.yaml) | Shape A — the Kamiwaza MCP as a `KamiwazaExtension` |
| [raw-mcp-server.yaml](raw-mcp-server.yaml) | Shape B — an ordinary workload published on the platform domain |
| [stdio-launcher.py](stdio-launcher.py) | Shape C — one member, one credential, over a pipe |
| [check-discovery.sh](check-discovery.sh) | Proves a client can discover how to authenticate |

---

## Shape A — the Kamiwaza MCP as a platform extension

The container entry point is `python -m kamiwaza_mcp`, which builds the **hosted**
deployment. The platform injects `KAMIWAZA_API_URL`; the server refuses to start
without it rather than defaulting to another cluster's address.

```bash
kubectl apply --server-side \
  --field-manager=platform-operator-user \
  -f extension-kamiwaza-mcp.yaml

kubectl -n kamiwaza-examples get kamiwazaextensions.extensions.kamiwaza.ai kamiwaza-mcp
```

Two settings are yours, both in the manifest:

| Variable | Effect |
| --- | --- |
| `KAMIWAZA_MCP_READ_ONLY` | `true` serves the read-only surface. A value that is neither on nor off is refused at startup rather than read as off. |
| `KAMIWAZA_MCP_CONTINUATION_KEYS` | The ring that seals multi-round exchanges — an approval, a task handle. 32 bytes minimum, newest first. |

Read the published route rather than assuming the path:

```bash
kubectl -n kamiwaza-examples get httproute \
  -o custom-columns=NAME:.metadata.name,PATHS:.spec.rules[*].matches[*].path.value
```

An extension that declares no `networking.ingress` is reachable only in-cluster, which
is the right shape for a tool server that other workloads call and no browser does.

---

## Shape B — a raw MCP server, not an extension

Any workload that speaks Streamable HTTP can serve MCP here. The difference between the
two sub-shapes is who checks the credential.

### B1 — behind the platform edge

```bash
kubectl apply --server-side \
  --field-manager=platform-operator-user \
  -f raw-mcp-server.yaml
```

The platform authenticates, so the workload runs the hosted shape and publishes no
metadata of its own. For a client to discover how to authenticate against it, the path
must be one of the platform's published protected resources:

```bash
kubectl -n kamiwaza get cm core-config \
  -o jsonpath='{.data.AUTH_PROTECTED_RESOURCE_PATHS}'
```

The operator renders that list from the routes it declares: `/api`, and `/v1` when the
protocol data plane is selected. A path outside the list still refuses unauthenticated
callers — what it loses is the metadata document, which leaves a conformant client
holding a refusal it cannot act on.

### B2 — answering for itself

A server reachable without the platform edge in front of it owns the whole duty: verify
the bearer credential, name the scopes a caller lacks, and serve its own
`/.well-known/oauth-protected-resource`. In the Kamiwaza MCP library that is
`standalone_deployment(ProtectedResourceDuties(verify=..., resource=...))`. The
`resource` is optional in the type only because the verifier already refuses every
caller without a valid credential; leave it out and a conformant host has no way to
recover from the refusal.

---

## Shape C — a local process over standard input and output

The MCP host launches the server on your machine and it serves exactly one member: the
one whose credential it was started with. There is no edge, no port, and no metadata.

```bash
export KAMIWAZA_API_URL="https://<domain>/api"
export KAMIWAZA_API_KEY="<personal access token>"
export KAMIWAZA_MEMBER="<your member name>"
export KAMIWAZA_TENANT="<your tenant>"
python stdio-launcher.py
```

Client configuration, for any host that launches a command:

```json
{
  "mcpServers": {
    "kamiwaza": {
      "command": "python",
      "args": ["/path/to/stdio-launcher.py"],
      "env": {
        "KAMIWAZA_API_URL": "https://<domain>/api",
        "KAMIWAZA_API_KEY": "<personal access token>",
        "KAMIWAZA_MEMBER": "<your member name>",
        "KAMIWAZA_TENANT": "<your tenant>"
      }
    }
  }
}
```

---

## Connecting a client to a server running inside Kamiwaza

A conformant MCP client (specification revision 2026-07-28, section 4) does not have to
be told where to authenticate. It finds out:

1. It calls the MCP endpoint with no token and gets `401` with a `WWW-Authenticate`
   header naming `resource_metadata`.
2. It fetches that URL and reads `authorization_servers`.
3. It discovers the authorization server's metadata, obtains a client ID, runs the
   authorization code flow with PKCE and a `resource` parameter, and retries.

Prove the first two steps against your own installation:

```bash
DOMAIN=$(kubectl -n kamiwaza get kamiwazaplatform -o jsonpath='{.items[0].spec.domain}')
./check-discovery.sh "https://$DOMAIN" /v1 /v1/models
```

On the wire:

```console
$ curl -sD- -o /dev/null https://$DOMAIN/v1/models
HTTP/2 401
www-authenticate: Bearer resource_metadata="https://<domain>/.well-known/oauth-protected-resource/v1", scope="openid profile email"

$ curl -s https://$DOMAIN/.well-known/oauth-protected-resource/v1
{"resource":"https://<domain>/v1",
 "authorization_servers":["https://<domain>/realms/kamiwaza"],
 "scopes_supported":["openid","profile","email"],
 "bearer_methods_supported":["header"]}
```

The challenge comes from the platform's decision service even when the request never
reached it directly. The data plane in front of tool, agent, and model protocols holds
none of the five authority surfaces: it calls the decision service for every request
and returns that refusal to the caller unchanged, challenge header included.

For a client that already holds a token, skip the discovery and speak the protocol:

```bash
curl -s -H "Authorization: Bearer $TOKEN" \
  -H 'Content-Type: application/json' \
  -H 'Accept: application/json, text/event-stream' \
  -d '{"jsonrpc":"2.0","id":1,"method":"initialize","params":{
        "protocolVersion":"2026-07-28","capabilities":{},
        "clientInfo":{"name":"curl","version":"0"}}}' \
  "https://$DOMAIN/extensions/kamiwaza-mcp/mcp"
```

### One thing to check on your own realm

The client sends the RFC 8707 `resource` parameter when it asks for a token. Keycloak
does not turn that into an audience by itself, so the token carries whatever audience
the realm is configured to mint. Confirm that the audience the platform validates
(`AUTH_GATEWAY_JWT_AUDIENCE` in `core-config`) is one your realm issues, or add a
mapper for it. A client can complete discovery perfectly and still be refused at the
last step if these two disagree.
