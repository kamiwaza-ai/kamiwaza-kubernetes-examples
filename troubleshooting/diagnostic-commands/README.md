# Diagnostic commands

**Scenario:** pre-built diagnostic commands for every Kamiwaza component. Run `kamiwaza-diagnostics.sh` for a full health check, or use individual commands from this reference.

**Tags:** #troubleshooting #diagnostics #health-check

## Quick start

```bash
chmod +x troubleshooting/diagnostic-commands/kamiwaza-diagnostics.sh
./troubleshooting/diagnostic-commands/kamiwaza-diagnostics.sh
```

## Component-by-component reference

### Platform overview

```bash
# All pods and their status
kubectl get pods -n kamiwaza -o wide

# Pods not in Running/Completed state
kubectl get pods -n kamiwaza --field-selector='status.phase!=Running,status.phase!=Succeeded'

# Recent restarts (top 10)
kubectl get pods -n kamiwaza -o jsonpath='{range .items[*]}{.metadata.name}{"\t"}{range .status.containerStatuses[*]}{.restartCount}{end}{"\n"}{end}' | sort -t$'\t' -k2 -rn | head -10

# Events (warnings only)
kubectl get events -n kamiwaza --field-selector type=Warning --sort-by='.lastTimestamp'
```

### Core scheduler

```bash
# Pod status and readiness
kubectl get pods -n kamiwaza -l app.kubernetes.io/name=core-scheduler

# Logs (last 100 lines, errors only)
kubectl logs -n kamiwaza deployment/core-scheduler -c core --tail=100 | grep -iE 'error|exception|traceback'

# Environment (auth mode, rebac, hot-reload)
kubectl exec -n kamiwaza deployment/core-scheduler -c core -- env | grep -E '^(AUTH_|KAMIWAZA_|REBAC_)' | sort

# API health check
kubectl exec -n kamiwaza deployment/core-scheduler -c core -- \
  curl -sf http://localhost:7777/api/node/node_status 2>/dev/null | python3 -m json.tool || echo "API not responding"
```

### Ray cluster

```bash
# Head and worker pods
kubectl get pods -n kamiwaza -l ray.io/cluster=core-raycluster

# Ray dashboard (port-forward to access)
# kubectl port-forward svc/core-raycluster-dashboard 8265:8265 -n kamiwaza

# Ray cluster status via head node
kubectl exec -n kamiwaza $(kubectl get pod -n kamiwaza -l ray.io/node-type=head -o jsonpath='{.items[0].metadata.name}') -- \
  python3 -c "import ray; ray.init('auto'); print(ray.cluster_resources())" 2>/dev/null || echo "Ray not reachable"

# Ray head logs (last 50 lines)
kubectl logs -n kamiwaza $(kubectl get pod -n kamiwaza -l ray.io/node-type=head -o jsonpath='{.items[0].metadata.name}') --tail=50
```

### PostgreSQL

```bash
# Pod status
kubectl get pods -n kamiwaza -l app.kubernetes.io/name=core-postgres

# Connection count and database size
kubectl exec -n kamiwaza core-postgres-0 -- \
  psql -U core -d kamiwaza -c "SELECT numbackends AS connections, pg_size_pretty(pg_database_size('kamiwaza')) AS db_size FROM pg_stat_database WHERE datname = 'kamiwaza';"

# Active queries (long-running)
kubectl exec -n kamiwaza core-postgres-0 -- \
  psql -U core -d kamiwaza -c "SELECT pid, now() - pg_stat_activity.query_start AS duration, query FROM pg_stat_activity WHERE state = 'active' AND query NOT LIKE '%pg_stat%' ORDER BY duration DESC LIMIT 5;"

# Table row counts (top 10)
kubectl exec -n kamiwaza core-postgres-0 -- \
  psql -U core -d kamiwaza -c "SELECT relname AS table, n_live_tup AS rows FROM pg_stat_user_tables ORDER BY n_live_tup DESC LIMIT 10;"
```

### etcd

```bash
# Cluster health
kubectl exec -n kamiwaza core-etcd-0 -- etcdctl endpoint health

# Cluster status (leader, DB size, raft index)
kubectl exec -n kamiwaza core-etcd-0 -- etcdctl endpoint status --write-out=table

# Member list
kubectl exec -n kamiwaza core-etcd-0 -- etcdctl member list --write-out=table

# Key count
kubectl exec -n kamiwaza core-etcd-0 -- etcdctl get "" --prefix --keys-only 2>/dev/null | grep -c .
```

### Keycloak

```bash
# Pod status (only when auth.enabled=true)
kubectl get pods -n kamiwaza -l app.kubernetes.io/name=keycloak

# Health endpoint
kubectl exec -n kamiwaza deployment/core-scheduler -c core -- \
  curl -sf http://keycloak:8080/health/ready 2>/dev/null && echo "Keycloak healthy" || echo "Keycloak not ready"

# Keycloak logs (auth errors)
kubectl logs -n kamiwaza deployment/keycloak --tail=100 2>/dev/null | grep -iE 'error|warn|fail'
```

### Frontend

```bash
# Pod status
kubectl get pods -n kamiwaza -l app.kubernetes.io/name=frontend

# Health check
kubectl exec -n kamiwaza deployment/frontend -- curl -sf http://localhost:3000 >/dev/null 2>&1 && echo "Frontend healthy" || echo "Frontend not responding"
```

### Traefik (networking)

```bash
# Traefik pod and service
kubectl get pods -n kamiwaza -l app.kubernetes.io/name=traefik
kubectl get svc traefik -n kamiwaza

# All IngressRoutes
kubectl get ingressroute -n kamiwaza

# Traefik entrypoints and middleware
kubectl get middleware -n kamiwaza
```

### Extensions

```bash
# Extension operator
kubectl get pods -n kamiwaza-system -l app.kubernetes.io/name=extension-operator

# Extension pods
kubectl get pods -n kamiwaza-extensions
kubectl get pods -n kamiwaza-sandboxes

# Extension operator logs
kubectl logs -n kamiwaza-system deployment/extension-operator --tail=50 2>/dev/null | grep -iE 'error|warn'
```

### Storage

```bash
# PVC usage across Kamiwaza namespaces
kubectl get pvc -n kamiwaza
kubectl get pvc -n monitoring 2>/dev/null
```

## Notes

- The diagnostic script (`kamiwaza-diagnostics.sh`) runs all of the above in sequence and outputs a single report.
- All commands are read-only — no modifications to the cluster.
- Commands that reference Keycloak will return "not found" on lite-mode deployments — this is expected.
