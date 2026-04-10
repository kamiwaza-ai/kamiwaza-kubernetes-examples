#!/usr/bin/env bash
# Kamiwaza platform diagnostic report.
# Runs read-only checks against every component and prints a summary.
#
# Usage:
#   ./kamiwaza-diagnostics.sh
#   ./kamiwaza-diagnostics.sh | tee diagnostics-$(date +%Y%m%d-%H%M).txt
set -euo pipefail

NAMESPACE="${KAMIWAZA_NAMESPACE:-kamiwaza}"

# Colors (disabled if not a terminal)
if [ -t 1 ]; then
  GREEN='\033[0;32m'; RED='\033[0;31m'; YELLOW='\033[0;33m'; NC='\033[0m'; BOLD='\033[1m'
else
  GREEN=''; RED=''; YELLOW=''; NC=''; BOLD=''
fi

pass() { echo -e "  ${GREEN}[OK]${NC} $1"; }
warn() { echo -e "  ${YELLOW}[WARN]${NC} $1"; }
fail() { echo -e "  ${RED}[FAIL]${NC} $1"; }
section() { echo -e "\n${BOLD}=== $1 ===${NC}"; }

ERRORS=0
WARNINGS=0

check_pods() {
  local ns=$1
  local label=$2
  local name=$3
  local count
  count=$(kubectl get pods -n "$ns" -l "$label" --no-headers 2>/dev/null | grep -c Running || true)
  if [ "$count" -gt 0 ]; then
    pass "$name: $count running"
  else
    fail "$name: no running pods"
    ERRORS=$((ERRORS + 1))
  fi
}

# ---------------------------------------------------------------
section "Platform overview"
# ---------------------------------------------------------------
TOTAL=$(kubectl get pods -n "$NAMESPACE" --no-headers 2>/dev/null | wc -l)
RUNNING=$(kubectl get pods -n "$NAMESPACE" --no-headers 2>/dev/null | grep -c Running || true)
COMPLETED=$(kubectl get pods -n "$NAMESPACE" --no-headers 2>/dev/null | grep -c Completed || true)
NOT_READY=$((TOTAL - RUNNING - COMPLETED))

if [ "$NOT_READY" -eq 0 ]; then
  pass "All $TOTAL pods healthy ($RUNNING running, $COMPLETED completed)"
else
  warn "$NOT_READY pod(s) not in Running/Completed state"
  kubectl get pods -n "$NAMESPACE" --no-headers 2>/dev/null | grep -v -E 'Running|Completed' | sed 's/^/    /'
  WARNINGS=$((WARNINGS + 1))
fi

RESTART_PODS=$(kubectl get pods -n "$NAMESPACE" -o jsonpath='{range .items[*]}{.metadata.name}{" "}{range .status.containerStatuses[*]}{.restartCount}{" "}{end}{"\n"}{end}' 2>/dev/null | \
  awk '{total=0; for(i=2;i<=NF;i++) total+=$i; if(total>0) print "    "$1" ("total" restarts)"}')
if [ -n "$RESTART_PODS" ]; then
  warn "Pods with restarts:"
  echo "$RESTART_PODS"
  WARNINGS=$((WARNINGS + 1))
else
  pass "No pod restarts"
fi

# ---------------------------------------------------------------
section "Core scheduler"
# ---------------------------------------------------------------
check_pods "$NAMESPACE" "app.kubernetes.io/name=core-scheduler" "Scheduler"

if kubectl exec -n "$NAMESPACE" deployment/core-scheduler -c core -- \
  curl -sf http://core-raycluster-head-svc:7777/api/node/node_status >/dev/null 2>&1; then
  pass "API responding on core-raycluster-head-svc:7777"
else
  fail "API not responding on core-raycluster-head-svc:7777"
  ERRORS=$((ERRORS + 1))
fi

FORWARDAUTH=$(kubectl exec -n "$NAMESPACE" deployment/core-scheduler -c core -- \
  env 2>/dev/null | grep '^FORWARDAUTH_ENABLED=' | head -1 || echo "FORWARDAUTH_ENABLED=unknown")
pass "Auth: $FORWARDAUTH"

# ---------------------------------------------------------------
section "Ray cluster"
# ---------------------------------------------------------------
HEAD_POD=$(kubectl get pod -n "$NAMESPACE" -l ray.io/node-type=head -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || true)
if [ -n "$HEAD_POD" ]; then
  pass "Ray head: $HEAD_POD"
  WORKER_COUNT=$(kubectl get pod -n "$NAMESPACE" -l ray.io/node-type=worker --no-headers 2>/dev/null | grep -c Running || true)
  pass "Ray workers: ${WORKER_COUNT:-0} running"
else
  fail "No Ray head pod found"
  ERRORS=$((ERRORS + 1))
fi

# ---------------------------------------------------------------
section "PostgreSQL"
# ---------------------------------------------------------------
check_pods "$NAMESPACE" "app.kubernetes.io/name=core-postgres" "PostgreSQL"

PG_STATUS=$(kubectl exec -n "$NAMESPACE" core-postgres-0 -- \
  psql -U core -d kamiwaza -tAc "SELECT numbackends FROM pg_stat_database WHERE datname = 'kamiwaza';" 2>/dev/null || echo "error")
if [ "$PG_STATUS" != "error" ]; then
  pass "PostgreSQL reachable ($PG_STATUS active connections)"
  DB_SIZE=$(kubectl exec -n "$NAMESPACE" core-postgres-0 -- \
    psql -U core -d kamiwaza -tAc "SELECT pg_size_pretty(pg_database_size('kamiwaza'));" 2>/dev/null)
  pass "Database size: $DB_SIZE"
else
  fail "PostgreSQL not reachable"
  ERRORS=$((ERRORS + 1))
fi

# ---------------------------------------------------------------
section "etcd"
# ---------------------------------------------------------------
ETCD_HEALTH=$(kubectl exec -n "$NAMESPACE" core-etcd-0 -- \
  etcdctl endpoint health 2>&1 || true)
if echo "$ETCD_HEALTH" | grep -q "is healthy"; then
  pass "etcd healthy"
else
  fail "etcd unhealthy: $ETCD_HEALTH"
  ERRORS=$((ERRORS + 1))
fi

ETCD_LEADER=$(kubectl exec -n "$NAMESPACE" core-etcd-0 -- \
  etcdctl endpoint status --write-out=json 2>/dev/null | \
  python3 -c "import sys,json; d=json.load(sys.stdin); print('yes' if d[0]['Status']['leader']==d[0]['Status']['header']['member_id'] else 'no')" 2>/dev/null || echo "unknown")
pass "etcd-0 is leader: $ETCD_LEADER"

ETCD_SIZE=$(kubectl exec -n "$NAMESPACE" core-etcd-0 -- \
  etcdctl endpoint status --write-out=json 2>/dev/null | \
  python3 -c "import sys,json; d=json.load(sys.stdin); print(f'{d[0][\"Status\"][\"dbSize\"]/1024:.0f} KB')" 2>/dev/null || echo "unknown")
pass "etcd DB size: $ETCD_SIZE"

# ---------------------------------------------------------------
section "Keycloak"
# ---------------------------------------------------------------
KC_PODS=$(kubectl get pods -n "$NAMESPACE" -l app.kubernetes.io/name=keycloak --no-headers 2>/dev/null | grep -c Running || true)
if [ "$KC_PODS" -gt 0 ]; then
  pass "Keycloak: $KC_PODS running"
  if kubectl exec -n "$NAMESPACE" deployment/core-scheduler -c core -- \
    curl -sf http://keycloak:8080/health/ready >/dev/null 2>&1; then
    pass "Keycloak health: ready"
  else
    warn "Keycloak health check failed"
    WARNINGS=$((WARNINGS + 1))
  fi
else
  pass "Keycloak: not deployed (lite mode)"
fi

# ---------------------------------------------------------------
section "Frontend"
# ---------------------------------------------------------------
check_pods "$NAMESPACE" "app.kubernetes.io/name=frontend" "Frontend"

# ---------------------------------------------------------------
section "Traefik"
# ---------------------------------------------------------------
check_pods "$NAMESPACE" "app.kubernetes.io/name=traefik" "Traefik"

TRAEFIK_IP=$(kubectl get svc traefik -n "$NAMESPACE" -o jsonpath='{.status.loadBalancer.ingress[0].ip}' 2>/dev/null || echo "none")
if [ "$TRAEFIK_IP" != "none" ] && [ -n "$TRAEFIK_IP" ]; then
  pass "Traefik external IP: $TRAEFIK_IP"
else
  pass "Traefik: ClusterIP only (use port-forward for external access)"
fi

ROUTE_COUNT=$(kubectl get ingressroute -n "$NAMESPACE" --no-headers 2>/dev/null | wc -l)
pass "IngressRoutes: $ROUTE_COUNT configured"

# ---------------------------------------------------------------
section "Extensions"
# ---------------------------------------------------------------
EXT_OP=$(kubectl get pods -n kamiwaza-system -l app.kubernetes.io/name=extension-operator --no-headers 2>/dev/null | grep -c Running || true)
if [ "$EXT_OP" -gt 0 ]; then
  pass "Extension operator: running"
else
  warn "Extension operator: not found"
  WARNINGS=$((WARNINGS + 1))
fi

EXT_PODS=$(kubectl get pods -n kamiwaza-extensions --no-headers 2>/dev/null | grep -c Running || true)
pass "Extension pods: ${EXT_PODS:-0} running"

SANDBOX_PODS=$(kubectl get pods -n kamiwaza-sandboxes --no-headers 2>/dev/null | grep -c Running || true)
pass "Sandbox pods: ${SANDBOX_PODS:-0} running"

# ---------------------------------------------------------------
section "Storage"
# ---------------------------------------------------------------
PVC_ISSUES=$(kubectl get pvc -n "$NAMESPACE" --no-headers 2>/dev/null | grep -v Bound | wc -l || true)
PVC_TOTAL=$(kubectl get pvc -n "$NAMESPACE" --no-headers 2>/dev/null | wc -l || true)
if [ "$PVC_ISSUES" -eq 0 ]; then
  pass "All $PVC_TOTAL PVCs bound"
else
  warn "$PVC_ISSUES PVC(s) not bound:"
  kubectl get pvc -n "$NAMESPACE" --no-headers 2>/dev/null | grep -v Bound | sed 's/^/    /'
  WARNINGS=$((WARNINGS + 1))
fi

# ---------------------------------------------------------------
section "Summary"
# ---------------------------------------------------------------
if [ "$ERRORS" -eq 0 ] && [ "$WARNINGS" -eq 0 ]; then
  echo -e "${GREEN}${BOLD}All checks passed.${NC}"
elif [ "$ERRORS" -eq 0 ]; then
  echo -e "${YELLOW}${BOLD}$WARNINGS warning(s), no errors.${NC}"
else
  echo -e "${RED}${BOLD}$ERRORS error(s), $WARNINGS warning(s).${NC}"
fi
