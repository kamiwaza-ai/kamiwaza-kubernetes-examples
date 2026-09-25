# Monitoring scenarios index

Monitoring scenarios: each folder documents a complete observability stack for Kamiwaza, with prerequisites, step ordering, and verification commands.

## Stack matrix

| Stack                                            | Metrics                                                                                                                  | Logs         | Dashboards                       | Prerequisites                               |
| ------------------------------------------------ | ------------------------------------------------------------------------------------------------------------------------ | ------------ | -------------------------------- | ------------------------------------------- |
| [grafana-prometheus](grafana-prometheus)         | Prometheus scrape of platform workloads, operator conditions through kube-state-metrics, and operator controller metrics | Loki + Alloy | 8 Kamiwaza Grafana dashboards    | Helm, kubectl, an operator-managed platform |
| [platform-observability](platform-observability) | Platform OTLP export to an approved sink                                                                                 | OTLP         | Backend-neutral dashboard intent | An operator-managed platform                |
