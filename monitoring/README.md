# Monitoring scenarios index

Monitoring scenarios: each folder documents a complete observability stack for Kamiwaza, with prerequisites, step ordering, and verification commands.

## Stack matrix

| Stack | Metrics | Logs | Dashboards | Prerequisites |
| --- | --- | --- | --- | --- |
| [grafana-prometheus](grafana-prometheus) | Prometheus + ServiceMonitors | Loki + Alloy | 8 Kamiwaza Grafana dashboards | Helm, kubectl |
