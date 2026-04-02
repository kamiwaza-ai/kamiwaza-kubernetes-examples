#!/usr/bin/env bash
# Revert declarative LDAP user federation (removes only resources described in manifest.json).
#
# Order: group->role mappings listed in manifest -> LDAP mappers listed in manifest
# -> optional remove-imported-users -> LDAP provider.
#
# Requires: bash, curl, jq
#
# Defaults (override by exporting):
#   KEYCLOAK_URL              https://kamiwaza.test
#   KEYCLOAK_ADMIN_PASSWORD   from kubectl secret kamiwaza/keycloak-admin when unset
#
# Optional:
#   REVERT_SKIP_REMOVE_IMPORTED_USERS=1   skip POST .../remove-imported-users
#   KEYCLOAK_INSECURE_TLS=1                 skip TLS verify (local dev)
#
# Usage:
#   ./revert-keycloak-ldap.sh

set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=/dev/null
source "${ROOT}/keycloak-declarative-common.sh"

kc_decl_load_env revert

require_cmd curl
require_cmd jq
load_manifest

echo "Reverting Keycloak LDAP federation from ${DECL_ROOT} (realm: $(realm_name))..."
echo "  KEYCLOAK_URL=${KEYCLOAK_URL}"

TOKEN="$(get_access_token)"
RID="$(realm_internal_id "$TOKEN")"
LDAP_CID="$(find_ldap_component_id "$TOKEN" "$RID")"

echo "  removing declared group->realm role mappings (non-destructive to unrelated mappings)..."
remove_declared_group_role_mappings "$TOKEN"

if [[ -z $LDAP_CID ]]; then
  echo "  LDAP provider '$(ldap_provider_name)' not found; nothing to revert."
  exit 0
fi

# Delete mappers (children first). Reverse index loop for bash 3.2 (no mapfile).
_mapper_len="$(jq '.mappers | length' "$_MNF")"
for ((idx = _mapper_len - 1; idx >= 0; idx--)); do
  row="$(jq -c ".mappers[${idx}]" "$_MNF")"
  mname="$(echo "$row" | jq -r .name)"
  mid="$(find_mapper_component_id "$TOKEN" "$LDAP_CID" "$mname")"
  if [[ -n $mid ]]; then
    kc_curl -sS -f -X DELETE "$(kc_admin_api)/realms/$(realm_name)/components/${mid}" \
      -H "Authorization: Bearer ${TOKEN}" >/dev/null
    echo "  deleted mapper: ${mname} (${mid})"
  else
    echo "  mapper not present: ${mname}"
  fi
done

if [[ ${REVERT_SKIP_REMOVE_IMPORTED_USERS:-} == "1" ]]; then
  echo "  skipping remove-imported-users (REVERT_SKIP_REMOVE_IMPORTED_USERS=1)"
elif [[ "$(mnf '.revert.remove_imported_users_before_delete // true')" == "true" ]]; then
  echo "  removing users imported from this provider..."
  if ! kc_curl -sS -f -X POST \
    "$(kc_admin_api)/realms/$(realm_name)/user-storage/${LDAP_CID}/remove-imported-users" \
    -H "Authorization: Bearer ${TOKEN}" \
    -H "Content-Type: application/json" \
    -d '{}' >/dev/null; then
    echo "  warning: remove-imported-users failed (provider may not support it or already empty); continuing" >&2
  fi
fi

kc_curl -sS -f -X DELETE "$(kc_admin_api)/realms/$(realm_name)/components/${LDAP_CID}" \
  -H "Authorization: Bearer ${TOKEN}" >/dev/null
echo "  deleted LDAP provider: $(ldap_provider_name) (${LDAP_CID})"
echo "Done."
