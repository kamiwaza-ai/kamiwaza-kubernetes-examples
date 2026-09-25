#!/usr/bin/env bash
# Connect every installed Tomo extension to the monitoring stack, or disconnect it.
#
# Tomo publishes its live operational metrics on two ports, and records which
# model served each call and each turn only in its own PostgreSQL database.
# For each install, this script wires both into the stack for kam-09:
#
#   1. A PodMonitor for the API (port 8000) and the two workers (port 9100),
#      and a NetworkPolicy admitting only the Prometheus pods to those ports.
#   2. A PostgreSQL role, `grafana_reader`, in that install's database. It can
#      read only the content-free columns kam-09 queries: no message text, no
#      member identity, no prompt. The role is read-only, holds at most 6
#      connections, and every statement it runs is cancelled after 15 seconds,
#      so a dashboard cannot load Tomo.
#   3. A Service with a stable name in front of that database, a NetworkPolicy
#      admitting only the Grafana pods to it, and a Grafana datasource named
#      "Tomo · <install>" that the datasource sidecar provisions.
#
# Every install is independent: one that is still starting, or has failed,
# gets its scrape and is reported, and the rest are connected regardless.
# Connection objects left behind by an install that no longer exists are
# deleted. Every run rotates each role's password, so it is safe to repeat;
# run it after installing, reinstalling, or removing Tomo.
#
# Usage:
#   connect-tomo.sh [--extension NAME] [--namespace NS] [--monitoring-namespace NS]
#   connect-tomo.sh --remove [--extension NAME] ...
set -euo pipefail

NAMESPACE=kamiwaza
MONITORING_NAMESPACE=monitoring
ONLY=""
REMOVE=false
READER=grafana_reader
# Marks every object this script creates, and names the install it serves.
MARK=app.kubernetes.io/name=tomo-connection
# Marks a datasource tombstone: removing a provisioning file does not remove
# the datasource from Grafana, so a disconnected install's file is replaced by
# one that deletes it, and the next run removes the tombstone.
RETIRED=app.kubernetes.io/name=tomo-connection-retired
INSTALL_LABEL=monitoring.kamiwaza.ai/extension

while [ $# -gt 0 ]; do
  case "$1" in
  --extension)
    ONLY="$2"
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
    sed -n '2,27p' "$0"
    exit 0
    ;;
  *)
    echo "unknown argument: $1" >&2
    exit 2
    ;;
  esac
done

installed() {
  # The Extension carries the product name as a label; its object name, which
  # every pod label uses, is unique to the install.
  kubectl -n "$NAMESPACE" get extensions.extensions.kamiwaza.ai -l extensions.kamiwaza.ai/name=kaizen \
    -o jsonpath='{range .items[*]}{.metadata.name}{"\n"}{end}'
}

connected() {
  {
    kubectl -n "$NAMESPACE" get networkpolicies,services -l "$MARK" \
      -o jsonpath="{range .items[*]}{.metadata.labels.monitoring\.kamiwaza\.ai/extension}{\"\n\"}{end}"
    kubectl -n "$MONITORING_NAMESPACE" get podmonitors,secrets -l "$MARK" \
      -o jsonpath="{range .items[*]}{.metadata.labels.monitoring\.kamiwaza\.ai/extension}{\"\n\"}{end}"
  } | sort -u
}

running_db_pod() {
  kubectl -n "$NAMESPACE" get pods -l "kamiwaza.ai/extension=$1,kamiwaza.ai/component=postgres" \
    --field-selector=status.phase=Running \
    -o jsonpath='{range .items[*]}{.metadata.name}{"\n"}{end}' | sed -n 1p
}

psql_superuser() {
  # SQL arrives on stdin so a password never appears in a process argument.
  kubectl -n "$NAMESPACE" exec -i "$1" -- sh -c \
    'exec psql -X -q -At -v ON_ERROR_STOP=1 -U "$POSTGRES_USER" -d "$POSTGRES_DB"'
}

disconnect() {
  local ext="$1" db
  kubectl -n "$MONITORING_NAMESPACE" delete podmonitors,secrets -l "$MARK,$INSTALL_LABEL=$ext" --ignore-not-found
  kubectl -n "$NAMESPACE" delete networkpolicies,services -l "$MARK,$INSTALL_LABEL=$ext" --ignore-not-found
  kubectl apply -f - >/dev/null <<YAML
apiVersion: v1
kind: Secret
metadata:
  name: tomo-datasource-$ext
  namespace: $MONITORING_NAMESPACE
  labels:
    grafana_datasource: "1"
    app.kubernetes.io/name: tomo-connection-retired
    app.kubernetes.io/part-of: kamiwaza
    app.kubernetes.io/component: monitoring
    $INSTALL_LABEL: $ext
type: Opaque
stringData:
  tomo-datasource-$ext.yaml: |
    apiVersion: 1
    deleteDatasources:
      - name: Tomo · $ext
        orgId: 1
YAML
  db=$(running_db_pod "$ext")
  if [ -n "$db" ]; then
    psql_superuser "$db" <<SQL
SELECT format('REVOKE ALL ON ALL TABLES IN SCHEMA public FROM %I', '$READER')
 WHERE EXISTS (SELECT 1 FROM pg_roles WHERE rolname = '$READER') \gexec
SELECT format('REVOKE ALL ON SCHEMA public FROM %I', '$READER')
 WHERE EXISTS (SELECT 1 FROM pg_roles WHERE rolname = '$READER') \gexec
SELECT format('REVOKE ALL ON DATABASE %I FROM %I', current_database(), '$READER')
 WHERE EXISTS (SELECT 1 FROM pg_roles WHERE rolname = '$READER') \gexec
DROP ROLE IF EXISTS $READER;
SQL
  fi
  echo "$ext: disconnected"
}

labels() {
  printf '    app.kubernetes.io/name: tomo-connection\n'
  printf '    app.kubernetes.io/part-of: kamiwaza\n'
  printf '    app.kubernetes.io/component: monitoring\n'
  printf '    %s: %s\n' "$INSTALL_LABEL" "$1"
}

connect_scrape() {
  local ext="$1"
  kubectl apply -f - >/dev/null <<YAML
# Admit the Prometheus pods, and nothing else, to Tomo's metrics ports. Port
# 8000 also serves Tomo's member API, which still authenticates every request.
apiVersion: networking.k8s.io/v1
kind: NetworkPolicy
metadata:
  name: $ext-allow-prometheus
  namespace: $NAMESPACE
  labels:
$(labels "$ext")
spec:
  podSelector:
    matchLabels:
      kamiwaza.ai/extension: $ext
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
# Every install's targets share job="tomo" and differ by the extension label.
apiVersion: monitoring.coreos.com/v1
kind: PodMonitor
metadata:
  name: tomo-$ext
  namespace: $MONITORING_NAMESPACE
  labels:
$(labels "$ext")
spec:
  namespaceSelector:
    matchNames: [$NAMESPACE]
  selector:
    matchLabels:
      kamiwaza.ai/extension: $ext
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
        - targetLabel: job
          replacement: tomo
        - sourceLabels: [__meta_kubernetes_pod_label_kamiwaza_ai_component]
          targetLabel: component
        - sourceLabels: [__meta_kubernetes_pod_label_kamiwaza_ai_extension]
          targetLabel: extension
YAML
}

grant_reader() {
  local db="$1" password="$2"
  psql_superuser "$db" <<SQL
\set pw '$password'
SELECT 'CREATE ROLE $READER LOGIN' WHERE NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname = '$READER') \gexec
ALTER ROLE $READER WITH LOGIN NOSUPERUSER NOCREATEDB NOCREATEROLE NOINHERIT NOREPLICATION NOBYPASSRLS
  CONNECTION LIMIT 6 PASSWORD :'pw';
ALTER ROLE $READER SET default_transaction_read_only = on;
ALTER ROLE $READER SET statement_timeout = '15s';
ALTER ROLE $READER SET idle_in_transaction_session_timeout = '30s';
SELECT format('GRANT CONNECT ON DATABASE %I TO %I', current_database(), '$READER') \gexec
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
}

connect_database() {
  local ext="$1" db tables password database
  db=$(running_db_pod "$ext")
  if [ -z "$db" ]; then
    echo "$ext: scraped; database not running yet, run again once it is"
    return 1
  fi
  tables=$(
    psql_superuser "$db" <<'SQL'
SELECT count(*) FROM pg_tables WHERE schemaname = 'public' AND tablename IN
  ('llm_audit_event', 'conversation_input', 'capability_invocation_receipt', 'chat_answer_feedback');
SQL
  ) || tables=unreachable
  if [ "$tables" != 4 ]; then
    echo "$ext: scraped; tables not created yet, run again once its API is ready"
    return 1
  fi
  password=$(head -c 32 /dev/urandom | base64 | tr -dc 'A-Za-z0-9' | head -c 40)
  # This function runs as the left side of ||, where errexit is off, so each
  # step that can fail says so and stops this install only.
  grant_reader "$db" "$password" || {
    echo "$ext: scraped; granting the reader role failed"
    return 1
  }
  database=$(kubectl -n "$NAMESPACE" exec "$db" -- printenv POSTGRES_DB) || return 1
  kubectl apply -f - >/dev/null <<YAML || return 1
# Admit the Grafana pods, and nothing else, to this install's database.
apiVersion: networking.k8s.io/v1
kind: NetworkPolicy
metadata:
  name: $ext-allow-grafana-db
  namespace: $NAMESPACE
  labels:
$(labels "$ext")
spec:
  podSelector:
    matchLabels:
      kamiwaza.ai/extension: $ext
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
  name: $ext-reporting-db
  namespace: $NAMESPACE
  labels:
$(labels "$ext")
spec:
  selector:
    kamiwaza.ai/extension: $ext
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
  name: tomo-datasource-$ext
  namespace: $MONITORING_NAMESPACE
  labels:
    grafana_datasource: "1"
$(labels "$ext")
type: Opaque
stringData:
  tomo-datasource-$ext.yaml: |
    apiVersion: 1
    datasources:
      - name: Tomo · $ext
        uid: tomo-db-$ext
        type: grafana-postgresql-datasource
        access: proxy
        url: $ext-reporting-db.$NAMESPACE.svc.cluster.local:5432
        user: $READER
        editable: false
        jsonData:
          database: $database
          sslmode: disable
          postgresVersion: 1800
          maxOpenConns: 4
          maxIdleConns: 2
          connMaxLifetime: 14400
        secureJsonData:
          password: $password
YAML
  echo "$ext: connected; Grafana provisions the \"Tomo · $ext\" datasource within a minute"
}

# Grafana applied the previous run's tombstones long ago.
kubectl -n "$MONITORING_NAMESPACE" delete secrets -l "$RETIRED" --ignore-not-found >/dev/null

mapfile -t installs < <(installed)
if [ -n "$ONLY" ]; then
  installs=("$ONLY")
fi

if [ "$REMOVE" = true ]; then
  if [ -n "$ONLY" ]; then
    targets=("$ONLY")
  else
    mapfile -t targets < <(connected)
  fi
  for ext in "${targets[@]}"; do
    [ -n "$ext" ] && disconnect "$ext"
  done
  exit 0
fi

# An install that no longer exists leaves a scrape of nothing and a datasource
# that cannot connect; its database, and the role in it, went with it.
if [ -z "$ONLY" ]; then
  while read -r ext; do
    [ -n "$ext" ] || continue
    printf '%s\n' "${installs[@]}" | grep -qx "$ext" || disconnect "$ext"
  done < <(connected)
fi

if [ "${#installs[@]}" -eq 0 ]; then
  echo "No Tomo install in namespace $NAMESPACE."
  exit 0
fi

pending=0
for ext in "${installs[@]}"; do
  # Scrape first: it needs nothing from the database, so a starting or failed
  # install still reports what its running processes can.
  connect_scrape "$ext" || {
    echo "$ext: applying the scrape failed"
    pending=$((pending + 1))
    continue
  }
  connect_database "$ext" || pending=$((pending + 1))
done
[ "$pending" -eq 0 ] || exit 3
