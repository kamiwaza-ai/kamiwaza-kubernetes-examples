#!/usr/bin/env bash
set -euo pipefail

TABLE="kamiwaza_airgap"
ACTION="${1:-}"
if [[ $# -gt 0 ]]; then
  shift
fi

usage() {
  cat <<'EOF'
Usage:
  client-lockdown-nft.sh apply --kamiwaza-ip IP [options]
  client-lockdown-nft.sh remove
  client-lockdown-nft.sh status

Options for apply:
  --kamiwaza-ip IP       Kamiwaza IP to allow on TCP 443. May be repeated.
  --kamiwaza-host HOST   Hostname recorded in output for operator clarity.
  --port PORT            Kamiwaza TCP port. Default: 443
  --dns-ip IP            Internal DNS resolver to allow on TCP/UDP 53. May be repeated.
  --allow-ip IP          Additional approved IP to allow all outbound traffic to. May be repeated.
  --ttl-minutes N        Schedule automatic removal after N minutes.
  --dry-run              Print the generated nftables rules without applying them.
  -h, --help             Show this help.

This script only manages table inet/kamiwaza_airgap. It is intended for a
disposable Linux client VM.
EOF
}

if [[ -z "$ACTION" || "$ACTION" == "-h" || "$ACTION" == "--help" ]]; then
  usage
  exit 0
fi

require_nft() {
  if ! command -v nft >/dev/null 2>&1; then
    echo "nft command not found" >&2
    exit 1
  fi
}

run_nft() {
  if [[ "${DRY_RUN:-0}" == "1" ]]; then
    printf '+ nft %s\n' "$*"
  else
    sudo nft "$@"
  fi
}

addr_family() {
  if [[ "$1" == *:* ]]; then
    printf 'ip6'
  else
    printf 'ip'
  fi
}

case "$ACTION" in
  remove)
    require_nft
    sudo nft "delete table inet $TABLE" 2>/dev/null || true
    echo "removed nftables table inet/$TABLE"
    ;;
  status)
    require_nft
    sudo nft "list table inet $TABLE"
    ;;
  apply)
    require_nft
    KAMIWAZA_IPS=()
    DNS_IPS=()
    ALLOW_IPS=()
    KAMIWAZA_HOST=""
    PORT="443"
    TTL_MINUTES="0"
    DRY_RUN="0"

    while [[ $# -gt 0 ]]; do
      case "$1" in
        --kamiwaza-ip)
          KAMIWAZA_IPS+=("${2:?missing value for --kamiwaza-ip}")
          shift 2
          ;;
        --kamiwaza-host)
          KAMIWAZA_HOST="${2:?missing value for --kamiwaza-host}"
          shift 2
          ;;
        --port)
          PORT="${2:?missing value for --port}"
          shift 2
          ;;
        --dns-ip)
          DNS_IPS+=("${2:?missing value for --dns-ip}")
          shift 2
          ;;
        --allow-ip)
          ALLOW_IPS+=("${2:?missing value for --allow-ip}")
          shift 2
          ;;
        --ttl-minutes)
          TTL_MINUTES="${2:?missing value for --ttl-minutes}"
          shift 2
          ;;
        --dry-run)
          DRY_RUN="1"
          shift
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

    if [[ "${#KAMIWAZA_IPS[@]}" -eq 0 ]]; then
      echo "apply requires at least one --kamiwaza-ip" >&2
      exit 2
    fi
    if ! [[ "$TTL_MINUTES" =~ ^[0-9]+$ ]]; then
      echo "--ttl-minutes must be a non-negative integer" >&2
      exit 2
    fi

    RULES="$(mktemp)"
    trap 'rm -f "$RULES"' EXIT

    {
      echo "table inet $TABLE {"
      echo "  chain output {"
      echo "    type filter hook output priority 0; policy drop;"
      echo "    oif lo accept"
      echo "    ct state established,related accept"
      for ip in "${KAMIWAZA_IPS[@]}"; do
        family="$(addr_family "$ip")"
        echo "    $family daddr $ip tcp dport $PORT accept"
      done
      for ip in "${DNS_IPS[@]}"; do
        family="$(addr_family "$ip")"
        echo "    $family daddr $ip udp dport 53 accept"
        echo "    $family daddr $ip tcp dport 53 accept"
      done
      for ip in "${ALLOW_IPS[@]}"; do
        family="$(addr_family "$ip")"
        echo "    $family daddr $ip accept"
      done
      echo "  }"
      echo "}"
    } > "$RULES"

    echo "Applying client egress lock-down"
    if [[ -n "$KAMIWAZA_HOST" ]]; then
      echo "Kamiwaza host: $KAMIWAZA_HOST"
    fi
    echo "Kamiwaza IPs: ${KAMIWAZA_IPS[*]}"
    echo "Kamiwaza port: $PORT"
    echo "DNS IPs: ${DNS_IPS[*]:-(none)}"
    echo "Additional allow IPs: ${ALLOW_IPS[*]:-(none)}"
    echo

    if [[ "$DRY_RUN" == "1" ]]; then
      cat "$RULES"
      exit 0
    fi

    sudo nft "delete table inet $TABLE" 2>/dev/null || true
    sudo nft -f "$RULES"
    sudo nft "list table inet $TABLE"

    if [[ "$TTL_MINUTES" != "0" ]]; then
      sudo sh -c "nohup sh -c 'sleep $((TTL_MINUTES * 60)); nft delete table inet $TABLE' >/tmp/kamiwaza-airgap-nft-ttl.log 2>&1 &"
      echo "scheduled automatic removal after ${TTL_MINUTES} minutes"
    fi
    ;;
  *)
    echo "unknown action: $ACTION" >&2
    usage >&2
    exit 2
    ;;
esac
