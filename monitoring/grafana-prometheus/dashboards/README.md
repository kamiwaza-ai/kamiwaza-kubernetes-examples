# Kamiwaza Grafana dashboards

Eight Grafana dashboards for a platform reconciled by the Kamiwaza platform operator. Each `.json` file can be imported into any Grafana instance.

Every dashboard has a **Platform namespace** selector. It lists the namespaces that hold a `KamiwazaPlatform`, so the same dashboards serve a platform in any namespace.

## Dashboard inventory

| File                              | Title                           | Datasources      | Focus                                                                                                                                                    |
| --------------------------------- | ------------------------------- | ---------------- | -------------------------------------------------------------------------------------------------------------------------------------------------------- |
| `kam-01-platform-overview.json`   | Platform Health Overview        | Prometheus, Loki | Platform Ready condition, every capability's state and reason, platform conditions, pod stability, resource usage by workload, PVC usage, warning events |
| `kam-02-inference-ray.json`       | Inference & Delegated Compute   | Prometheus, Loki | ModelDeployment readiness and replicas, serving resource usage by model, delegated-compute head and workers, GPU usage, serving and compute logs         |
| `kam-03-core-api-scheduler.json`  | Application API & Web Interface | Prometheus, Loki | Application capabilities, API, retrieval, protocol data plane, and web interface replicas, container resources and throttling, error log rate            |
| `kam-04-data-infrastructure.json` | Data Infrastructure             | Prometheus, Loki | Data capabilities, etcd leader/DB size/WAL fsync, PostgreSQL connections/cache hit/transactions/row activity, metadata catalog JVM heap and GC           |
| `kam-05-extensions-kaizen.json`   | Extensions & Platform Operator  | Prometheus, Loki | Extension conditions, sandbox pools, extension resource usage, operator replicas, leader, reconcile rate/duration, condition transitions, CA expiry      |
| `kam-06-auth-identity.json`       | Auth & Identity                 | Prometheus, Loki | Identity capability, identity provider and decision service replicas, authorization request rate/latency/errors, certificate expiry, auth failure logs   |
| `kam-07-kubernetes-events.json`   | Kubernetes Events & Stability   | Prometheus, Loki | Pod restarts, OOMKilled, CrashLoopBackOff, Pending, ImagePullBackOff, throttling, node pressure, warning and operator events                             |
| `kam-08-log-explorer.json`        | Unified Log Explorer            | Loki             | Log volume and error rate by workload, filtered log stream, pre-built LogQL queries                                                                      |

## Where the data comes from

| Series                                                                                                  | Source                                                   | Set up by                                                                          |
| ------------------------------------------------------------------------------------------------------- | -------------------------------------------------------- | ---------------------------------------------------------------------------------- |
| `kamiwaza_platform_*`, `kamiwaza_model_deployment_*`, `kamiwaza_extension_*`, `kamiwaza_sandbox_pool_*` | Conditions and status on the operator's custom resources | kube-state-metrics custom resource state in `../kube-prometheus-stack-values.yaml` |
| `kamiwaza_operator_*`, `leader_election_master_status`                                                  | The operator manager                                     | `../operator-metrics/`                                                             |
| `etcd_*`, `grpc_server_*`, `jvm_*`, `up` for delegated compute                                          | Platform workloads                                       | `../servicemonitors/`                                                              |
| `pg_*`                                                                                                  | PostgreSQL exporter                                      | `../exporters/`                                                                    |
| `certmanager_*`                                                                                         | cert-manager                                             | `../servicemonitors/cert-manager-servicemonitor.yaml`                              |
| Container, pod, and PVC series                                                                          | kubelet and kube-state-metrics                           | kube-prometheus-stack                                                              |
| `app`, `container`, `extension`, and `model` log labels                                                 | Alloy                                                    | `../alloy-values.yaml`                                                             |

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

| Datasource | Required for                  | Default URL                                                                 |
| ---------- | ----------------------------- | --------------------------------------------------------------------------- |
| Prometheus | kam-01 through kam-07         | `http://kube-prometheus-stack-prometheus.monitoring.svc.cluster.local:9090` |
| Loki       | Log panels on every dashboard | `http://loki.monitoring.svc.cluster.local:3100`                             |

Dashboards reference datasources by **type** (`prometheus`, `loki`), not by name. If you have exactly one of each type configured as default, import works without manual mapping.

## Panels that are empty by design

- **GPU** panels on kam-02 need the NVIDIA DCGM exporter. They are empty on CPU-only clusters.
- **PVC Usage** on kam-01 needs kubelet volume statistics. Host-path provisioners, including kind's local-path provisioner, do not report them.
- **Platform Operator** panels on kam-05 that read `kamiwaza_operator_*` or `leader_election_master_status` need `../operator-metrics/`.
- Restart, error, and event panels are empty while nothing has restarted, failed, or logged an error.

## What these dashboards do not show

- **Request rate and latency for the application API and served models.** The application API does not serve Prometheus metrics, and a serving runtime publishes them, if at all, on its inference port. Scraping that port would admit the scraper to the model API itself, so this stack does not.
- **Identity provider sessions and logins.** The identity provider image ships without its metrics endpoint. kam-06 reports its replicas and its event log instead.
- **Delegated-compute scheduler internals.** The head and workers serve only process metrics on their metrics port, so kam-02 reports them through Kubernetes and container metrics.
