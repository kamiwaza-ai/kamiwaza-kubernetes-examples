#!/usr/bin/env bash
# Connect one installed Tomo extension to the monitoring stack, or disconnect it.
#
# Tomo publishes its live operational metrics on two ports, and records which
# model served each call and each turn only in its own PostgreSQL database.
# This script wires both into the stack for kam-09:
#
#   1. A PodMonitor for the API (port 8000) and the two workers (port 9100),
#      and a NetworkPolicy admitting only the Prometheus pods to those ports.
#   2. A PostgreSQL role, `grafana_reader`, that can read only the content-free
#      columns kam-09 queries: no message text, no member identity, no prompt.
#      The role is read-only, holds at most 6 connections, and every statement
#      it runs is cancelled after 15 seconds, so a dashboard cannot load Tomo.
#   3. A Service with a stable name in front of Tomo's database, a
#      NetworkPolicy admitting only the Grafana pods to it, and a Grafana
#      datasource Secret that the datasource sidecar provisions.
#
# Every run rotates the role's password and rewrites the datasource, so it is
# safe to repeat. Run it again after reinstalling Tomo: a new install is a new
# extension name and a new database.
#
# Usage:
#   connect-tomo.sh [--extension NAME] [--namespace NS] [--monitoring-namespace NS]
#   connect-tomo.sh --remove [--extension NAME] ...
set -euo pipefail

NAMESPACE=kamiwaza
MONITORING_NAMESPACE=monitoring
EXTENSION=""
REMOVE=false
READER=grafana_reader

while [ $# -gt 0 ]; do
  case "$1" in
  --extension)
    EXTENSION="$2"
    shift 2
    ;;
  --namespace)
    NAMESPACE="$2"
    shift 2
    ;;
  --monitoring-namespace)
    MONITORING_NAMESPACE="$2"
    shift 2
    ;;
  --remove)
    REMOVE=true
    shift
    ;;
  -h | --help)
    sed -n '2,25p' "$0"
    exit 0
    ;;
  *)
    echo "unknown argument: $1" >&2
    exit 2
    ;;
  esac
done

die() {
  echo "error: $*" >&2
  exit 1
}

# The Extension carries the product name as a label; its object name, which
# every pod label uses, is unique to the install.
if [ -z "$EXTENSION" ]; then
  mapfile -t found < <(kubectl -n "$NAMESPACE" get extensions.extensions.kamiwaza.ai \
    -l extensions.kamiwaza.ai/name=kaizen -o jsonpath='{range .items[*]}{.metadata.name}{"\n"}{end}')
  [ "${#found[@]}" -eq 1 ] && [ -n "${found[0]}" ] ||
    die "expected one Tomo extension in namespace $NAMESPACE, found ${#found[@]}; pass --extension"
  EXTENSION="${found[0]}"
fi
echo "Tomo extension: $NAMESPACE/$EXTENSION"

DB_POD=$(kubectl -n "$NAMESPACE" get pods \
  -l "kamiwaza.ai/extension=$EXTENSION,kamiwaza.ai/component=postgres" \
  --field-selector=status.phase=Running -o jsonpath='{.items[0].metadata.name}')
[ -n "$DB_POD" ] || die "no running database pod for $EXTENSION"

psql_superuser() {
  # SQL arrives on stdin so the password never appears in a process argument.
  kubectl -n "$NAMESPACE" exec -i "$DB_POD" -- sh -c \
    'exec psql -X -q -v ON_ERROR_STOP=1 -U "$POSTGRES_USER" -d "$POSTGRES_DB"'
}

DB_NAME=$(kubectl -n "$NAMESPACE" exec "$DB_POD" -- printenv POSTGRES_DB)

if [ "$REMOVE" = true ]; then
  kubectl -n "$MONITORING_NAMESPACE" delete secret tomo-datasource --ignore-not-found
  kubectl -n "$MONITORING_NAMESPACE" delete podmonitor tomo --ignore-not-found
  kubectl -n "$NAMESPACE" delete service tomo-reporting-db --ignore-not-found
  kubectl -n "$NAMESPACE" delete networkpolicy allow-prometheus-tomo allow-grafana-tomo-reporting-db --ignore-not-found
  psql_superuser <<SQL
SELECT format('REVOKE ALL ON ALL TABLES IN SCHEMA public FROM %I', '$READER')
 WHERE EXISTS (SELECT 1 FROM pg_roles WHERE rolname = '$READER') \gexec
SELECT format('REVOKE ALL ON SCHEMA public FROM %I', '$READER')
 WHERE EXISTS (SELECT 1 FROM pg_roles WHERE rolname = '$READER') \gexec
SELECT format('REVOKE ALL ON DATABASE %I FROM %I', '$DB_NAME', '$READER')
 WHERE EXISTS (SELECT 1 FROM pg_roles WHERE rolname = '$READER') \gexec
DROP ROLE IF EXISTS $READER;
SQL
  echo "Disconnected $EXTENSION from monitoring."
  exit 0
fi

# Scrape first: it needs nothing from the database, so it works even while
# Tomo is still starting.
kubectl apply -f - <<YAML
# Admit the Prometheus pods, and nothing else, to Tomo's metrics ports. Port
# 8000 also serves Tomo's member API, which still authenticates every request.
apiVersion: networking.k8s.io/v1
kind: NetworkPolicy
metadata:
  name: allow-prometheus-tomo
  namespace: $NAMESPACE
  labels:
    app.kubernetes.io/part-of: kamiwaza
    app.kubernetes.io/component: monitoring
spec:
  podSelector:
    matchLabels:
      kamiwaza.ai/extension: $EXTENSION
    matchExpressions:
      - key: kamiwaza.ai/component
        operator: In
        values: [api-backend, background-worker, document-worker]
  policyTypes: [Ingress]
  ingress:
    - from:
        - namespaceSelector:
            matchLabels:
              kubernetes.io/metadata.name: $MONITORING_NAMESPACE
          podSelector:
            matchLabels:
              app.kubernetes.io/name: prometheus
      ports:
        - port: 8000
          protocol: TCP
        - port: 9100
          protocol: TCP
---
apiVersion: monitoring.coreos.com/v1
kind: PodMonitor
metadata:
  name: tomo
  namespace: $MONITORING_NAMESPACE
  labels:
    app.kubernetes.io/part-of: kamiwaza
spec:
  namespaceSelector:
    matchNames: [$NAMESPACE]
  selector:
    matchLabels:
      kamiwaza.ai/extension: $EXTENSION
    matchExpressions:
      - key: kamiwaza.ai/component
        operator: In
        values: [api-backend, background-worker, document-worker]
  podMetricsEndpoints:
    - port: http
      path: /metrics
      interval: 30s
      scrapeTimeout: 10s
      relabelings:
        - sourceLabels: [__meta_kubernetes_pod_label_kamiwaza_ai_component]
          targetLabel: component
        - sourceLabels: [__meta_kubernetes_pod_label_kamiwaza_ai_extension]
          targetLabel: extension
YAML
echo "Prometheus scrapes $EXTENSION."

ready=$(printf 'SELECT count(*) FROM pg_tables WHERE schemaname = %s AND tablename IN (%s);\n' \
  "'public'" "'llm_audit_event','conversation_input','capability_invocation_receipt','chat_answer_feedback'" |
  kubectl -n "$NAMESPACE" exec -i "$DB_POD" -- sh -c 'exec psql -X -At -U "$POSTGRES_USER" -d "$POSTGRES_DB"')
[ "$ready" = 4 ] || die "Tomo has not created its tables yet; run again once its API is ready"

PASSWORD=$(head -c 32 /dev/urandom | base64 | tr -dc 'A-Za-z0-9' | head -c 40)

psql_superuser <<SQL
\set pw '$PASSWORD'
SELECT 'CREATE ROLE $READER LOGIN' WHERE NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname = '$READER') \gexec
ALTER ROLE $READER WITH LOGIN NOSUPERUSER NOCREATEDB NOCREATEROLE NOINHERIT NOREPLICATION NOBYPASSRLS
  CONNECTION LIMIT 6 PASSWORD :'pw';
ALTER ROLE $READER SET default_transaction_read_only = on;
ALTER ROLE $READER SET statement_timeout = '15s';
ALTER ROLE $READER SET idle_in_transaction_session_timeout = '30s';
GRANT CONNECT ON DATABASE "$DB_NAME" TO $READER;
GRANT USAGE ON SCHEMA public TO $READER;
-- Start from nothing, then grant exactly the columns kam-09 reads.
REVOKE ALL ON ALL TABLES IN SCHEMA public FROM $READER;
GRANT SELECT (created_at, purpose, route, model_id, outcome, error_class, latency_ms,
              prompt_token_count, response_token_count,
              prompt_cache_read_tokens, prompt_cache_write_tokens)
  ON llm_audit_event TO $READER;
GRANT SELECT (kind, status, execution_mode, reasoning_effort, agent_name,
              model_catalog_id, model_deployment_id,
              accepted_at, started_at, completed_at)
  ON conversation_input TO $READER;
GRANT SELECT (tool_name, capability, status, created_at, finished_at)
  ON capability_invocation_receipt TO $READER;
GRANT SELECT (vote, answer_path, created_at)
  ON chat_answer_feedback TO $READER;
SQL
echo "Database role $READER granted read access to kam-09's columns."

kubectl apply -f - <<YAML
# Admit the Grafana pods, and nothing else, to Tomo's database.
apiVersion: networking.k8s.io/v1
kind: NetworkPolicy
metadata:
  name: allow-grafana-tomo-reporting-db
  namespace: $NAMESPACE
  labels:
    app.kubernetes.io/part-of: kamiwaza
    app.kubernetes.io/component: monitoring
spec:
  podSelector:
    matchLabels:
      kamiwaza.ai/extension: $EXTENSION
      kamiwaza.ai/component: postgres
  policyTypes: [Ingress]
  ingress:
    - from:
        - namespaceSelector:
            matchLabels:
              kubernetes.io/metadata.name: $MONITORING_NAMESPACE
          podSelector:
            matchLabels:
              app.kubernetes.io/name: grafana
      ports:
        - port: 5432
          protocol: TCP
---
# Tomo's own database Service carries a revision hash that changes on upgrade.
# This one selects the same pod by install and component, so it keeps its name.
apiVersion: v1
kind: Service
metadata:
  name: tomo-reporting-db
  namespace: $NAMESPACE
  labels:
    app.kubernetes.io/part-of: kamiwaza
    app.kubernetes.io/component: monitoring
spec:
  selector:
    kamiwaza.ai/extension: $EXTENSION
    kamiwaza.ai/component: postgres
  ports:
    - name: postgres
      port: 5432
      targetPort: 5432
      protocol: TCP
---
apiVersion: v1
kind: Secret
metadata:
  name: tomo-datasource
  namespace: $MONITORING_NAMESPACE
  labels:
    grafana_datasource: "1"
    app.kubernetes.io/part-of: kamiwaza
type: Opaque
stringData:
  tomo-datasource.yaml: |
    apiVersion: 1
    datasources:
      - name: Tomo database
        uid: tomo-db
        type: grafana-postgresql-datasource
        access: proxy
        url: tomo-reporting-db.$NAMESPACE.svc.cluster.local:5432
        user: $READER
        editable: false
        jsonData:
          database: $DB_NAME
          sslmode: disable
          postgresVersion: 1800
          maxOpenConns: 4
          maxIdleConns: 2
          connMaxLifetime: 14400
        secureJsonData:
          password: $PASSWORD
YAML
echo "Connected $EXTENSION. Grafana provisions the \"Tomo database\" datasource within a minute."
