# Grafana + Prometheus monitoring for Kamiwaza

**Scenario:** deploy a Prometheus + Grafana + Loki + Alloy monitoring stack for a platform reconciled by the Kamiwaza platform operator, with scrape configuration, exporters, and 10 pre-built dashboards. Each component is independently usable.

**Tags:** #monitoring #prometheus #grafana #loki #dashboards

## What you get

| Component                | Path                                                                         | Purpose                                                                                                                                                                                                                                                                      |
| ------------------------ | ---------------------------------------------------------------------------- | ---------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| **Dashboards**           | `dashboards/`                                                                | 10 Grafana dashboards: kam-01 through kam-08 cover platform capabilities, inference and compute, the application API, data infrastructure, extensions and the operator, auth, events, and logs; kam-09 covers the Tomo extension's operations, and kam-10 how members use it |
| **Tomo connection**      | `tomo/`                                                                      | Script that connects every Tomo install: its metrics scrape, and a read-only, content-free database datasource for kam-09 and kam-10                                                                                                                                         |
| **Scrape configuration** | `servicemonitors/`                                                           | ServiceMonitors and PodMonitors for etcd, delegated compute, the metadata catalog, the authorization decision service, and cert-manager, plus the NetworkPolicies that admit Prometheus to those metrics ports                                                               |
| **Operator metrics**     | `operator-metrics/`                                                          | Serving certificate and Helm values that turn on the operator's authenticated metrics endpoint, ServiceMonitor, and alert rules                                                                                                                                              |
| **Postgres exporter**    | `exporters/`                                                                 | Helm values for `prometheus-postgres-exporter` against `core-postgres`                                                                                                                                                                                                       |
| **Full stack values**    | `kube-prometheus-stack-values.yaml`, `loki-values.yaml`, `alloy-values.yaml` | Helm values to deploy Prometheus, Grafana, Loki, and Alloy from scratch                                                                                                                                                                                                      |

## How the stack reads the platform

The operator reports each outcome on its custom resources: every platform capability, served model, extension, and sandbox pool carries standard conditions with stable reasons. kube-state-metrics turns those into `kamiwaza_*` series through custom resource state, so the dashboards show what the operator decided rather than inferring it from pods.

Workload metrics come from the platform's own metrics ports. The operator installs a default-deny ingress floor for every platform pod, so `servicemonitors/scrape-networkpolicies.yaml` admits the Prometheus pods, and only them, to each metrics port. No API port is opened.

The operator's controller metrics come from the operator chart itself once `operator-metrics/` is applied. Every scrape is authenticated with the Prometheus ServiceAccount token and authorized for `GET /metrics`.

Monitoring stays external: the operator never installs, upgrades, or owns any part of this stack.

## Prerequisites

- A platform reconciled by the Kamiwaza platform operator in namespace `kamiwaza`, with cert-manager installed.
- `kubectl` configured for your cluster.
- `helm` 3 or later.
- A default `ReadWriteOnce` StorageClass with at least 10 GiB for Loki. If the cluster has no default, add `--set singleBinary.persistence.storageClass=<storage-class>` to the Loki install command.

The scrape configuration and dashboards target the resource names and labels the operator renders. For a platform in another namespace, change each `namespaceSelector`, the NetworkPolicy namespace, and the exporter namespace before applying them. The dashboards find the namespace themselves.

## Quick start (full stack)

If you have no existing monitoring and want everything:

```bash
helm repo add prometheus-community https://prometheus-community.github.io/helm-charts
helm repo add grafana https://grafana.github.io/helm-charts
helm repo update

# Prometheus + Grafana + Alertmanager, and the Prometheus Operator CRDs
helm upgrade --install kube-prometheus-stack \
  prometheus-community/kube-prometheus-stack \
  -n monitoring --create-namespace \
  --version 91.5.2 \
  -f monitoring/grafana-prometheus/kube-prometheus-stack-values.yaml \
  --wait

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

# Platform scrape configuration and its NetworkPolicies
kubectl apply -k monitoring/grafana-prometheus/servicemonitors/

# Kamiwaza dashboards (auto-loaded by Grafana sidecar)
kubectl apply -k monitoring/grafana-prometheus/dashboards/

# Postgres exporter
helm upgrade --install postgres-exporter \
  prometheus-community/prometheus-postgres-exporter \
  --version 8.2.0 -n kamiwaza \
  -f monitoring/grafana-prometheus/exporters/postgres-exporter-values.yaml
```

Then turn on the operator's metrics. Apply the serving certificate, wait for it, and add `operator-metrics/values.yaml` to the operator's existing Helm values:

```bash
kubectl apply -f monitoring/grafana-prometheus/operator-metrics/certificate.yaml
kubectl -n kamiwaza wait --for=condition=Ready \
  certificate/kamiwaza-platform-operator-metrics --timeout=2m

helm upgrade --install kamiwaza-platform-operator <operator chart> \
  --namespace kamiwaza \
  --values <your operator values> \
  --values monitoring/grafana-prometheus/operator-metrics/values.yaml
```

The operator chart creates its own ServiceMonitor and PrometheusRule in the operator namespace. It requires the Prometheus Operator CRDs, so install kube-prometheus-stack first.

If Tomo is installed, connect every install for kam-09 and kam-10, and run the script again whenever an install is added or removed. See [tomo/README.md](tomo/README.md) for what it grants:

```bash
monitoring/grafana-prometheus/tomo/connect-tomo.sh
```

## Already have Prometheus + Grafana?

Apply only what you need:

```bash
# Scrape configuration (requires Prometheus Operator CRDs)
kubectl apply -k monitoring/grafana-prometheus/servicemonitors/

# Dashboards via Grafana sidecar
kubectl apply -k monitoring/grafana-prometheus/dashboards/

# Or import dashboards manually: Grafana > Dashboards > Import > upload each .json
```

Three settings from `kube-prometheus-stack-values.yaml` must also exist in your installation, or the matching panels stay empty:

- the kube-state-metrics `customResourceState` block and its `rbac.extraRules`, which produce every `kamiwaza_*` condition series;
- the kube-state-metrics `metricLabelsAllowlist`, which groups resource usage by workload, model, extension, and extension component;
- ServiceMonitor and PodMonitor selection across namespaces (`*SelectorNilUsesHelmValues: false`).

`scrape-networkpolicies.yaml` admits pods labelled `app.kubernetes.io/name: prometheus` in namespace `monitoring`. Change both selectors to match your Prometheus. Set `monitoring.scraperServiceAccount` in `operator-metrics/values.yaml` to the ServiceAccount your Prometheus runs as.

## Upgrading from the Helm-deployed platform

The earlier version of this stack targeted the Helm-deployed platform. Remove its Keycloak and Ray ServiceMonitors and its Keycloak NetworkPolicy. The operator-managed identity provider serves no metrics endpoint, and no operator-managed Service carries the old Ray metrics port:

```bash
kubectl -n monitoring delete servicemonitor keycloak core-raycluster --ignore-not-found
kubectl -n kamiwaza delete networkpolicy keycloak-allow-prometheus-scrape --ignore-not-found
```

## Verification

```bash
# Scrape configuration registered
kubectl get servicemonitors,podmonitors -n monitoring
kubectl get servicemonitor -n kamiwaza kamiwaza-platform-operator

# Every Kamiwaza target is up, and operator conditions are exported
kubectl port-forward svc/kube-prometheus-stack-prometheus 9090:9090 -n monitoring &
curl -s 'http://127.0.0.1:9090/api/v1/query?query=kamiwaza_platform_condition'
# http://127.0.0.1:9090/targets lists each scrape and its last error

# Dashboards loaded
kubectl get configmap -n monitoring -l grafana_dashboard=1

# Alloy running on every node
kubectl get pods -n monitoring -l app.kubernetes.io/name=alloy -o wide

# Access Grafana
kubectl port-forward svc/kube-prometheus-stack-grafana 3000:80 -n monitoring
```

The chart stores the generated Grafana admin password in `Secret/monitoring/kube-prometheus-stack-grafana`. Read it only into a protected local credential flow; do not print it into terminal logs or automation output.

## Dashboards

The dashboards are Grafana v2 dashboard resources and need Grafana 13 or later. Start at **kam-01 Platform Overview**; its tiles link to the dashboard for each component.

| Dashboard                                  | Question it answers                                                               |
| ------------------------------------------ | --------------------------------------------------------------------------------- |
| **kam-01 Platform Overview**               | Is the platform healthy, and where should I look if it is not?                    |
| **kam-02 Inference & Delegated Compute**   | Are served models and delegated compute healthy and within their limits?          |
| **kam-03 Application API & Web Interface** | Are the application workloads up, erroring, or short of resources?                |
| **kam-04 Data Infrastructure**             | Are the stores that hold platform state healthy and far from their limits?        |
| **kam-05 Extensions & Platform Operator**  | Are extensions healthy, and is the operator reconciling without errors?           |
| **kam-06 Auth & Identity**                 | Can users sign in, are decisions fast and correct, are certificates valid?        |
| **kam-07 Kubernetes Events & Stability**   | Which pods are failing or short of resources?                                     |
| **kam-08 Log Explorer**                    | What are the workloads saying?                                                    |
| **kam-09 Tomo operations**                 | Is Tomo answering members, and how are its models and tools doing?                |
| **kam-10 Tomo product insight**            | How do members use Tomo, where do they struggle, which features earn their place? |

See [dashboards/README.md](dashboards/README.md) for the design rules they follow, how to install them without the sidecar, and which panels hide themselves when their data cannot exist.

## Files

| File                                          | Purpose                                                                                                                        |
| --------------------------------------------- | ------------------------------------------------------------------------------------------------------------------------------ |
| `kube-prometheus-stack-values.yaml`           | Helm values for Prometheus + Grafana + Alertmanager, and kube-state-metrics custom resource state for the operator's resources |
| `loki-values.yaml`                            | Helm values for Loki (single-binary, filesystem storage)                                                                       |
| `alloy-values.yaml`                           | Helm values for Alloy DaemonSet log collector, labelling logs by workload, extension, and served model                         |
| `dashboards/*.json`                           | 10 Grafana v2 dashboard resources, loaded by the sidecar or created through the Grafana API                                    |
| `dashboards/kustomization.yaml`               | Wraps JSON files as ConfigMaps for sidecar auto-loading                                                                        |
| `servicemonitors/*monitor.yaml`               | ServiceMonitors and PodMonitors for etcd, delegated compute, metadata catalog, authorization, and cert-manager                 |
| `servicemonitors/scrape-networkpolicies.yaml` | NetworkPolicies admitting Prometheus to the platform's metrics ports and the exporter to PostgreSQL                            |
| `operator-metrics/certificate.yaml`           | Self-signed serving certificate for the operator's metrics endpoint                                                            |
| `operator-metrics/values.yaml`                | Operator Helm values enabling authenticated metrics, ServiceMonitor, and PrometheusRule                                        |
| `exporters/postgres-exporter-values.yaml`     | Helm values for postgres-exporter against `core-postgres`                                                                      |
| `tomo/connect-tomo.sh`                        | Connects every Tomo install: scrape, NetworkPolicies, read-only database role, and a datasource per install                    |
