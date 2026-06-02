#!/usr/bin/env bash
set -euo pipefail

usage() {
  cat <<'EOF'
Usage:
  server-egress-probe.sh --kamiwaza-url URL [options]

Options:
  --namespace NS        Namespace used when auto-selecting a pod. Default: kamiwaza
  --pod NS/NAME         Pod to use for in-cluster public egress probes.
  --public-url URL      Public URL expected to be blocked. May be repeated.
  --out-dir DIR         Evidence output directory.
  --timeout-sec N       Curl/Python probe timeout. Default: 8
  -h, --help            Show this help.

Run this after server-side public egress deny is active. Public probes should
fail; the Kamiwaza health probe should still connect.
EOF
}

KAMIWAZA_URL=""
NAMESPACE="kamiwaza"
POD_REF=""
OUT_DIR=""
TIMEOUT_SEC="8"
PUBLIC_URLS=(
  "https://huggingface.co"
  "https://pypi.org/simple/"
  "https://registry-1.docker.io/v2/"
  "https://fonts.googleapis.com/css2"
  "https://info.kamiwaza.ai"
)

while [[ $# -gt 0 ]]; do
  case "$1" in
    --kamiwaza-url)
      KAMIWAZA_URL="${2:?missing value for --kamiwaza-url}"
      shift 2
      ;;
    --namespace)
      NAMESPACE="${2:?missing value for --namespace}"
      shift 2
      ;;
    --pod)
      POD_REF="${2:?missing value for --pod}"
      shift 2
      ;;
    --public-url)
      PUBLIC_URLS+=("${2:?missing value for --public-url}")
      shift 2
      ;;
    --out-dir)
      OUT_DIR="${2:?missing value for --out-dir}"
      shift 2
      ;;
    --timeout-sec)
      TIMEOUT_SEC="${2:?missing value for --timeout-sec}"
      shift 2
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      echo "unknown option: $1" >&2
      usage >&2
      exit 2
      ;;
  esac
done

if [[ -z "$KAMIWAZA_URL" ]]; then
  usage >&2
  exit 2
fi

if [[ "$KAMIWAZA_URL" != *"://"* ]]; then
  KAMIWAZA_URL="https://${KAMIWAZA_URL}"
fi
KAMIWAZA_URL="${KAMIWAZA_URL%/}"

if [[ -z "$OUT_DIR" ]]; then
  OUT_DIR="airgap-evidence-$(date -u +%Y%m%dT%H%M%SZ)"
fi
mkdir -p "$OUT_DIR"

log() {
  printf '%s\n' "$*" | tee -a "$OUT_DIR/summary.txt"
}

probe_url() {
  local label="$1"
  local url="$2"
  local expectation="$3"
  local output
  local rc

  set +e
  output="$(curl -k -L -I --max-time "$TIMEOUT_SEC" -sS -o /dev/null \
    -w 'http_code=%{http_code} remote_ip=%{remote_ip} url=%{url_effective}' "$url" 2>&1)"
  rc=$?
  set -e

  if [[ "$rc" -eq 0 ]]; then
    log "REACHABLE [$label] $output"
    if [[ "$expectation" == "blocked" ]]; then
      log "  FAIL: public URL was reachable"
    fi
  else
    log "BLOCKED_OR_FAILED [$label] rc=$rc $output"
    if [[ "$expectation" == "reachable" ]]; then
      log "  FAIL: Kamiwaza URL did not connect"
    fi
  fi
}

{
  echo "date_utc=$(date -u +%Y-%m-%dT%H:%M:%SZ)"
  echo "host=$(hostname -f 2>/dev/null || hostname)"
  echo "uname=$(uname -a)"
  echo "kamiwaza_url=$KAMIWAZA_URL"
  echo "namespace=$NAMESPACE"
  echo "pod_ref=${POD_REF:-auto}"
} > "$OUT_DIR/metadata.txt"

log "Evidence directory: $OUT_DIR"
log "Kamiwaza URL: $KAMIWAZA_URL"
log ""
log "Host-level probes"
probe_url "kamiwaza-health" "$KAMIWAZA_URL/api/health" "reachable"
for url in "${PUBLIC_URLS[@]}"; do
  probe_url "public" "$url" "blocked"
done

if command -v kubectl >/dev/null 2>&1; then
  log ""
  log "Kubernetes evidence"
  kubectl config current-context > "$OUT_DIR/kubectl-context.txt" 2>&1 || true
  kubectl get pods -A -o wide > "$OUT_DIR/pods-wide.txt" 2>&1 || true
  kubectl get pods -A -o json > "$OUT_DIR/pods.json" 2>/dev/null || true

  if [[ -s "$OUT_DIR/pods.json" ]]; then
    python3 - "$OUT_DIR/pods.json" > "$OUT_DIR/image-summary.txt" <<'PY'
import json
import sys
from collections import Counter

public_registries = (
    "docker.io/",
    "index.docker.io/",
    "registry-1.docker.io/",
    "quay.io/",
    "ghcr.io/",
    "gcr.io/",
    "k8s.gcr.io/",
    "registry.k8s.io/",
    "public.ecr.aws/",
)

def image_flag(image: str) -> str:
    first = image.split("/", 1)[0]
    has_explicit_registry = "/" in image and (
        "." in first or ":" in first or first == "localhost"
    )
    if not has_explicit_registry:
        return "IMPLICIT_DOCKERHUB"
    if image.startswith(public_registries):
        return "PUBLIC_REGISTRY_REFERENCE"
    return "review"


with open(sys.argv[1], "r", encoding="utf-8") as f:
    pods = json.load(f)

images = Counter()
for pod in pods.get("items", []):
    spec = pod.get("spec", {})
    for key in ("initContainers", "containers"):
        for container in spec.get(key) or []:
            image = container.get("image")
            if image:
                images[image] += 1

print("Image references:")
for image, count in sorted(images.items()):
    flag = image_flag(image)
    print(f"{count:4d} {flag:25s} {image}")
PY
    log "wrote $OUT_DIR/image-summary.txt"
  fi

  if [[ -z "$POD_REF" ]]; then
    AUTO_POD="$(kubectl -n "$NAMESPACE" get pods \
      --field-selector=status.phase=Running \
      -o jsonpath='{range .items[*]}{.metadata.name}{"\n"}{end}' 2>/dev/null \
      | grep -Ei 'core|api|backend' | head -n1 || true)"
    if [[ -n "$AUTO_POD" ]]; then
      POD_REF="$NAMESPACE/$AUTO_POD"
    fi
  fi

  if [[ -n "$POD_REF" ]]; then
    POD_NS="${POD_REF%%/*}"
    POD_NAME="${POD_REF#*/}"
    log ""
    log "Pod-level public egress probes from $POD_NS/$POD_NAME"

    PY_CODE='import sys, urllib.request
timeout = int(sys.argv[1])
for url in sys.argv[2:]:
    try:
        with urllib.request.urlopen(url, timeout=timeout) as resp:
            print(f"REACHABLE url={url} status={resp.status}")
    except Exception as exc:
        print(f"BLOCKED_OR_FAILED url={url} error={type(exc).__name__}:{exc}")'

    set +e
    kubectl -n "$POD_NS" exec "$POD_NAME" -- python3 -c "$PY_CODE" "$TIMEOUT_SEC" "${PUBLIC_URLS[@]}" \
      > "$OUT_DIR/pod-public-probes.txt" 2>&1
    pod_rc=$?
    if [[ "$pod_rc" -ne 0 ]]; then
      kubectl -n "$POD_NS" exec "$POD_NAME" -- python -c "$PY_CODE" "$TIMEOUT_SEC" "${PUBLIC_URLS[@]}" \
        > "$OUT_DIR/pod-public-probes.txt" 2>&1
      pod_rc=$?
    fi
    set -e

    if [[ "$pod_rc" -eq 0 ]]; then
      tee -a "$OUT_DIR/summary.txt" < "$OUT_DIR/pod-public-probes.txt"
      if grep -q '^REACHABLE ' "$OUT_DIR/pod-public-probes.txt"; then
        log "  FAIL: at least one public URL was reachable from the pod"
      fi
    else
      log "pod probe skipped or failed; see $OUT_DIR/pod-public-probes.txt"
    fi
  else
    log "pod probe skipped: no --pod provided and no core/api/backend pod auto-selected"
  fi
else
  log ""
  log "kubectl not found; skipped Kubernetes evidence"
fi

log ""
log "Done. Review $OUT_DIR/summary.txt plus Azure NSG/Azure Firewall logs."
