# Kamiwaza Grafana dashboards

Eight Grafana dashboards for a platform reconciled by the Kamiwaza platform operator.

Each file is a Grafana **v2 dashboard resource** (`apiVersion: dashboard.grafana.app/v2`), the schema behind Grafana 13's dynamic dashboards. They need **Grafana 13 or later**; kube-prometheus-stack 91.5.2 ships Grafana 13.2.2. An older Grafana rejects them.

Every dashboard has a **Platform namespace** selector. It lists the namespaces that hold a `KamiwazaPlatform`, so the same dashboards serve a platform in any namespace. The **Kamiwaza dashboards** menu in the header moves between them and keeps the selected namespace and time range.

## Dashboard inventory

| File                              | Title                                      | Tabs                                                               | Focus                                                                                                                            |
| --------------------------------- | ------------------------------------------ | ------------------------------------------------------------------ | -------------------------------------------------------------------------------------------------------------------------------- |
| `kam-01-platform-overview.json`   | Kamiwaza · Platform Overview               | Health, Stability, Resources, Events                               | Platform readiness, each capability's state over time and its reason, pod stability, resource usage by workload, volumes, events |
| `kam-02-inference-ray.json`       | Kamiwaza · Inference & Delegated Compute   | Model serving, Delegated compute                                   | ModelDeployment readiness over time and replicas, serving resources by model, delegated-compute head and workers, GPUs, errors   |
| `kam-03-core-api-scheduler.json`  | Kamiwaza · Application API & Web Interface | Overview, Resources, Logs                                          | Application capabilities and replicas, container CPU, memory, throttling, restarts, error rate compared with the day before      |
| `kam-04-data-infrastructure.json` | Kamiwaza · Data Infrastructure             | Overview, Coordination store, Durable data, Metadata catalog, Logs | Cache hit, connection, and heap gauges, etcd raft and fsync, PostgreSQL activity compared with the day before, catalog JVM       |
| `kam-05-extensions-kaizen.json`   | Kamiwaza · Extensions & Platform Operator  | Extensions, Platform operator, Logs                                | Extension readiness over time and conditions, sandbox pools, operator leader, reconcile rate and duration, condition transitions |
| `kam-06-auth-identity.json`       | Kamiwaza · Auth & Identity                 | Overview, Authorization, Authentication                            | Identity capability, certificate expiry gauges, authorization decision rate, latency, and errors, authentication failures        |
| `kam-07-kubernetes-events.json`   | Kamiwaza · Kubernetes Events & Stability   | Stability, Events                                                  | Restarts, OOMKilled, CrashLoopBackOff, Pending, image pulls, throttling, node pressure over time, warning and operator events    |
| `kam-08-log-explorer.json`        | Kamiwaza · Log Explorer                    | Explore, Diagnostics                                               | Log volume and error lines by workload, a filtered stream, pre-built diagnostic queries                                          |

## How they are built

The dashboards use Grafana 13 features where each one answers a real question:

- **Tabs** split each dashboard by concern, so no dashboard is a long scroll.
- **Auto grid** lays out the summary strips and chart groups, so they reflow to the screen width.
- **Show/hide rules** hide a panel that has no data where the absence is expected: GPU charts on CPU-only clusters, volume usage where the provisioner reports no statistics, operator reconcile charts before operator metrics are on, authorization errors while there are none, and empty diagnostic queries.
- **State timelines** show how each capability, served model, extension, and node condition changed over the time range, not only its current value.
- **Time comparison** overlays the day before on the application error rate and on database transactions.
- The **revamped gauge**, with sparklines, shows the database cache hit ratio, connections in use, and catalog heap. Table **gauge cells** show certificate expiry and volume usage.
- **Legend limits** keep charts with many series readable; **Show all** reveals the rest.

## Install through the kube-prometheus-stack sidecar

If Grafana was installed with the dashboard sidecar enabled (see `../kube-prometheus-stack-values.yaml`), apply the ConfigMaps:

```bash
kubectl apply -k monitoring/grafana-prometheus/dashboards/
```

The sidecar loads ConfigMaps labelled `grafana_dashboard=1` into the **Kamiwaza** folder. Grafana provisions v2 resources from files unchanged.

## Install through the Grafana API

For a Grafana 13 instance without the sidecar, create each dashboard through the v2 API with an account that can write dashboards:

```bash
for dashboard in monitoring/grafana-prometheus/dashboards/*.json; do
  curl -sS -u "$GRAFANA_USER:$GRAFANA_PASSWORD" -H 'Content-Type: application/json' \
    --data-binary @"$dashboard" \
    "$GRAFANA_URL/apis/dashboard.grafana.app/v2/namespaces/default/dashboards"
done
```

`default` is the namespace of Grafana's default organization. Use `PUT .../dashboards/<name>` to replace a dashboard that already exists.

## Datasource requirements

| Datasource | Required for                  | Default URL                                                                 |
| ---------- | ----------------------------- | --------------------------------------------------------------------------- |
| Prometheus | kam-01 through kam-07         | `http://kube-prometheus-stack-prometheus.monitoring.svc.cluster.local:9090` |
| Loki       | Log panels on every dashboard | `http://loki.monitoring.svc.cluster.local:3100`                             |

The **Metrics** and **Logs** selectors pick the datasource by type (`prometheus`, `loki`), so no name mapping is needed.

## Where the data comes from

| Series                                                                                                  | Source                                                   | Set up by                                                                          |
| ------------------------------------------------------------------------------------------------------- | -------------------------------------------------------- | ---------------------------------------------------------------------------------- |
| `kamiwaza_platform_*`, `kamiwaza_model_deployment_*`, `kamiwaza_extension_*`, `kamiwaza_sandbox_pool_*` | Conditions and status on the operator's custom resources | kube-state-metrics custom resource state in `../kube-prometheus-stack-values.yaml` |
| `kamiwaza_operator_*`, `leader_election_master_status`                                                  | The operator manager                                     | `../operator-metrics/`                                                             |
| `etcd_*`, `grpc_server_*`, `jvm_*`, `up` for delegated compute                                          | Platform workloads                                       | `../servicemonitors/`                                                              |
| `pg_*`                                                                                                  | PostgreSQL exporter                                      | `../exporters/`                                                                    |
| `certmanager_*`                                                                                         | cert-manager                                             | `../servicemonitors/cert-manager-servicemonitor.yaml`                              |
| Container, pod, node, and PVC series                                                                    | kubelet and kube-state-metrics                           | kube-prometheus-stack                                                              |
| `app`, `container`, `extension`, and `model` log labels                                                 | Alloy                                                    | `../alloy-values.yaml`                                                             |

## Panels that are hidden or empty by design

- **GPU** charts on kam-02 need the NVIDIA DCGM exporter. They are hidden on CPU-only clusters; the **GPUs** tile reads 0.
- **Volume usage** on kam-01 needs kubelet volume statistics. Host-path provisioners, including kind's local-path provisioner, report none, so the panel is hidden.
- **Reconciliation** charts on kam-05 need `../operator-metrics/` and are hidden until it is applied. The leader, blocked-platform, and CA tiles read `0` or are empty until then.
- Restart, error, and event panels are empty while nothing has restarted, failed, or logged an error.

## What these dashboards do not show

- **Request rate and latency for the application API and served models.** The application API does not serve Prometheus metrics, and a serving runtime publishes them, if at all, on its inference port. Scraping that port would admit the scraper to the model API itself, so this stack does not.
- **Identity provider sessions and logins.** The identity provider image ships without its metrics endpoint. kam-06 reports its replicas and its event log instead.
- **Delegated-compute scheduler internals.** The head and workers serve only process metrics on their metrics port, so kam-02 reports them through Kubernetes and container metrics.
