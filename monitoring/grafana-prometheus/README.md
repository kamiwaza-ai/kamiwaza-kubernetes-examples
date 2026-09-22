# Grafana + Prometheus monitoring for Kamiwaza

**Scenario:** deploy a Prometheus + Grafana + Loki + Alloy monitoring stack for
an operator-managed platform in namespace `kamiwaza`, with scrape
configuration, exporters, and 8 pre-built dashboards. Each component is
independently usable.

**Tags:** #monitoring #prometheus #grafana #loki #dashboards

## What you get

| Component | Path | Purpose |
| --- | --- | --- |
| **Dashboards** | `dashboards/` | 8 Grafana dashboards (kam-01 through kam-08) covering platform health, inference, API, data infrastructure, extensions, auth, events, and logs |
| **Scrape configuration** | `servicemonitors/` | Prometheus scrape configs for delegated compute, etcd, and Keycloak + NetworkPolicy |
| **Postgres exporter** | `exporters/` | Helm values for `prometheus-postgres-exporter` against core-postgres |
| **Full stack values** | `kube-prometheus-stack-values.yaml`, `loki-values.yaml`, `alloy-values.yaml` | Helm values to deploy Prometheus, Grafana, Loki, and Alloy from scratch |

## Prerequisites

- A platform reconciled by the platform operator, or equivalent resource names
  and labels.
- `kubectl` configured for your cluster.
- A default `ReadWriteOnce` StorageClass with at least 10 GiB for Loki. If the
  cluster has no default, add
  `--set singleBinary.persistence.storageClass=<storage-class>` to the Loki
  install command.
- `helm` 3 installed (for the Helm chart components).

The provided scrape configuration and dashboard queries target the resource
names and labels the operator renders in `kamiwaza`. For a platform in another
namespace, change each `namespaceSelector` and the dashboard namespace
variables before applying them.

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
  --version 91.4.1 \
  -f monitoring/grafana-prometheus/kube-prometheus-stack-values.yaml

# Loki (log aggregation)
helm upgrade --install loki grafana/loki \
  -n monitoring \
  --version 7.3.0 \
  -f monitoring/grafana-prometheus/loki-values.yaml

# Alloy (log collector DaemonSet)
helm upgrade --install alloy grafana/alloy \
  -n monitoring \
  --version 1.12.1 \
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
```

The chart stores the generated Grafana admin password in
`Secret/monitoring/kube-prometheus-stack-grafana`. Read it only into a protected
local credential flow; do not print it into terminal logs or automation output.

## Dashboards

| Dashboard | Focus |
| --- | --- |
| **kam-01 Platform Overview** | Component health, golden signals, resource utilisation, PVC usage, K8s warning events |
| **kam-02 Inference & Compute** | Delegated-compute nodes, inference throughput/latency, GPU utilisation |
| **kam-03 Core API & Scheduler** | Core API request rate/errors/latency, scheduler CPU/memory/restarts |
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
| `servicemonitors/*.yaml` | Prometheus PodMonitor for delegated compute and ServiceMonitors for etcd and Keycloak |
| `servicemonitors/keycloak-allow-prometheus-netpol.yaml` | NetworkPolicy for monitoring namespace to scrape Keycloak |
| `exporters/postgres-exporter-values.yaml` | Helm values for postgres-exporter against core-postgres |
