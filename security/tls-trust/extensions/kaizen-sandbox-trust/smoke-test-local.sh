#!/usr/bin/env bash
# Cluster-free smoke test for the Kaizen sandbox-controller trust overlay.
#
# Validates the recipe WITHOUT a cluster, in two parts:
#
#   PART A (always runnable, dependency-light: python3 only)
#     Runs apply-sandbox-controller-trust.py --print-only --skip-cr-patch --from-file
#     against a sample kubernetes.py and asserts the injection is correct:
#       - exactly 4 `kamiwaza-trust-bundle (tls-trust)` injection sites in the patched file
#       - re-running on the patched output stays at 4 (idempotent)
#       - the patched file passes `python3 -m py_compile`
#     Supply the sample controller file with --from-file <path>, or via $KCTL_SOURCE.
#     The canonical input is a real kubernetes.py extracted from a live controller:
#       kubectl -n kamiwaza-extensions exec <sandbox-controller-pod> -- \
#         cat /usr/local/lib/python3.12/site-packages/kaizen/sandbox_controller/backends/kubernetes.py \
#         > /tmp/kubernetes.py
#
#   PART B (optional, requires Docker + the Kaizen agent image)
#     Mirrors the proven local E2E using the committed demo PKI (../../demo-pki/):
#       - serves a local TLS endpoint signed by the demo intermediate on a docker network
#       - runs the agent image with the demo bundle (ca-chain.pem) bind-mounted at
#         /etc/ssl/certs/ca-certificates.crt — simulating the K8s subPath mount — and
#         httpx-GETs the server: expect OK
#       - a control run WITHOUT the bundle: expect failure (unable to get local issuer)
#     CA trust is isolated from hostname via ssl.create_default_context(cafile=...) +
#     check_hostname=False (the demo leaf is *.kamiwaza.test, the docker DNS name is not).
#     Gated behind `command -v docker` and the AGENT_IMAGE env var; skipped with a clear
#     message if either is absent.
#
# Usage:
#   ./smoke-test-local.sh --from-file /tmp/kubernetes.py
#   KCTL_SOURCE=/tmp/kubernetes.py ./smoke-test-local.sh
#   AGENT_IMAGE=ghcr.io/kamiwaza/kaizen-agent:1.8.13 ./smoke-test-local.sh --from-file /tmp/kubernetes.py
#
# Exit code: 0 if every runnable assertion passes (skipped PART B is not a failure).
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
APPLIER="$HERE/apply-sandbox-controller-trust.py"
DEMO_PKI="$(cd "$HERE/../../demo-pki" && pwd)"
SENTINEL="kamiwaza-trust-bundle (tls-trust)"
EXPECTED_SITES=4

# ---- pretty helpers (repo ✓/✗ style) --------------------------------------
pass() { printf '  \033[32m✓\033[0m %s\n' "$1"; }
fail() { printf '  \033[31m✗\033[0m %s\n' "$1"; exit 1; }
info() { printf '\033[1m%s\033[0m\n' "$1"; }
skip() { printf '  \033[33m–\033[0m %s\n' "$1"; }

# ---- arg parsing -----------------------------------------------------------
KCTL_SOURCE="${KCTL_SOURCE:-}"
while [ $# -gt 0 ]; do
  case "$1" in
    --from-file) KCTL_SOURCE="${2:-}"; shift 2 ;;
    --from-file=*) KCTL_SOURCE="${1#*=}"; shift ;;
    -h|--help) sed -n '2,40p' "$0"; exit 0 ;;
    *) fail "unknown argument: $1 (try --help)" ;;
  esac
done

command -v python3 >/dev/null 2>&1 || fail "python3 is required for PART A"
[ -f "$APPLIER" ] || fail "applier not found: $APPLIER"

WORKDIR="$(mktemp -d)"
DOCKER_NET=""
SERVER_CID=""
cleanup() {
  rm -rf "$WORKDIR" 2>/dev/null || true
  if [ -n "$SERVER_CID" ]; then docker rm -f "$SERVER_CID" >/dev/null 2>&1 || true; fi
  if [ -n "$DOCKER_NET" ]; then docker network rm "$DOCKER_NET" >/dev/null 2>&1 || true; fi
}
trap cleanup EXIT

# Extract just the patched-file section the applier emits between its
# "# ===== patched kubernetes.py ... =====" and "# ===== ConfigMap =====" markers.
extract_patched() {
  # $1 = file containing applier --print-only output ; writes patched source to $2
  awk '
    /^# ===== patched .* =====$/ { grab=1; next }
    /^# ===== ConfigMap =====$/  { grab=0 }
    grab { print }
  ' "$1" > "$2"
}

count_sites() {
  # count sentinel occurrences in $1
  grep -c "$SENTINEL" "$1" || true
}

run_applier_print() {
  # $1 = input kubernetes.py ; $2 = file to capture stdout
  python3 "$APPLIER" smoke-dummy \
    --from-file "$1" \
    --skip-cr-patch \
    --print-only > "$2"
}

# ===========================================================================
# PART A — injection correctness (no cluster, no docker)
# ===========================================================================
info "PART A: injection transform (python3 only)"

if [ -z "$KCTL_SOURCE" ] || [ ! -f "$KCTL_SOURCE" ]; then
  echo
  echo "  PART A needs a sample sandbox-controller kubernetes.py."
  echo "  Provide it with --from-file <path> or KCTL_SOURCE=<path>."
  echo
  echo "  Extract one from a live controller (the canonical input):"
  echo "    kubectl -n kamiwaza-extensions exec <sandbox-controller-pod> -- \\"
  echo "      cat /usr/local/lib/python3.12/site-packages/kaizen/sandbox_controller/backends/kubernetes.py \\"
  echo "      > /tmp/kubernetes.py"
  echo "    ./smoke-test-local.sh --from-file /tmp/kubernetes.py"
  echo
  fail "no sample kubernetes.py supplied (see guidance above)"
fi
pass "sample controller file: $KCTL_SOURCE"

# 1. Patch the sample once.
OUT1="$WORKDIR/out1.txt"
PATCHED1="$WORKDIR/patched1.py"
run_applier_print "$KCTL_SOURCE" "$OUT1"
extract_patched "$OUT1" "$PATCHED1"
[ -s "$PATCHED1" ] || fail "could not extract a patched-file section from applier output"

SITES1="$(count_sites "$PATCHED1")"
if [ "$SITES1" -eq "$EXPECTED_SITES" ]; then
  pass "first pass injected exactly $EXPECTED_SITES '$SENTINEL' sites"
else
  fail "first pass injected $SITES1 sites, expected $EXPECTED_SITES (anchors changed? inspect $PATCHED1)"
fi

# 2. py_compile the patched file.
if python3 -m py_compile "$PATCHED1" 2>"$WORKDIR/pycompile.err"; then
  pass "patched file passes py_compile"
else
  cat "$WORKDIR/pycompile.err" >&2
  fail "patched file failed py_compile"
fi

# 3. Idempotency: re-run the applier on the already-patched file; must STAY at 4.
OUT2="$WORKDIR/out2.txt"
PATCHED2="$WORKDIR/patched2.py"
run_applier_print "$PATCHED1" "$OUT2"
extract_patched "$OUT2" "$PATCHED2"
[ -s "$PATCHED2" ] || fail "could not extract patched-file section on the idempotency re-run"

SITES2="$(count_sites "$PATCHED2")"
if [ "$SITES2" -eq "$EXPECTED_SITES" ]; then
  pass "re-running on patched output stays at $EXPECTED_SITES sites (idempotent)"
else
  fail "idempotency broken: re-run produced $SITES2 sites, expected $EXPECTED_SITES"
fi

# Content-identical re-run is the strongest idempotency signal (the applier's sentinel
# short-circuits, returning the source unchanged). Strip trailing blank lines first so the
# one framing newline that --print-only adds around the patched body is not flagged.
strip_trailing_blank() { sed -e :a -e '/^\n*$/{$d;N;ba' -e '}' "$1"; }
if diff -q <(strip_trailing_blank "$PATCHED1") <(strip_trailing_blank "$PATCHED2") >/dev/null 2>&1; then
  pass "patched content is identical across runs (sentinel short-circuit)"
else
  skip "patched content differs across runs but site count held at $EXPECTED_SITES (acceptable)"
fi

echo
info "PART A passed."

# ===========================================================================
# PART B — local TLS E2E with the demo PKI + agent image (optional)
# ===========================================================================
echo
info "PART B: local TLS E2E (optional — needs Docker + AGENT_IMAGE)"

if ! command -v docker >/dev/null 2>&1; then
  skip "docker not found — skipping PART B (PART A already validated the overlay)"
  echo
  info "Smoke test complete (PART A only)."
  exit 0
fi
if [ -z "${AGENT_IMAGE:-}" ]; then
  skip "AGENT_IMAGE not set — skipping PART B. Re-run with e.g."
  skip "  AGENT_IMAGE=ghcr.io/kamiwaza/kaizen-agent:<tag> ./smoke-test-local.sh --from-file <kubernetes.py>"
  echo
  info "Smoke test complete (PART A only)."
  exit 0
fi

for f in ca-chain.pem ingress-fullchain.pem ingress.key; do
  [ -f "$DEMO_PKI/$f" ] || fail "demo PKI file missing: $DEMO_PKI/$f (run ../../demo-pki/generate.sh)"
done
pass "demo PKI present: ca-chain.pem (anchor) + ingress-fullchain.pem/ingress.key (server)"

DOCKER_NET="kaizen-trust-smoke-$$"
docker network create "$DOCKER_NET" >/dev/null 2>&1 \
  && pass "created docker network $DOCKER_NET" \
  || fail "could not create docker network $DOCKER_NET"

# TLS server: serve the demo leaf chain on :8443 using python's stdlib inside the
# agent image (avoids pulling a second base image). Bind-mount the served chain + key.
TLS_SERVER_PY="$WORKDIR/tls_server.py"
cat > "$TLS_SERVER_PY" <<'PYEOF'
import http.server, ssl
ctx = ssl.SSLContext(ssl.PROTOCOL_TLS_SERVER)
ctx.load_cert_chain(certfile="/srv/fullchain.pem", keyfile="/srv/server.key")
httpd = http.server.HTTPServer(("0.0.0.0", 8443), http.server.SimpleHTTPRequestHandler)
httpd.socket = ctx.wrap_socket(httpd.socket, server_side=True)
print("serving https on :8443", flush=True)
httpd.serve_forever()
PYEOF

SERVER_CID="$(docker run -d --rm \
  --network "$DOCKER_NET" --network-alias tls-server \
  -v "$DEMO_PKI/ingress-fullchain.pem:/srv/fullchain.pem:ro" \
  -v "$DEMO_PKI/ingress.key:/srv/server.key:ro" \
  -v "$TLS_SERVER_PY:/srv/tls_server.py:ro" \
  "$AGENT_IMAGE" python3 /srv/tls_server.py 2>/dev/null || true)"
[ -n "$SERVER_CID" ] || fail "could not start TLS server container from $AGENT_IMAGE"
pass "started demo TLS server (container ${SERVER_CID:0:12}) on the docker network"

# Wait until the server is accepting TLS connections (bounded; no fixed sleep).
PROBE_PY="$WORKDIR/probe.py"
cat > "$PROBE_PY" <<'PYEOF'
# Probe the demo TLS server. CA trust is isolated from hostname on purpose:
# the demo leaf is *.kamiwaza.test, the docker DNS name (tls-server) is not, so we
# disable hostname checking to test ONLY whether the CA bundle establishes trust.
import os, ssl, sys, time
import httpx

mode = os.environ.get("PROBE_MODE", "trust")  # "trust" | "control"
url = "https://tls-server:8443/"

if mode == "trust":
    ctx = ssl.create_default_context(cafile="/etc/ssl/certs/ca-certificates.crt")
else:
    # control: default trust store WITHOUT the demo CA -> must fail to verify
    ctx = ssl.create_default_context()
ctx.check_hostname = False  # isolate CA trust from hostname match

deadline = time.time() + 30
last = ""
while time.time() < deadline:
    try:
        r = httpx.get(url, verify=ctx, timeout=5)
        print("OK", r.status_code)
        sys.exit(0)
    except ssl.SSLCertVerificationError as e:
        # genuine verification failure — report immediately (don't retry-mask it)
        print("VERIFY_FAIL", str(e).splitlines()[0])
        sys.exit(3)
    except Exception as e:  # server may not be up yet — retry until deadline
        last = type(e).__name__ + ": " + str(e).splitlines()[0]
        time.sleep(1)
print("UNREACHABLE", last)
sys.exit(4)
PYEOF

run_probe() {
  # $1 = PROBE_MODE ; mounts the demo bundle only in "trust" mode (simulating the subPath)
  local mode="$1"
  local args=(--network "$DOCKER_NET" --rm -e "PROBE_MODE=$mode"
              -v "$PROBE_PY:/srv/probe.py:ro")
  if [ "$mode" = "trust" ]; then
    args+=(-v "$DEMO_PKI/ca-chain.pem:/etc/ssl/certs/ca-certificates.crt:ro")
  fi
  docker run "${args[@]}" "$AGENT_IMAGE" python3 /srv/probe.py 2>/dev/null || true
}

# Trust run: bundle mounted at the K8s path -> expect OK.
TRUST_OUT="$(run_probe trust)"
case "$TRUST_OUT" in
  OK*) pass "trust run: httpx verified against the mounted demo bundle ($TRUST_OUT)" ;;
  *)   fail "trust run did not verify (got: ${TRUST_OUT:-<empty>}). The demo CA bundle at /etc/ssl/certs/ca-certificates.crt should have established trust." ;;
esac

# Control run: NO bundle mounted -> expect a verification failure (proves the bundle is load-bearing).
CONTROL_OUT="$(run_probe control)"
case "$CONTROL_OUT" in
  VERIFY_FAIL*) pass "control run failed verification as expected ($CONTROL_OUT)" ;;
  OK*)          fail "control run unexpectedly verified WITHOUT the demo bundle — the agent image's default trust store already trusts the demo CA, so this E2E proves nothing. Use a server cert signed by a CA NOT in the image." ;;
  *)            fail "control run gave an unexpected result (got: ${CONTROL_OUT:-<empty>}); expected VERIFY_FAIL" ;;
esac

echo
info "PART B passed."
echo
info "Smoke test complete (PART A + PART B)."
