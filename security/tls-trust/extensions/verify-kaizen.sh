#!/usr/bin/env bash
# Verify Kaizen trust wiring for both declared extension pods and spawned sandboxes.
#
# Usage:
#   security/tls-trust/extensions/verify-kaizen.sh <extension-name>
#   security/tls-trust/extensions/verify-kaizen.sh <extension-name> https://endpoint
#   EXPECT_HTTPS_PROXY=http://squid.internal:3128 security/tls-trust/extensions/verify-kaizen.sh <extension-name> https://endpoint
#
# Fail closed:
#   - no backend trust wiring -> fail
#   - no sandbox pod yet -> fail (validation incomplete)
#   - sandbox pod exists but lacks bundle/env -> fail
set -euo pipefail

EXT_NAME="${1:-}"
PROBE_URL="${2:-}"

if [ -z "$EXT_NAME" ]; then
  echo "usage: $0 <extension-name> [https://probe-url]" >&2
  exit 2
fi

EXT_NS="${EXT_NS:-kamiwaza-extensions}"
SANDBOX_NS="${SANDBOX_NS:-kamiwaza-sandboxes}"
BUNDLE_CM="kamiwaza-trust-bundle"
BUNDLE_PATH="/etc/ssl/certs/ca-certificates.crt"
EXPECT_HTTPS_PROXY="${EXPECT_HTTPS_PROXY:-${HTTPS_PROXY:-}}"
EXPECT_HTTP_PROXY="${EXPECT_HTTP_PROXY:-${HTTP_PROXY:-}}"
EXPECT_NO_PROXY="${EXPECT_NO_PROXY:-${NO_PROXY:-}}"

pass() { printf '  \033[32m✓\033[0m %s\n' "$1"; }
fail() {
  printf '  \033[31m✗\033[0m %s\n' "$1"
  exit 1
}
info() { printf '\033[1m%s\033[0m\n' "$1"; }

check_env_equals() {
  local label="$1"
  local text="$2"
  local key="$3"
  local expected="$4"
  echo "$text" | grep -q "^${key}=${expected}$" &&
    pass "${label} ${key}=${expected}" ||
    fail "${label} missing ${key}=${expected}"
}

check_env_if_expected() {
  local label="$1"
  local text="$2"
  local key="$3"
  local expected="$4"
  if [ -n "$expected" ]; then
    check_env_equals "$label" "$text" "$key" "$expected"
  fi
}

check_cert_count() {
  local label="$1"
  local pod_ref="$2"
  local namespace="$3"
  local count
  count="$(kubectl -n "$namespace" exec "$pod_ref" -- sh -c "grep -c 'BEGIN CERTIFICATE' $BUNDLE_PATH 2>/dev/null" 2>/dev/null || echo 0)"
  if [ "${count:-0}" -gt 50 ]; then
    pass "${label} bundle has $count certs in-pod"
  else
    fail "${label} bundle has only ${count:-0} certs in-pod"
  fi
}

probe_httpx() {
  local label="$1"
  local pod_ref="$2"
  local namespace="$3"
  local url="$4"
  if kubectl -n "$namespace" exec "$pod_ref" -- python -c \
    "import httpx; print('status', httpx.get('$url', timeout=15).status_code)" 2>/dev/null; then
    pass "${label} httpx TLS handshake to $url verified against the bundle"
  else
    fail "${label} httpx probe to $url failed"
  fi
}

info "1. Trust bundle ConfigMap present in extension and sandbox namespaces"
kubectl -n "$EXT_NS" get configmap "$BUNDLE_CM" >/dev/null 2>&1 &&
  pass "$EXT_NS/$BUNDLE_CM present" ||
  fail "$EXT_NS/$BUNDLE_CM missing"
kubectl -n "$SANDBOX_NS" get configmap "$BUNDLE_CM" >/dev/null 2>&1 &&
  pass "$SANDBOX_NS/$BUNDLE_CM present" ||
  fail "$SANDBOX_NS/$BUNDLE_CM missing (run build-trust-bundle-configmap.sh --include-sandboxes)"

info "2. Declared Kaizen backend pod has bundle mount + CA env"
BACKEND_POD="$(kubectl -n "$EXT_NS" get pods -l "extensions.kamiwaza.io/deployment-id=${EXT_NAME},extensions.kamiwaza.io/service=backend" -o name 2>/dev/null | head -1)"
[ -n "$BACKEND_POD" ] || fail "No backend pod found for extension ${EXT_NAME}"
BACKEND_ENV="$(kubectl -n "$EXT_NS" exec "$BACKEND_POD" -- sh -c "ls $BUNDLE_PATH >/dev/null 2>&1 && env" 2>/dev/null || true)"
[ -n "$BACKEND_ENV" ] && pass "backend has $BUNDLE_PATH mounted" ||
  fail "backend missing $BUNDLE_PATH mount"
check_cert_count "backend" "$BACKEND_POD" "$EXT_NS"
check_env_equals "backend" "$BACKEND_ENV" "SSL_CERT_FILE" "$BUNDLE_PATH"
check_env_equals "backend" "$BACKEND_ENV" "REQUESTS_CA_BUNDLE" "$BUNDLE_PATH"
check_env_equals "backend" "$BACKEND_ENV" "AWS_CA_BUNDLE" "$BUNDLE_PATH"
check_env_equals "backend" "$BACKEND_ENV" "AGENT_DISABLE_SSL_VERIFY" "false"
check_env_equals "backend" "$BACKEND_ENV" "KAMIWAZA_VERIFY_SSL" "true"
check_env_equals "backend" "$BACKEND_ENV" "KAMIWAZA_TLS_REJECT_UNAUTHORIZED" "1"
check_env_if_expected "backend" "$BACKEND_ENV" "HTTPS_PROXY" "$EXPECT_HTTPS_PROXY"
check_env_if_expected "backend" "$BACKEND_ENV" "HTTP_PROXY" "$EXPECT_HTTP_PROXY"
check_env_if_expected "backend" "$BACKEND_ENV" "NO_PROXY" "$EXPECT_NO_PROXY"

# Turning verification ON only helps if the extension's OWN KAMIWAZA_API_URL is
# reachable under verification. The platform sometimes hands extensions an
# internal HTTPS hostname (e.g. https://traefik.kamiwaza.svc.cluster.local/api)
# that does NOT match the Traefik cert (*.kamiwaza.test) — so verify-ON breaks the
# extension's own API connection even though the CA is trusted. Fail closed on it.
info "3a. Backend reaches its own KAMIWAZA_API_URL with verification ON"
API_PROBE="$(kubectl -n "$EXT_NS" exec "$BACKEND_POD" -- python3 -c '
import httpx, os, sys
url = os.environ.get("KAMIWAZA_API_URL", "")
if not url.startswith("https"):
    print("SKIP " + (url or "(unset)")); sys.exit(0)
try:
    r = httpx.get(url.rstrip("/") + "/models/", timeout=10)  # verify=True -> uses SSL_CERT_FILE bundle
    print("OK " + str(r.status_code))
except Exception as e:
    m = str(e)
    kind = "hostname-mismatch" if "Hostname mismatch" in m else ("unknown-CA" if "unable to get local issuer" in m else type(e).__name__)
    print("FAIL " + kind)
' 2>/dev/null || echo "FAIL exec-failed")"
case "$API_PROBE" in
OK*) pass "backend KAMIWAZA_API_URL verifies under verify-ON (HTTP ${API_PROBE#OK })" ;;
SKIP*) pass "backend KAMIWAZA_API_URL is plain HTTP (TLS not applicable): ${API_PROBE#SKIP }" ;;
*) fail "backend cannot reach its KAMIWAZA_API_URL with verification ON (${API_PROBE#FAIL }). The platform gave this extension an HTTPS API URL whose hostname does not match the Traefik cert (*.kamiwaza.test). Point KAMIWAZA_API_URL at the public origin (https://kamiwaza.test/api) or add the internal hostname to the cert SANs — see README 'The internal API URL is the most common real-world tripwire'." ;;
esac

if [ -n "$PROBE_URL" ]; then
  info "3. Live backend TLS probe to $PROBE_URL"
  probe_httpx "backend" "$BACKEND_POD" "$EXT_NS" "$PROBE_URL"
fi

info "4. Spawned sandbox pod exists and inherits the trust bundle"
SANDBOX_POD="$(kubectl -n "$SANDBOX_NS" get pods -l "kamiwaza.io/parent-extension=${EXT_NAME}" -o name 2>/dev/null | head -1)"
[ -n "$SANDBOX_POD" ] || fail "No sandbox pod found for ${EXT_NAME}. Open or resume a Kaizen conversation, then rerun."
SANDBOX_ENV="$(kubectl -n "$SANDBOX_NS" exec "$SANDBOX_POD" -- sh -c "ls $BUNDLE_PATH >/dev/null 2>&1 && env" 2>/dev/null || true)"
[ -n "$SANDBOX_ENV" ] && pass "sandbox has $BUNDLE_PATH mounted" ||
  fail "sandbox missing $BUNDLE_PATH mount (current config-only packet stops here)"
# NOTE: structural checks confirm a CA bundle is present and that the agent's
# SSL_CERT_FILE/REQUESTS_CA_BUNDLE point at it — NOT that the corporate CA is in
# it. The Kaizen agent image already ships a full bundle (Mozilla + Traefik cert),
# so these can pass with the default bundle. The live probe (step 5) is the only
# proof the corporate CA is trusted.
#
# AWS_CA_BUNDLE and proxy vars are intentionally NOT checked here: the Kaizen
# backend's forward_env (conversation_manager.py) carries only MCP_VERIFY_SSL +
# KAMIWAZA_TRUST_TRAEFIK_CERT in the verify-ON path, so neither reaches sandboxes.
# The agent entrypoint sets SSL_CERT_FILE + REQUESTS_CA_BUNDLE itself.
check_cert_count "sandbox" "$SANDBOX_POD" "$SANDBOX_NS"
check_env_equals "sandbox" "$SANDBOX_ENV" "SSL_CERT_FILE" "$BUNDLE_PATH"
check_env_equals "sandbox" "$SANDBOX_ENV" "REQUESTS_CA_BUNDLE" "$BUNDLE_PATH"

if [ -n "$PROBE_URL" ]; then
  info "5. Live sandbox TLS probe to $PROBE_URL (the real proof of corporate-CA trust)"
  probe_httpx "sandbox" "$SANDBOX_POD" "$SANDBOX_NS" "$PROBE_URL"
else
  info "5. (skipped) No probe URL given — structural checks above do NOT prove the"
  printf '  corporate CA is trusted in the sandbox. Re-run with a corporate-CA https:// URL.\n'
fi

info "Kaizen trust validation passed."
