# Kamiwaza Grafana dashboards

Eight pre-built Grafana dashboards covering the full Kamiwaza platform. Each `.json` file can be imported into any Grafana instance — no specific deployment method required.

## Dashboard inventory

| File | Title | Datasources | Focus |
| --- | --- | --- | --- |
| `kam-01-platform-overview.json` | Platform Health Overview | Prometheus, Loki | Component health, golden signals, resource utilisation, PVC usage, K8s warning events |
| `kam-02-inference-ray.json` | Inference & Ray Cluster | Prometheus, Loki | Ray node health, inference throughput/latency, GPU utilisation, Ray logs |
| `kam-03-core-api-scheduler.json` | Core API & Scheduler | Prometheus, Loki | Ray Serve request rate/errors/latency, scheduler CPU/memory/restarts, error log rate |
| `kam-04-data-infrastructure.json` | Data Infrastructure | Prometheus, Loki | etcd leader/DB size/WAL fsync, PostgreSQL connections/cache hit/transactions/row activity |
| `kam-05-extensions-kaizen.json` | Extensions & Kaizen | Prometheus, Loki | Extension sync status, operator health, sandbox pods, namespace resource usage |
| `kam-06-auth-identity.json` | Auth & Identity | Prometheus | Keycloak health, active sessions, login rate, auth errors, certificate expiry |
| `kam-07-kubernetes-events.json` | Kubernetes Events & Stability | Prometheus, Loki | Pod restarts, OOMKilled, CrashLoopBackOff, Pending, ImagePullBackOff |
| `kam-08-log-explorer.json` | Unified Log Explorer | Loki | Log volume by namespace, error rate by service, filtered log stream, pre-built LogQL queries |

## Option A: Manual import (any Grafana)

1. Open Grafana and navigate to **Dashboards > Import**.
2. Click **Upload JSON file** and select any `.json` file from this directory.
3. Select your **Prometheus** datasource when prompted.
4. Click **Import**.

Repeat for each dashboard. Dashboards that include log panels also require a **Loki** datasource.

## Option B: ConfigMap sidecar (kube-prometheus-stack)

If Grafana was installed via `kube-prometheus-stack` with the dashboard sidecar enabled (see `../kube-prometheus-stack-values.yaml`), apply the ConfigMaps:

```bash
kubectl apply -k monitoring/grafana-prometheus/dashboards/
```

The sidecar auto-loads ConfigMaps labelled `grafana_dashboard=1` and places them in the **Kamiwaza** folder.

## Datasource requirements

| Datasource | Required for | Default URL |
| --- | --- | --- |
| Prometheus | All dashboards (metrics panels) | `http://kube-prometheus-stack-prometheus.monitoring.svc.cluster.local:9090` |
| Loki | kam-01, kam-02, kam-03, kam-04, kam-05, kam-07, kam-08 (log panels) | `http://loki.monitoring.svc.cluster.local:3100` |

Dashboards reference datasources by **type** (`prometheus`, `loki`), not by name. If you have exactly one of each type configured as default, import works without manual mapping.

## Notes

- **kam-05**, **kam-07**, and **kam-08** include panels that query ArgoCD metrics (`argocd_app_info`, `argocd_app_sync_total`). These panels display data when Kamiwaza is deployed via ArgoCD and are simply empty otherwise — no errors or broken panels.
- **kam-06** includes a panel for Keycloak active sessions that uses the Grafana Infinity datasource against the Keycloak Admin REST API. This panel requires additional Keycloak client configuration and is empty by default. All other panels on kam-06 use standard Prometheus metrics.
