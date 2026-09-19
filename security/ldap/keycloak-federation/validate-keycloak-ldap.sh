#!/usr/bin/env bash
# Validate Keycloak LDAP federation matches manifest (post-apply checks).
#
# Requires: bash, curl, jq
# Uses same env as apply-keycloak-ldap.sh (KEYCLOAK_URL, KEYCLOAK_ADMIN_PASSWORD, etc.)
#
# Usage:
#   ./validate-keycloak-ldap.sh
#   KEYCLOAK_URL=http://keycloak.kamiwaza.svc.cluster.local:8080 ./validate-keycloak-ldap.sh

set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=/dev/null
source "${ROOT}/keycloak-declarative-common.sh"

kc_decl_load_env apply

require_cmd curl
require_cmd jq
load_manifest

echo "Validating Keycloak LDAP federation (realm: $(realm_name))..."
echo "  KEYCLOAK_URL=${KEYCLOAK_URL}"

fail=0

TOKEN="$(get_access_token)"
RID="$(realm_internal_id "$TOKEN")"
LDAP_NAME="$(ldap_provider_name)"
LDAP_CID="$(find_ldap_component_id "$TOKEN" "$RID")"

if [[ -z $LDAP_CID ]]; then
  echo "FAIL: LDAP user federation provider not found (expected name: ${LDAP_NAME})" >&2
  exit 1
fi
echo "OK: LDAP provider present — ${LDAP_NAME} (id ${LDAP_CID})"

echo ""
echo "== Realm groups (required for the group role mappings)"
if manifest_has_group_role_mappings; then
  while IFS= read -r gname; do
    [[ -z $gname ]] && continue
    gpath="$(group_path_from_name "$gname")"
    gid="$(find_group_id_by_path "$TOKEN" "$gpath")"
    if [[ -z $gid ]]; then
      echo "FAIL: group missing at path ${gpath} (manifest group_name: ${gname})" >&2
      fail=1
    else
      echo "OK: group ${gpath} (id ${gid})"
    fi
  done < <(jq -r '.group_role_mappings[].group_name' "$_MNF" | sort -u)
else
  echo "  (no group_role_mappings in manifest — skipping)"
fi

echo ""
echo "== User federation mappers"
if verify_federation_mappers_present "$TOKEN" "$LDAP_CID"; then
  while IFS= read -r row; do
    [[ -z $row ]] && continue
    fname="$(echo "$row" | jq -r .file)"
    mname="$(jq -r .name "${DECL_ROOT}/${fname}")"
    echo "OK: mapper ${mname}"
  done < <(jq -c '.mappers[]' "$_MNF")
else
  fail=1
fi

echo ""
echo "== Provider is read-only federation"
LDAP_JSON="$(kc_curl -sS -f "$(kc_admin_api)/realms/$(realm_name)/components/${LDAP_CID}" \
  -H "Authorization: Bearer ${TOKEN}")"
edit_mode="$(echo "$LDAP_JSON" | jq -r '(.config.editMode // [])[0] // empty')"
sync_registrations="$(echo "$LDAP_JSON" | jq -r '(.config.syncRegistrations // [])[0] // empty')"
bind_dn="$(echo "$LDAP_JSON" | jq -r '(.config.bindDn // [])[0] // empty')"
if [[ $edit_mode == "READ_ONLY" ]]; then
  echo "OK: editMode=READ_ONLY (the platform never writes to the directory)"
else
  echo "FAIL: editMode='${edit_mode}' (expected READ_ONLY)" >&2
  fail=1
fi
if [[ $sync_registrations == "false" ]]; then
  echo "OK: syncRegistrations=false (no account is created in the directory)"
else
  echo "FAIL: syncRegistrations='${sync_registrations}' (expected false)" >&2
  fail=1
fi
case "$bind_dn" in
cn=federation-reader,*) echo "OK: bindDn is the read-only federation account" ;;
*) echo "WARN: bindDn='${bind_dn}' is not the read-only federation account" >&2 ;;
esac

echo ""
echo "== Synchronization is bounded"
# A directory read with no page size, no batch size, and no timeouts is
# unbounded: a large or hostile directory can hold the connection open and
# return an arbitrary number of entries. Asserting the bounds here is the point
# of a validator — configuring them and never checking is how they get dropped
# by a later edit without anyone noticing.
for bound in pagination:true batchSizeForSync: connectionTimeout: readTimeout:; do
  key="${bound%%:*}"
  want="${bound#*:}"
  got="$(echo "$LDAP_JSON" | jq -r "(.config.${key} // [])[0] // empty")"
  if [[ -z $got ]]; then
    echo "FAIL: ${key} is unset (synchronization would be unbounded)" >&2
    fail=1
  elif [[ -n $want && $got != "$want" ]]; then
    echo "FAIL: ${key}='${got}' (expected ${want})" >&2
    fail=1
  else
    echo "OK: ${key}=${got}"
  fi
done

echo ""
echo "== Group -> realm role mappings"
if verify_declared_group_role_mappings "$TOKEN"; then
  echo "OK: all declared group->realm role mappings present"
else
  fail=1
fi

echo ""
echo "== Federated user sample (alice — demo user from examples)"
USERS_JSON="$(kc_curl -sS -G "$(kc_admin_api)/realms/$(realm_name)/users" \
  -H "Authorization: Bearer ${TOKEN}" \
  --data-urlencode "username=alice" \
  --data-urlencode "exact=true")"
cnt="$(echo "$USERS_JSON" | jq 'length')"
if [[ $cnt -ge 1 ]]; then
  echo "OK: user 'alice' present in realm ($(echo "$USERS_JSON" | jq -r '.[0].id'))"
  fed="$(echo "$USERS_JSON" | jq -r '.[0].federationLink // empty')"
  if [[ -n $fed ]]; then
    echo "OK: alice has federationLink=${fed}"
  else
    echo "WARN: alice has no federationLink (may be local user or different Keycloak version shape)" >&2
  fi
else
  echo "WARN: user 'alice' not found — ensure the ldap-bootstrap-import Job finished, then run a Keycloak user sync" >&2
fi

echo ""
if command -v kubectl >/dev/null 2>&1; then
  if kubectl get job -n ldap ldap-bootstrap-import >/dev/null 2>&1; then
    echo "== Kubernetes Job ldap-bootstrap-import"
    succeeded="$(kubectl get job -n ldap ldap-bootstrap-import -o jsonpath='{.status.succeeded}' 2>/dev/null || true)"
    if [[ ${succeeded:-0} == "1" ]]; then
      # The Job proves the federation bind account is read-only before it
      # succeeds, so a completed Job is that proof.
      echo "OK: job succeeded (completionTime=$(kubectl get job -n ldap ldap-bootstrap-import -o jsonpath='{.status.completionTime}'))"
    else
      echo "WARN: job .status.succeeded=${succeeded:-unset} (expected 1 when the last run finished cleanly)" >&2
    fi
  fi
fi

if [[ $fail -ne 0 ]]; then
  echo "" >&2
  echo "Validation finished with failures." >&2
  exit 1
fi

echo ""
echo "All validation checks passed."
