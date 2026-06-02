#!/usr/bin/env bash
set -euo pipefail

usage() {
  cat <<'EOF'
Usage:
  launch-airgap-chrome.sh [options] <kamiwaza-url>

Options:
  --chrome-bin PATH       Chrome/Chromium executable to use.
  --profile-dir PATH      Isolated browser profile directory.
  --proxy URL             Dead proxy URL. Default: http://127.0.0.1:9
  --extra-bypass HOST     Additional host to allow through the proxy bypass.
  -h, --help              Show this help.

The browser can reach only hosts in the proxy bypass list. Everything else is
sent to the dead proxy and should fail.
EOF
}

CHROME_BIN="${CHROME_BIN:-}"
PROFILE_DIR="${KAMIWAZA_AIRGAP_CHROME_PROFILE:-/tmp/kamiwaza-airgap-chrome}"
PROXY_SERVER="${KAMIWAZA_AIRGAP_PROXY:-http://127.0.0.1:9}"
EXTRA_BYPASS=()
KAMIWAZA_URL=""

while [[ $# -gt 0 ]]; do
  case "$1" in
    --chrome-bin)
      CHROME_BIN="${2:?missing value for --chrome-bin}"
      shift 2
      ;;
    --profile-dir)
      PROFILE_DIR="${2:?missing value for --profile-dir}"
      shift 2
      ;;
    --proxy)
      PROXY_SERVER="${2:?missing value for --proxy}"
      shift 2
      ;;
    --extra-bypass)
      EXTRA_BYPASS+=("${2:?missing value for --extra-bypass}")
      shift 2
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    -*)
      echo "unknown option: $1" >&2
      usage >&2
      exit 2
      ;;
    *)
      if [[ -n "$KAMIWAZA_URL" ]]; then
        echo "only one Kamiwaza URL may be provided" >&2
        exit 2
      fi
      KAMIWAZA_URL="$1"
      shift
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

KAMIWAZA_HOST="$(
  python3 - "$KAMIWAZA_URL" <<'PY'
from urllib.parse import urlparse
import sys

parsed = urlparse(sys.argv[1])
if not parsed.hostname:
    raise SystemExit("could not parse hostname from URL")
print(parsed.hostname)
PY
)"

find_chrome() {
  local candidate
  if [[ -n "$CHROME_BIN" ]]; then
    printf '%s\n' "$CHROME_BIN"
    return 0
  fi

  if [[ "${OSTYPE:-}" == darwin* ]]; then
    for candidate in \
      "/Applications/Google Chrome.app/Contents/MacOS/Google Chrome" \
      "/Applications/Chromium.app/Contents/MacOS/Chromium" \
      "/Applications/Microsoft Edge.app/Contents/MacOS/Microsoft Edge"; do
      if [[ -x "$candidate" ]]; then
        printf '%s\n' "$candidate"
        return 0
      fi
    done
  fi

  for candidate in google-chrome google-chrome-stable chromium chromium-browser microsoft-edge brave-browser; do
    if command -v "$candidate" >/dev/null 2>&1; then
      command -v "$candidate"
      return 0
    fi
  done

  return 1
}

CHROME_BIN="$(find_chrome)" || {
  echo "could not find Chrome/Chromium; pass --chrome-bin PATH" >&2
  exit 1
}

BYPASS=("$KAMIWAZA_HOST" "localhost" "127.0.0.1" "<-loopback>")
if [[ "$KAMIWAZA_HOST" != *":"* && ! "$KAMIWAZA_HOST" =~ ^[0-9.]+$ ]]; then
  BYPASS+=("*.${KAMIWAZA_HOST}")
fi
BYPASS+=("${EXTRA_BYPASS[@]}")

BYPASS_LIST="$(IFS=';'; echo "${BYPASS[*]}")"

mkdir -p "$PROFILE_DIR"

cat <<EOF
Launching: $CHROME_BIN
URL:       $KAMIWAZA_URL
Proxy:     $PROXY_SERVER
Bypass:    $BYPASS_LIST
Profile:   $PROFILE_DIR
EOF

exec "$CHROME_BIN" \
  --user-data-dir="$PROFILE_DIR" \
  --disable-extensions \
  --proxy-server="$PROXY_SERVER" \
  --proxy-bypass-list="$BYPASS_LIST" \
  "$KAMIWAZA_URL"
