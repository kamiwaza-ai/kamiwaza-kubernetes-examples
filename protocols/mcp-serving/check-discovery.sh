#!/usr/bin/env bash
# Prove an MCP client can find its way in: the refusal names a metadata
# document, the document exists, and it names an authorization server.
#
#   ./check-discovery.sh https://kamiwaza.example /v1
#   ./check-discovery.sh https://kamiwaza.example /runtime/tools/kamiwaza-mcp
#
# Exits non-zero at the first broken link in the chain, naming which one broke.
set -euo pipefail

BASE=${1:?usage: check-discovery.sh <https://domain> <resource path> [probe path]}
RESOURCE=${2:?usage: check-discovery.sh <https://domain> <resource path> [probe path]}
PROBE=${3:-$RESOURCE}

CURL=(curl --silent --show-error --max-time 15)

echo "== 1. unauthenticated call to ${BASE}${PROBE}"
headers=$("${CURL[@]}" --dump-header - --output /dev/null "${BASE}${PROBE}")
status=$(printf '%s' "$headers" | awk 'toupper($1) ~ /^HTTP/ {print $2}' | tail -1)
challenge=$(printf '%s' "$headers" |
  awk 'BEGIN{IGNORECASE=1} /^www-authenticate:/ {sub(/^[^:]*:[ ]*/, ""); print}' |
  tr -d '\r')

if [ "$status" != "401" ]; then
  echo "FAIL: expected 401 from an unauthenticated call, got ${status:-no status}." >&2
  echo "      A path that does not require a token has nothing to discover." >&2
  exit 1
fi
if [ -z "$challenge" ]; then
  echo "FAIL: the 401 carries no WWW-Authenticate header." >&2
  echo "      RFC 6750 section 3 requires it, and an MCP client starts here." >&2
  exit 1
fi
echo "   challenge: $challenge"

metadata_url=$(printf '%s' "$challenge" |
  sed -n 's/.*resource_metadata="\([^"]*\)".*/\1/p')
if [ -z "$metadata_url" ]; then
  echo "FAIL: the challenge names no resource_metadata." >&2
  echo "      RFC 9728 section 5.1 puts the document location here." >&2
  exit 1
fi

echo "== 2. metadata document at $metadata_url"
document=$("${CURL[@]}" --fail "$metadata_url") || {
  echo "FAIL: the challenge points at a document that does not answer." >&2
  exit 1
}
printf '   %s\n' "$document"

resource=$(printf '%s' "$document" | sed -n 's/.*"resource"[ ]*:[ ]*"\([^"]*\)".*/\1/p')
issuer=$(printf '%s' "$document" |
  sed -n 's/.*"authorization_servers"[ ]*:[ ]*\[[ ]*"\([^"]*\)".*/\1/p')

if [ -z "$issuer" ]; then
  echo "FAIL: the document names no authorization server, so discovery ends here." >&2
  exit 1
fi
if [ "$resource" != "${BASE}${RESOURCE}" ]; then
  echo "FAIL: document describes ${resource:-nothing}, expected ${BASE}${RESOURCE}." >&2
  echo "      A client would ask for a token bound to the wrong resource." >&2
  exit 1
fi

echo "== 3. authorization server metadata at $issuer"
"${CURL[@]}" --fail "${issuer%/}/.well-known/openid-configuration" >/dev/null || {
  echo "FAIL: the named authorization server publishes no discovery document." >&2
  exit 1
}

echo
echo "PASS: ${BASE}${RESOURCE} is discoverable — challenge, metadata, issuer all agree."
