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
  --netlog PATH           Session-wide NetLog file. Default:
                          ~/Downloads/kamiwaza-airgap.netlog
  --no-netlog             Disable session-wide NetLog capture.
  -h, --help              Show this help.

The browser can reach only hosts in the proxy bypass list. Everything else is
sent to the dead proxy and should fail.

NetLog records every request across all tabs, navigations, and refreshes for the
whole browser session into one file (finalized when Chrome exits), including
blocked/failed attempts. Summarize it with summarize-netlog-origins.py. This
replaces the manual per-page DevTools "Export HAR" step.
EOF
}

CHROME_BIN="${CHROME_BIN:-}"
PROFILE_DIR="${KAMIWAZA_AIRGAP_CHROME_PROFILE:-/tmp/kamiwaza-airgap-chrome}"
PROXY_SERVER="${KAMIWAZA_AIRGAP_PROXY:-http://127.0.0.1:9}"
NETLOG_PATH="${KAMIWAZA_AIRGAP_NETLOG:-$HOME/Downloads/kamiwaza-airgap.netlog}"
NETLOG_ENABLED=1
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
    --netlog)
      NETLOG_PATH="${2:?missing value for --netlog}"
      NETLOG_ENABLED=1
      shift 2
      ;;
    --no-netlog)
      NETLOG_ENABLED=0
      shift
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

# A Windows chrome.exe driven from WSL interprets file paths as Windows paths, so
# a WSL path like /tmp/... becomes C:\tmp\... which it cannot create. Detect that
# case and hand Chrome real Windows paths instead.
is_windows_chrome() {
  command -v wslpath >/dev/null 2>&1 && [[ "$CHROME_BIN" == /mnt/* || "$CHROME_BIN" == *.exe ]]
}

# Windows %TEMP% as a WSL path, for siting Chrome's profile on local Windows disk.
win_temp_wsl() {
  local t
  t="$(cmd.exe /C 'echo %TEMP%' 2>/dev/null | tr -d '\r\n')"
  [[ -n "$t" ]] && wslpath -u "$t" 2>/dev/null
}

BYPASS=("$KAMIWAZA_HOST" "localhost" "127.0.0.1" "<-loopback>")
if [[ "$KAMIWAZA_HOST" != *":"* && ! "$KAMIWAZA_HOST" =~ ^[0-9.]+$ ]]; then
  BYPASS+=("*.${KAMIWAZA_HOST}")
fi
BYPASS+=("${EXTRA_BYPASS[@]}")

BYPASS_LIST="$(IFS=';'; echo "${BYPASS[*]}")"

# Resolve where the profile actually lives (PROFILE_DIR, used for mkdir/report)
# and what we pass to Chrome (PROFILE_FOR_CHROME). A Chrome profile needs local
# disk, so a WSL-native default is relocated to Windows %TEMP%; an explicit
# /mnt/... path is just translated in place.
PROFILE_FOR_CHROME="$PROFILE_DIR"
if is_windows_chrome; then
  if [[ "$PROFILE_DIR" == /mnt/* ]]; then
    PROFILE_FOR_CHROME="$(wslpath -w "$PROFILE_DIR")"
  else
    win_temp="$(win_temp_wsl)"
    if [[ -n "$win_temp" ]]; then
      PROFILE_DIR="${win_temp}/kamiwaza-airgap-chrome"
      PROFILE_FOR_CHROME="$(wslpath -w "$PROFILE_DIR")"
    else
      echo "warning: could not resolve Windows %TEMP%; profile may fail to load" >&2
    fi
  fi
fi

mkdir -p "$PROFILE_DIR"

CHROME_ARGS=(
  --user-data-dir="$PROFILE_FOR_CHROME"
  --disable-extensions
  --proxy-server="$PROXY_SERVER"
  --proxy-bypass-list="$BYPASS_LIST"
)

NETLOG_DISPLAY="(disabled)"
if [[ "$NETLOG_ENABLED" -eq 1 ]]; then
  mkdir -p "$(dirname "$NETLOG_PATH")"
  NETLOG_FOR_CHROME="$NETLOG_PATH"
  if is_windows_chrome; then
    NETLOG_FOR_CHROME="$(wslpath -w "$NETLOG_PATH")"
  fi
  CHROME_ARGS+=(--log-net-log="$NETLOG_FOR_CHROME")
  NETLOG_DISPLAY="$NETLOG_PATH"
fi

cat <<EOF
Launching: $CHROME_BIN
URL:       $KAMIWAZA_URL
Proxy:     $PROXY_SERVER
Bypass:    $BYPASS_LIST
Profile:   $PROFILE_DIR
NetLog:    $NETLOG_DISPLAY
EOF

if [[ "$NETLOG_ENABLED" -eq 1 ]]; then
  cat <<EOF

Session NetLog is recording. Browse the full workflow matrix, refresh freely,
then quit Chrome (close all windows) to finalize the log. Summarize with:

  python3 "$(dirname "$0")/summarize-netlog-origins.py" \\
    --netlog "$NETLOG_PATH" \\
    --allow-host "$KAMIWAZA_HOST" \\
    --allow-host localhost \\
    --allow-host 127.0.0.1
EOF
fi

exec "$CHROME_BIN" "${CHROME_ARGS[@]}" "$KAMIWAZA_URL"
