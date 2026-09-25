# Kamiwaza Grafana dashboards

Ten Grafana dashboards for a platform reconciled by the Kamiwaza platform operator: eight for the platform, and two for the Tomo extension.

Each file is a Grafana **v2 dashboard resource** (`apiVersion: dashboard.grafana.app/v2`), the schema behind Grafana 13's dynamic dashboards. They need **Grafana 13 or later**; kube-prometheus-stack 91.5.2 ships Grafana 13.2.2. An older Grafana rejects them.

## Dashboard inventory

Start at **kam-01**. Each dashboard answers one question, and its tiles link to the dashboard that answers the next one.

| File                              | Title                                      | Question it answers                                                                      |
| --------------------------------- | ------------------------------------------ | ---------------------------------------------------------------------------------------- |
| `kam-01-platform-overview.json`   | Kamiwaza · Platform Overview               | Is the platform healthy, and where should I look if it is not?                           |
| `kam-02-inference-ray.json`       | Kamiwaza · Inference & Delegated Compute   | Are served models and delegated compute healthy and within their limits?                 |
| `kam-03-core-api-scheduler.json`  | Kamiwaza · Application API & Web Interface | Are the application workloads up, erroring, or short of resources?                       |
| `kam-04-data-infrastructure.json` | Kamiwaza · Data Infrastructure             | Are the stores that hold platform state healthy and far from their limits?               |
| `kam-05-extensions-kaizen.json`   | Kamiwaza · Extensions & Platform Operator  | Are extensions healthy, and is the operator reconciling without errors?                  |
| `kam-06-auth-identity.json`       | Kamiwaza · Auth & Identity                 | Can users sign in, are authorization decisions fast and correct, are certificates valid? |
| `kam-07-kubernetes-events.json`   | Kamiwaza · Kubernetes Events & Stability   | Which pods in the platform namespace are failing or short of resources?                  |
| `kam-08-log-explorer.json`        | Kamiwaza · Log Explorer                    | What are the workloads saying?                                                           |
| `kam-09-tomo.json`                | Kamiwaza · Tomo operations                 | Is Tomo answering members, and how are its models and tools doing?                       |
| `kam-10-tomo-product.json`        | Kamiwaza · Tomo product insight            | How do members use Tomo, where do they struggle, and which features earn their place?    |

Every dashboard carries its question as its description and in a collapsed **About this dashboard** section.

## Design rules

These rules follow Grafana's [dashboard best practices](https://grafana.com/docs/grafana/latest/visualizations/dashboards/build-dashboards/best-practices/). Keep them when changing a dashboard.

1. **One question per dashboard, answered at the top.** The first row is status tiles. An operator who sees only that row knows whether to keep reading.
2. **General to specific.** Rows run status, then signals, then detail, and logs come last in a collapsed row. kam-01 is the entry point. Its service and attention tiles open the detail dashboard, keeping the namespace and time range.
3. **A method per kind of component.**
   - Services with request metrics use **RED**: rate, errors, and duration. That covers the authorization decision service and the operator's reconcile loop.
   - Resources use **USE**: utilisation, saturation, and errors. That covers container CPU and memory, the stores' capacity, and throttling.
   - The application API publishes no request metrics, so its error signal is its error log rate.
4. **Normalised axes.** CPU and memory are shown as a percentage of each container's limit, not as cores or bytes, so 100% means the same thing for every workload. Replica tiles show ready next to desired, never a percentage, so "1 of 2" is not read as "50% healthy".
5. **Colour means state.** Green is healthy, orange needs a look, red is wrong, and grey is disabled by plan. Counts that are not good or bad, such as models ready or warm sandboxes, are neutral. A rate that is normal at low values, such as authentication failures, stays neutral until a stated threshold. No colour is decorative, and every state timeline has a legend and labelled segments.
6. **Show what is in trouble, and only while it is.** kam-01 opens with warning and critical Prometheus alerts, and its **Needs attention** table lists only capabilities that are Progressing or Blocked, saying so when there are none. Error tiles count events inside a window (restarts and out-of-memory kills in the last hour) or states that hold now (crash loops, pending pods), so a problem that has passed does not keep a tile red. Failed Job pods are reported on kam-07, not in kam-01's health.
7. **Hide panels whose data cannot exist, never panels that are merely quiet.**
   - Hidden when their data cannot exist on this installation: GPU charts without the DCGM exporter, volume usage without kubelet volume statistics, and operator reconcile charts before operator metrics are on.
   - Always shown: error, restart, and diagnostic panels. An empty one means nothing went wrong, and that is information.
8. **Name series by workload, not by pod.** Legends read `workload · container`, from `app.kubernetes.io/name`, so a rollout does not rename a series and replicas of one workload share a line. Saturation rankings leave out one-shot Job pods, whose saturation is not actionable. Log panels drop Alloy's `service_name` and `stream` labels, which repeat the workload and level.
9. **No stacking, except for log-volume charts.** Stacked series hide individual values. Log volume is a total by design.
10. **One place per fact.** kam-01 holds every capability's state and history, and marks the operator's warning events on its time axis. A detail dashboard shows at most the one capability it is about, then the signals behind it. Each component has one name on every dashboard.
11. **Refresh every minute.** Prometheus scrapes every 30 seconds, so refreshing faster only adds load. kam-10 is the exception: it reads Tomo's database, its numbers move by the day, and it refreshes every 15 minutes over the last 30 days.

## Grafana features in use

- **Tabs** on the dashboards that cover two unrelated components (kam-05, kam-08). The single-subject dashboards stay on one page.
- **Auto grid** for status strips and chart pairs, so they reflow to the screen width.
- **Show/hide rules** for rule 7.
- **State timelines** for capability, model, extension, and node state over the time range.
- **Time comparison** against the day before, on the application error rate and database commits.
- The **revamped gauge**, with sparklines, for store saturation. Table **gauge cells** for certificate expiry and volume usage.
- **Data links** on kam-01 tiles, and **legend limits** on charts with many series.
- **Config from query results** on replica tiles: desired replicas set the threshold at which ready turns green.
- A **Loki annotation** that marks the operator's Warning events on every platform dashboard's time axis.

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

| Datasource | Required for                                              | Default URL                                                                                          |
| ---------- | --------------------------------------------------------- | ---------------------------------------------------------------------------------------------------- |
| Prometheus | kam-01 through kam-07, kam-09                             | `http://kube-prometheus-stack-prometheus.monitoring.svc.cluster.local:9090`                          |
| Loki       | Log panels on every dashboard                             | `http://loki.monitoring.svc.cluster.local:3100`                                                      |
| PostgreSQL | kam-10, and kam-09 model, turn, and connector-tool panels | One **Tomo · &lt;install&gt;** datasource per Tomo install, provisioned by `../tomo/connect-tomo.sh` |

The **Metrics** and **Logs** selectors pick the datasource by type (`prometheus`, `loki`), so no name mapping is needed. kam-09 and kam-10 pick the PostgreSQL datasource named for the selected Tomo install.

## Where the data comes from

| Series                                                                                                  | Source                                                                         | Set up by                                                                          |
| ------------------------------------------------------------------------------------------------------- | ------------------------------------------------------------------------------ | ---------------------------------------------------------------------------------- |
| `kamiwaza_platform_*`, `kamiwaza_model_deployment_*`, `kamiwaza_extension_*`, `kamiwaza_sandbox_pool_*` | Conditions and status on the operator's custom resources                       | kube-state-metrics custom resource state in `../kube-prometheus-stack-values.yaml` |
| `kamiwaza_operator_*`, `leader_election_master_status`                                                  | The operator manager                                                           | `../operator-metrics/`                                                             |
| `etcd_*`, `grpc_server_*`, `jvm_*`, `up` for delegated compute                                          | Platform workloads                                                             | `../servicemonitors/`                                                              |
| `pg_*`                                                                                                  | PostgreSQL exporter                                                            | `../exporters/`                                                                    |
| `certmanager_*`                                                                                         | cert-manager                                                                   | `../servicemonitors/cert-manager-servicemonitor.yaml`                              |
| Container, pod, node, limit, and PVC series                                                             | kubelet and kube-state-metrics                                                 | kube-prometheus-stack                                                              |
| `app`, `container`, `extension`, and `model` log labels                                                 | Alloy                                                                          | `../alloy-values.yaml`                                                             |
| `kaizen_*`, `tool_run_total`, `sandbox_*`, `worker_queue_depth`                                         | Tomo's API and workers                                                         | `../tomo/connect-tomo.sh`                                                          |
| Member usage, feature use, votes, model, turn, and connector-tool history                               | Tomo's database, through the content-free functions in `../tomo/reporting.sql` | `../tomo/connect-tomo.sh`                                                          |

## What these dashboards do not show

- **Request rate and latency for the application API and served models.** The application API does not serve Prometheus metrics, and a serving runtime publishes them, if at all, on its inference port. Scraping that port would admit the scraper to the model API itself, so this stack does not.
- **Identity provider sessions and logins.** The identity provider image ships without its metrics endpoint. kam-06 reports its replicas, its event log, and authentication failures instead.
- **Delegated-compute scheduler internals.** The head and workers serve only process metrics on their metrics port, so kam-02 reports them through Kubernetes and container metrics.
