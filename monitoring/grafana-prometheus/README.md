# Grafana + Prometheus monitoring for Kamiwaza

**Scenario:** deploy a Prometheus + Grafana + Loki + Alloy monitoring stack with Kamiwaza-specific ServiceMonitors, exporters, and 8 pre-built dashboards. Each component is independently usable — deploy the full stack or pick what you need.

**Tags:** #monitoring #prometheus #grafana #loki #dashboards

## What you get

| Component | Path | Purpose |
| --- | --- | --- |
| **Dashboards** | `dashboards/` | 8 Grafana dashboards (kam-01 through kam-08) covering platform health, inference, API, data infrastructure, extensions, auth, events, and logs |
| **ServiceMonitors** | `servicemonitors/` | Prometheus scrape configs for Ray cluster, etcd, and Keycloak + NetworkPolicy |
| **Postgres exporter** | `exporters/` | Helm values for `prometheus-postgres-exporter` against core-postgres |
| **Full stack values** | `kube-prometheus-stack-values.yaml`, `loki-values.yaml`, `alloy-values.yaml` | Helm values to deploy Prometheus, Grafana, Loki, and Alloy from scratch |

## Prerequisites

- Kamiwaza deployed (any method: Helmfile, ArgoCD, manual Helm).
- `kubectl` configured for your cluster.
- `helm` 3 installed (for the Helm chart components).

## Quick start (full stack)

If you have no existing monitoring and want everything:

```bash
helm repo add prometheus-community https://prometheus-community.github.io/helm-charts
helm repo add grafana https://grafana.github.io/helm-charts
helm repo update

# Prometheus + Grafana + Alertmanager
helm upgrade --install kube-prometheus-stack \
  prometheus-community/kube-prometheus-stack \
  -n monitoring --create-namespace \
  -f monitoring/grafana-prometheus/kube-prometheus-stack-values.yaml

# Loki (log aggregation)
helm upgrade --install loki grafana/loki \
  -n monitoring \
  -f monitoring/grafana-prometheus/loki-values.yaml

# Alloy (log collector DaemonSet)
helm upgrade --install alloy grafana/alloy \
  -n monitoring \
  -f monitoring/grafana-prometheus/alloy-values.yaml

# Kamiwaza ServiceMonitors
kubectl apply -k monitoring/grafana-prometheus/servicemonitors/

# Kamiwaza dashboards (auto-loaded by Grafana sidecar)
kubectl apply -k monitoring/grafana-prometheus/dashboards/

# Postgres exporter (optional)
helm upgrade --install postgres-exporter \
  prometheus-community/prometheus-postgres-exporter \
  --version 6.10.0 -n kamiwaza \
  -f monitoring/grafana-prometheus/exporters/postgres-exporter-values.yaml
```

## Already have Prometheus + Grafana?

Apply only what you need:

```bash
# ServiceMonitors (requires Prometheus Operator CRDs)
kubectl apply -k monitoring/grafana-prometheus/servicemonitors/

# Dashboards via Grafana sidecar
kubectl apply -k monitoring/grafana-prometheus/dashboards/

# Or import dashboards manually: Grafana > Dashboards > Import > upload each .json

# Postgres exporter
helm upgrade --install postgres-exporter \
  prometheus-community/prometheus-postgres-exporter \
  --version 6.10.0 -n kamiwaza \
  -f monitoring/grafana-prometheus/exporters/postgres-exporter-values.yaml
```

## Verification

```bash
# ServiceMonitors registered
kubectl get servicemonitors -n monitoring

# Dashboards loaded
kubectl get configmap -n monitoring -l grafana_dashboard=1

# Alloy running on every node
kubectl get pods -n monitoring -l app.kubernetes.io/name=alloy -o wide

# Access Grafana
kubectl port-forward svc/kube-prometheus-stack-grafana 3000:80 -n monitoring
# Default password:
kubectl get secret kube-prometheus-stack-grafana -n monitoring \
  -o jsonpath='{.data.admin-password}' | base64 -d; echo
```

## Dashboards

| Dashboard | Focus |
| --- | --- |
| **kam-01 Platform Overview** | Component health, golden signals, resource utilisation, PVC usage, K8s warning events |
| **kam-02 Inference & Ray** | Ray cluster nodes, inference throughput/latency, GPU utilisation |
| **kam-03 Core API & Scheduler** | Ray Serve request rate/errors/latency, scheduler CPU/memory/restarts |
| **kam-04 Data Infrastructure** | etcd leader/DB size/WAL fsync, PostgreSQL connections/cache hit/transactions |
| **kam-05 Extensions & Kaizen** | Extension sync status, operator health, sandbox pods |
| **kam-06 Auth & Identity** | Keycloak status, active sessions, logins, auth errors, certificate expiry |
| **kam-07 Kubernetes Events** | Pod restarts, OOMKilled, CrashLoopBackOff, Pending, ImagePullBackOff |
| **kam-08 Log Explorer** | Log volume by namespace, error rate by service, pre-built LogQL queries |

See [dashboards/README.md](dashboards/README.md) for import options and datasource requirements.

## Files

| File | Purpose |
| --- | --- |
| `kube-prometheus-stack-values.yaml` | Helm values for Prometheus + Grafana + Alertmanager |
| `loki-values.yaml` | Helm values for Loki (single-binary, filesystem storage) |
| `alloy-values.yaml` | Helm values for Alloy DaemonSet log collector |
| `dashboards/*.json` | 8 Grafana dashboard JSON files (importable or auto-loaded via sidecar) |
| `dashboards/kustomization.yaml` | Wraps JSON files as ConfigMaps for sidecar auto-loading |
| `servicemonitors/*.yaml` | Prometheus ServiceMonitor CRDs for Ray, etcd, Keycloak |
| `servicemonitors/keycloak-allow-prometheus-netpol.yaml` | NetworkPolicy for monitoring namespace to scrape Keycloak |
| `exporters/postgres-exporter-values.yaml` | Helm values for postgres-exporter against core-postgres |
