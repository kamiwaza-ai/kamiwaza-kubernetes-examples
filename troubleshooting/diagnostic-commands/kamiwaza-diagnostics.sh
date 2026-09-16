#!/usr/bin/env bash
# Read-only diagnostics for one operator-managed Kamiwaza platform.
#
# Usage:
#   ./kamiwaza-diagnostics.sh
#   KAMIWAZA_NAMESPACE=tenant-a ./kamiwaza-diagnostics.sh
#   KAMIWAZA_NAMESPACE=tenant-a KAMIWAZA_PLATFORM=kamiwaza ./kamiwaza-diagnostics.sh
set -uo pipefail

if [ -t 1 ]; then
  GREEN='\033[0;32m'
  RED='\033[0;31m'
  YELLOW='\033[0;33m'
  NC='\033[0m'
  BOLD='\033[1m'
else
  GREEN=''
  RED=''
  YELLOW=''
  NC=''
  BOLD=''
fi

ERRORS=0
WARNINGS=0

pass() { printf '  %b[OK]%b %s\n' "$GREEN" "$NC" "$1"; }
warn() {
  printf '  %b[WARN]%b %s\n' "$YELLOW" "$NC" "$1"
  WARNINGS=$((WARNINGS + 1))
}
fail() {
  printf '  %b[FAIL]%b %s\n' "$RED" "$NC" "$1"
  ERRORS=$((ERRORS + 1))
}
section() { printf '\n%b=== %s ===%b\n' "$BOLD" "$1" "$NC"; }

if ! command -v kubectl >/dev/null 2>&1; then
  printf 'kubectl is required.\n' >&2
  exit 2
fi

PLATFORM_ROWS=$(kubectl get kamiwazaplatform -A \
  -o jsonpath='{range .items[*]}{.metadata.namespace}{"\t"}{.metadata.name}{"\t"}{.metadata.generation}{"\t"}{.status.observedGeneration}{"\t"}{range .status.conditions[?(@.type=="Ready")]}{.status}{"\t"}{.reason}{end}{"\n"}{end}' 2>/dev/null) || {
  printf 'Cannot list KamiwazaPlatform resources. Check cluster access and install the operator CRDs.\n' >&2
  exit 2
}

mapfile -t MATCHES < <(
  printf '%s\n' "$PLATFORM_ROWS" | awk \
    -v namespace="${KAMIWAZA_NAMESPACE:-}" \
    -v platform="${KAMIWAZA_PLATFORM:-}" \
    'NF && (!namespace || $1 == namespace) && (!platform || $2 == platform)'
)

if [ "${#MATCHES[@]}" -eq 0 ]; then
  printf 'No matching KamiwazaPlatform exists. Set KAMIWAZA_NAMESPACE and KAMIWAZA_PLATFORM when needed.\n' >&2
  exit 2
fi
if [ "${#MATCHES[@]}" -gt 1 ]; then
  printf 'More than one KamiwazaPlatform matches. Set KAMIWAZA_NAMESPACE and KAMIWAZA_PLATFORM.\n' >&2
  exit 2
fi

IFS=$'\t' read -r NAMESPACE PLATFORM GENERATION OBSERVED READY READY_REASON <<<"${MATCHES[0]}"

section "Platform"
printf '  Platform: %s/%s\n' "$NAMESPACE" "$PLATFORM"
if [ "$GENERATION" != "$OBSERVED" ]; then
  fail "Generation not observed: desired $GENERATION, observed ${OBSERVED:-none}"
elif [ "$READY" = "True" ]; then
  pass "Platform Ready: $READY_REASON"
else
  fail "Platform not Ready: ${READY_REASON:-reason unavailable}"
fi

COMPONENTS=$(kubectl get kamiwazaplatform "$PLATFORM" -n "$NAMESPACE" \
  -o jsonpath='{range .status.components[*]}{.name}{"\t"}{.message}{"\n"}{end}' 2>/dev/null || true)
if [ -n "$COMPONENTS" ]; then
  printf '%s\n' "$COMPONENTS" | awk -F '\t' '{printf "  %-24s %s\n", $1, $2}'
fi

section "Pods"
PODS=$(kubectl get pods -n "$NAMESPACE" --no-headers 2>/dev/null) || {
  fail "Cannot list pods"
  PODS=''
}
TOTAL=$(printf '%s\n' "$PODS" | awk 'NF {count++} END {print count+0}')
UNHEALTHY=$(printf '%s\n' "$PODS" | awk '
  NF {
    split($2, ready, "/")
    if (!(($3 == "Running" && ready[1] == ready[2]) || $3 == "Completed" || $3 == "Succeeded")) print
  }')
if [ "$TOTAL" -eq 0 ]; then
  fail "No pods found"
elif [ -z "$UNHEALTHY" ]; then
  pass "All $TOTAL pods ready"
else
  fail "Pods are not ready:"
  printf '%s\n' "$UNHEALTHY" | sed 's/^/    /'
fi

RESTARTED=$(printf '%s\n' "$PODS" | awk 'NF && $4+0 > 0 {print}')
if [ -n "$RESTARTED" ]; then
  warn "Pods have container restarts:"
  printf '%s\n' "$RESTARTED" | sed 's/^/    /'
else
  pass "No container restarts"
fi

section "Persistent storage"
PVCS=$(kubectl get pvc -n "$NAMESPACE" --no-headers 2>/dev/null) || {
  fail "Cannot list persistent volume claims"
  PVCS=''
}
PVC_TOTAL=$(printf '%s\n' "$PVCS" | awk 'NF {count++} END {print count+0}')
UNBOUND=$(printf '%s\n' "$PVCS" | awk 'NF && $2 != "Bound" {print}')
if [ -n "$UNBOUND" ]; then
  fail "Persistent volume claims are not bound:"
  printf '%s\n' "$UNBOUND" | sed 's/^/    /'
else
  pass "All $PVC_TOTAL persistent volume claims bound"
fi

section "Model deployments"
MODELS=$(kubectl get modeldeployments -n "$NAMESPACE" --no-headers \
  -o custom-columns='NAME:.metadata.name,GENERATION:.metadata.generation,OBSERVED:.status.observedGeneration,READY:.status.conditions[?(@.type=="Ready")].status,REASON:.status.conditions[?(@.type=="Ready")].reason' 2>/dev/null || true)
if [ -z "$MODELS" ]; then
  pass "No model deployments declared"
else
  printf '%s\n' "$MODELS" | awk '{printf "  %-32s generation %s/%s  Ready=%s  %s\n", $1, $2, $3, $4, $5}'
  MODEL_ISSUES=$(printf '%s\n' "$MODELS" | awk 'NF && ($2 != $3 || $4 != "True") {count++} END {print count+0}')
  if [ "$MODEL_ISSUES" -gt 0 ]; then
    fail "$MODEL_ISSUES model deployment(s) not reconciled and ready"
  else
    pass "All model deployments reconciled and ready"
  fi
fi

section "Extensions"
EXTENSIONS=$(kubectl get kamiwazaextensions -n "$NAMESPACE" --no-headers \
  -o custom-columns='NAME:.metadata.name,PHASE:.status.phase,READY:.status.conditions[?(@.type=="Ready")].status' 2>/dev/null || true)
if [ -z "$EXTENSIONS" ]; then
  pass "No extensions declared"
else
  printf '%s\n' "$EXTENSIONS" | awk '{printf "  %-48s phase=%s  Ready=%s\n", $1, $2, $3}'
  EXTENSION_ISSUES=$(printf '%s\n' "$EXTENSIONS" | awk 'NF && $3 != "True" {count++} END {print count+0}')
  if [ "$EXTENSION_ISSUES" -gt 0 ]; then
    fail "$EXTENSION_ISSUES extension(s) not ready"
  else
    pass "All extensions ready"
  fi
fi

section "Warning events"
EVENTS=$(kubectl get events -n "$NAMESPACE" --field-selector type=Warning --sort-by=.lastTimestamp --no-headers 2>/dev/null || true)
if [ -n "$EVENTS" ]; then
  warn "Namespace has warning events:"
  printf '%s\n' "$EVENTS" | sed 's/^/    /'
else
  pass "No warning events"
fi

section "Summary"
if [ "$ERRORS" -gt 0 ]; then
  printf '%b%b%d error(s), %d warning(s).%b\n' "$RED" "$BOLD" "$ERRORS" "$WARNINGS" "$NC"
  exit 1
fi
if [ "$WARNINGS" -gt 0 ]; then
  printf '%b%b%d warning(s), no errors.%b\n' "$YELLOW" "$BOLD" "$WARNINGS" "$NC"
else
  printf '%b%bAll checks passed.%b\n' "$GREEN" "$BOLD" "$NC"
fi
