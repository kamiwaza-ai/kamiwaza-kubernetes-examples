# Service access patterns

**Scenario:** access an operator-managed Kamiwaza platform from outside its
namespace. Use `kubectl port-forward` for local diagnostics. Use the
administrator-owned Gateway API listener for customer traffic.

**Tags:** #networking #external-access #port-forward #gateway-api

## Scope

This example uses services that the platform operator creates. It does not
create a `Gateway`, load balancer, ingress controller, or DNS record.

Set these values before you run the commands:

```bash
export PLATFORM_NAMESPACE=kamiwaza-examples
export PLATFORM_NAME=kamiwaza
```

## Service map

| Service | In-cluster URL | Purpose |
| --- | --- | --- |
| Frontend | `http://frontend:3000` | Kamiwaza web interface |
| Core API | `http://core-api:7777` | Platform API |
| Keycloak | `http://keycloak:80` | Identity provider |
| Delegated-compute dashboard | `http://core-raycluster-head-svc:8265` | Restricted diagnostic UI |
| Grafana | `http://kube-prometheus-stack-grafana.monitoring:80` | Optional monitoring UI |
| PostgreSQL | `core-postgres:5432` | Internal database. Do not expose it. |
| etcd | `core-etcd:2379` | Internal store. Do not expose it. |

## Use a port-forward for diagnostics

Run each port-forward in a separate terminal. When the diagnostic task is
complete, stop the port-forward.

```bash
# Frontend: http://127.0.0.1:3000
kubectl -n "$PLATFORM_NAMESPACE" port-forward service/frontend 3000:3000

# Core API: http://127.0.0.1:7777
kubectl -n "$PLATFORM_NAMESPACE" port-forward service/core-api 7777:7777

# Keycloak: http://127.0.0.1:9080
kubectl -n "$PLATFORM_NAMESPACE" port-forward service/keycloak 9080:80

# Grafana: http://127.0.0.1:3001
kubectl -n monitoring port-forward service/kube-prometheus-stack-grafana 3001:80
```

When the terminal exits, the port-forward stops. It does not change a Service
or open a cluster port.

## Use Gateway API for customer traffic

The operator publishes standard `HTTPRoute` objects. Each route attaches to the
administrator-approved `Gateway` and hostname from platform policy.

```bash
kubectl -n "$PLATFORM_NAMESPACE" get httproutes
kubectl -n "$PLATFORM_NAMESPACE" get httproute frontend core keycloak
```

The default public paths are:

| Path | Backend |
| --- | --- |
| `/` | `frontend:3000` |
| `/api` | `core-api:7777` |
| `/.well-known/openid-configuration` | Keycloak realm discovery |
| `/realms` and `/resources` | `keycloak:80` |
| `/v1` | governed protocol data plane |

Model and extension controllers can publish more `HTTPRoute` objects. Inspect
the live objects instead of assuming their generated paths.

### Verify route attachment

Get the route hostname and parent from the live object:

```bash
export PLATFORM_DOMAIN="$(kubectl -n "$PLATFORM_NAMESPACE" get \
  kamiwazaplatform "$PLATFORM_NAME" -o jsonpath='{.spec.domain}')"
export GATEWAY_NAME="$(kubectl -n "$PLATFORM_NAMESPACE" get httproute frontend \
  -o jsonpath='{.spec.parentRefs[0].name}')"
export GATEWAY_NAMESPACE="$(kubectl -n "$PLATFORM_NAMESPACE" get httproute frontend \
  -o jsonpath='{.spec.parentRefs[0].namespace}')"
export GATEWAY_NAMESPACE="${GATEWAY_NAMESPACE:-$PLATFORM_NAMESPACE}"

kubectl -n "$PLATFORM_NAMESPACE" get httproute frontend \
  -o jsonpath='{range .status.parents[0].conditions[*]}{.type}={.status}{"\n"}{end}'
kubectl -n "$GATEWAY_NAMESPACE" get gateway "$GATEWAY_NAME" \
  -o jsonpath='{range .status.conditions[*]}{.type}={.status}{"\n"}{end}'
```

Require `Accepted=True` and `ResolvedRefs=True` on the route. Require
`Programmed=True` on the Gateway before you send customer traffic.

Configure DNS so that `$PLATFORM_DOMAIN` resolves to the Gateway address. If the
listener uses a private CA, give its CA file to the client. Do not disable TLS
verification.

```bash
curl --fail --show-error --cacert /path/to/administrator-ca.pem \
  "https://${PLATFORM_DOMAIN}/"
curl --fail --show-error --cacert /path/to/administrator-ca.pem \
  "https://${PLATFORM_DOMAIN}/.well-known/openid-configuration"
```

When the listener uses a public CA, omit `--cacert`.

## Restrict diagnostic surfaces

Do not publish PostgreSQL, etcd, the delegated-compute dashboard, model
runtime, or management ports through public routes.

Use a temporary dashboard port-forward only during an approved diagnostic:

```bash
kubectl -n "$PLATFORM_NAMESPACE" port-forward \
  service/core-raycluster-head-svc 8265:8265
```

Use the approved credential workflow for Keycloak, Grafana, and Kamiwaza. Do
not print Secret values into terminal logs or automation output.
