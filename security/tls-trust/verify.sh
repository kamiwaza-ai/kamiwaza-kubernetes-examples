#!/usr/bin/env bash
# Verify the custom CA trust recipe.
#
# Usage:
#   security/tls-trust/verify.sh                       # structural checks only
#   security/tls-trust/verify.sh https://endpoint      # + live outbound TLS probe from a Ray pod
#
# Exit non-zero on the first failed structural check.
set -euo pipefail

NS="${KAMIWAZA_NS:-kamiwaza}"
SYNC_NAMESPACES=(kamiwaza kamiwaza-system kamiwaza-extensions)
BUNDLE_CM="kamiwaza-trust-bundle"
BUNDLE_PATH="/etc/ssl/certs/ca-certificates.crt"
PROBE_URL="${1:-}"

pass() { printf '  \033[32m✓\033[0m %s\n' "$1"; }
fail() { printf '  \033[31m✗\033[0m %s\n' "$1"; exit 1; }
info() { printf '\033[1m%s\033[0m\n' "$1"; }

info "1. Trust-bundle ConfigMap present in all target namespaces"
for ns in "${SYNC_NAMESPACES[@]}"; do
  kubectl -n "$ns" get configmap "$BUNDLE_CM" >/dev/null 2>&1 \
    && pass "$ns/$BUNDLE_CM present" \
    || fail "$ns/$BUNDLE_CM missing — run security/tls-trust/build-trust-bundle-configmap.sh to create it"
done

info "2. Bundle contains multiple CAs (Mozilla + platform root + your CA)"
CERT_COUNT="$(kubectl -n "$NS" get configmap "$BUNDLE_CM" \
  -o jsonpath='{.data.ca-certificates\.crt}' | grep -c 'BEGIN CERTIFICATE' || true)"
if [ "${CERT_COUNT:-0}" -gt 1 ]; then
  pass "bundle holds $CERT_COUNT certificates"
else
  fail "bundle holds ${CERT_COUNT:-0} certificate(s) — CA Secret not merged?"
fi

info "3. Scheduler: mount + trust env vars"
SCHED_ENV="$(kubectl -n "$NS" exec deploy/core-scheduler -c core -- \
  sh -c "ls $BUNDLE_PATH >/dev/null 2>&1 && env" 2>/dev/null || true)"
[ -n "$SCHED_ENV" ] && pass "scheduler has $BUNDLE_PATH mounted" \
  || fail "scheduler missing $BUNDLE_PATH mount (deploy/core-scheduler not ready?)"
# In-pod cert count guards against a silent-empty-mount failure: the chart mounts
# the bundle ConfigMap with optional: true, so if the kamiwaza-trust-bundle
# ConfigMap was not built/applied (run build-trust-bundle-configmap.sh) the file
# is missing or empty inside the container even though the volume "mounts cleanly".
SCHED_CERT_COUNT="$(kubectl -n "$NS" exec deploy/core-scheduler -c core -- \
  sh -c "grep -c 'BEGIN CERTIFICATE' $BUNDLE_PATH 2>/dev/null" 2>/dev/null || echo 0)"
if [ "${SCHED_CERT_COUNT:-0}" -gt 50 ]; then
  pass "scheduler bundle has $SCHED_CERT_COUNT certs in-pod (Mozilla set present)"
else
  fail "scheduler bundle has only ${SCHED_CERT_COUNT:-0} certs in-pod — ConfigMap not built (run build-trust-bundle-configmap.sh), or pod predates the bundle (rollout restart)"
fi
for v in AWS_CA_BUNDLE SSL_CERT_FILE REQUESTS_CA_BUNDLE; do
  echo "$SCHED_ENV" | grep -q "^${v}=${BUNDLE_PATH}$" \
    && pass "scheduler $v=$BUNDLE_PATH" \
    || fail "scheduler missing $v=$BUNDLE_PATH (merge the values snippet + re-sync)"
done

info "4. Ray head: mount + trust env vars"
RAY_POD="$(kubectl -n "$NS" get pods -l ray.io/node-type=head -o name 2>/dev/null | head -1)"
if [ -z "$RAY_POD" ]; then
  RAY_POD="$(kubectl -n "$NS" get pods -o name 2>/dev/null | grep -i raycluster | head -1 || true)"
fi
if [ -n "$RAY_POD" ]; then
  RAY_ENV="$(kubectl -n "$NS" exec "$RAY_POD" -- \
    sh -c "ls $BUNDLE_PATH >/dev/null 2>&1 && env" 2>/dev/null || true)"
  echo "$RAY_ENV" | grep -q "^AWS_CA_BUNDLE=${BUNDLE_PATH}$" \
    && pass "Ray ($RAY_POD) has bundle + AWS_CA_BUNDLE" \
    || fail "Ray pod missing bundle/AWS_CA_BUNDLE"
else
  printf '  (no Ray pod found — skipping)\n'
fi

info "5. LiteLLM trust resolution (does litellm pick up the bundle?)"
TARGET_POD="${RAY_POD:-deploy/core-scheduler}"
RESOLVED="$(kubectl -n "$NS" exec "$TARGET_POD" -- python -c \
  "from litellm.llms.custom_httpx.http_handler import get_ssl_verify; print(get_ssl_verify())" 2>/dev/null || true)"
if [ "$RESOLVED" = "$BUNDLE_PATH" ]; then
  pass "litellm get_ssl_verify() -> $RESOLVED (verifying against the bundle)"
elif [ -n "$RESOLVED" ]; then
  fail "litellm get_ssl_verify() -> '$RESOLVED' (expected $BUNDLE_PATH — is SSL_CERT_FILE set on this pod?)"
else
  printf '  (could not import litellm in %s — skipping)\n' "$TARGET_POD"
fi

if [ -n "$PROBE_URL" ]; then
  info "6. Live TLS probe to $PROBE_URL via httpx (litellm's transport, verification ON)"
  # httpx exercises the SAME SSL_CERT_FILE resolution litellm/Bedrock use — unlike urllib.
  if kubectl -n "$NS" exec "$TARGET_POD" -- python -c \
    "import httpx; print('status', httpx.get('$PROBE_URL', timeout=15).status_code)" 2>/dev/null; then
    pass "httpx TLS handshake to $PROBE_URL verified against the bundle"
  else
    fail "httpx probe to $PROBE_URL failed — check the CA chain in the Secret / endpoint URL"
  fi
fi

info "All checks passed."
