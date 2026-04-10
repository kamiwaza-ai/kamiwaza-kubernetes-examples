# Service access patterns

**Scenario:** how to reach Kamiwaza services from outside the cluster. Covers `kubectl port-forward` (works everywhere), `NodePort` (for direct node access), and `LoadBalancer`/`Ingress` (for production).

**Tags:** #networking #external-access #port-forward #ingress

## Service map

| Service | In-cluster URL | Default port | Purpose |
| --- | --- | --- | --- |
| **Frontend (UI)** | `http://frontend:3000` | 3000 | Kamiwaza web interface |
| **Core API** | `http://core-raycluster-head-svc:7777` | 7777 | REST API (served by Ray head) |
| **Keycloak** | `http://keycloak:8080` | 8080 | Identity provider (when auth enabled) |
| **Ray Dashboard** | `http://core-raycluster-head-svc:8265` | 8265 | Ray cluster management UI |
| **Traefik** | `http://traefik:443` | 443 (HTTPS), 80 (HTTP) | Ingress controller (routes all traffic) |
| **Grafana** | `http://kube-prometheus-stack-grafana:80` | 80 | Monitoring dashboards (if deployed) |
| **PostgreSQL** | `core-postgres:5432` | 5432 | Application database (not exposed externally) |
| **etcd** | `core-etcd:2379` | 2379 | Key-value store (not exposed externally) |

## Port-forward (works on any cluster)

The simplest way to access services. No cluster configuration needed.

```bash
# Frontend UI — open http://localhost:3000
kubectl port-forward svc/frontend 3000:3000 -n kamiwaza

# Core API — open http://localhost:7777
kubectl port-forward svc/core-raycluster-head-svc 7777:7777 -n kamiwaza

# Keycloak admin console — open http://localhost:9080
kubectl port-forward svc/keycloak 9080:8080 -n kamiwaza

# Ray Dashboard — open http://localhost:8265
kubectl port-forward svc/core-raycluster-head-svc 8265:8265 -n kamiwaza

# Grafana — open http://localhost:3001
kubectl port-forward svc/kube-prometheus-stack-grafana 3001:80 -n monitoring

# Multiple services at once (background)
kubectl port-forward svc/frontend 3000:3000 -n kamiwaza &
kubectl port-forward svc/core-raycluster-head-svc 7777:7777 -n kamiwaza &
kubectl port-forward svc/keycloak 9080:8080 -n kamiwaza &
echo "Frontend: http://localhost:3000"
echo "API:      http://localhost:7777"
echo "Keycloak: http://localhost:9080"
```

## Traefik routes (default path)

When Kamiwaza is deployed with the standard network chart, Traefik handles all external routing. The frontend, API, and Keycloak are all accessible through a single domain:

| URL | Routes to |
| --- | --- |
| `https://kamiwaza.test/` | Frontend |
| `https://kamiwaza.test/api/*` | Core API (via Ray head) |
| `https://kamiwaza.test/realms/*` | Keycloak (OIDC endpoints) |
| `https://kamiwaza.test/admin/*` | Keycloak admin console |

This requires DNS resolution for `kamiwaza.test` pointing to the Traefik service IP (or a load balancer in front of it).

```bash
# Find the Traefik external IP
kubectl get svc traefik -n kamiwaza -o jsonpath='{.status.loadBalancer.ingress[0].ip}' 2>/dev/null || \
kubectl get svc traefik -n kamiwaza -o jsonpath='{.spec.clusterIP}'

# Test with curl (skip TLS verification for self-signed certs)
TRAEFIK_IP=$(kubectl get svc traefik -n kamiwaza -o jsonpath='{.status.loadBalancer.ingress[0].ip}' 2>/dev/null)
curl -sk --resolve kamiwaza.test:443:${TRAEFIK_IP} https://kamiwaza.test/api/node/node_status
```

## NodePort (direct node access)

Some services are pre-configured as NodePort:

```bash
# Check which services have NodePort
kubectl get svc -n kamiwaza -o wide | grep NodePort

# Frontend NodePort
FRONTEND_PORT=$(kubectl get svc frontend -n kamiwaza -o jsonpath='{.spec.ports[0].nodePort}')
echo "Frontend: http://<any-node-ip>:${FRONTEND_PORT}"

# Ray Dashboard NodePort
RAY_PORT=$(kubectl get svc core-raycluster-dashboard -n kamiwaza -o jsonpath='{.spec.ports[0].nodePort}')
echo "Ray Dashboard: http://<any-node-ip>:${RAY_PORT}"
```

## Verification

```bash
# Verify services from the scheduler pod (already allowed by NetworkPolicies)
kubectl exec -n kamiwaza deployment/core-scheduler -c core -- sh -c '
  echo "API:       $(curl -sf http://core-raycluster-head-svc:7777/api/node/node_status | head -c 80)"
  echo "Keycloak:  $(curl -sf http://keycloak:8080/health/ready && echo "ready")"
  echo "Frontend:  $(curl -sf -o /dev/null -w "%{http_code}" http://frontend:3000)"
'

# Verify Traefik routes are configured
kubectl get ingressroute -n kamiwaza -o custom-columns='NAME:.metadata.name,MATCH:.spec.routes[0].match'
```

## Credentials

```bash
# Keycloak admin password
kubectl get secret keycloak-admin -n kamiwaza -o jsonpath='{.data.password}' | base64 -d; echo

# Grafana admin password
kubectl get secret kube-prometheus-stack-grafana -n monitoring -o jsonpath='{.data.admin-password}' | base64 -d 2>/dev/null; echo

# Kamiwaza admin password (if present)
kubectl get secret kamiwaza-user-admin -n kamiwaza -o jsonpath='{.data.password}' 2>/dev/null | base64 -d; echo
```

## Notes

- **Port-forward** is the safest option — no cluster changes, works with any RBAC.
- **Traefik** is the production path — all API and UI traffic goes through it. The domain (`kamiwaza.test` by default) must resolve to the Traefik service IP.
- **NodePort** services are accessible on every cluster node at the allocated port. Find node IPs with `kubectl get nodes -o wide`.
- **PostgreSQL and etcd** should not be exposed externally. Use `kubectl exec` or `kubectl port-forward` for administrative access.
