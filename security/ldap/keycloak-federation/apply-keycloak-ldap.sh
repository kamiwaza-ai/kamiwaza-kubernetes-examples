#!/usr/bin/env bash
# Apply declarative LDAP user federation to Keycloak (idempotent).
#
# Requires: bash, curl, jq
#
# Defaults (export before running to override):
#   KEYCLOAK_URL              https://kamiwaza.test
#   KEYCLOAK_ADMIN_PASSWORD   from kubectl secret kamiwaza/keycloak-admin when unset and kubectl works
#   LDAP_BIND_PASSWORD        from kubectl secret ldap/openldap-secret when unset and kubectl works
#
# Optional:
#   KEYCLOAK_ADMIN            default admin
#   KEYCLOAK_TOKEN_REALM      default master
#   KEYCLOAK_INSECURE_TLS=1   skip TLS verify (local dev when CA is not in system trust store)
#
# Usage:
#   ./apply-keycloak-ldap.sh
#   # or
#   export KEYCLOAK_URL=https://other.example
#   export KEYCLOAK_INSECURE_TLS=1
#   ./apply-keycloak-ldap.sh

set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=/dev/null
source "${ROOT}/keycloak-declarative-common.sh"

kc_decl_load_env apply

require_cmd curl
require_cmd jq
load_manifest

print_zero_sync_hint() {
  local sync_json="$1"
  local added updated
  added="$(echo "$sync_json" | jq -r '.added // 0')"
  updated="$(echo "$sync_json" | jq -r '.updated // 0')"
  [[ $added == "0" && $updated == "0" ]] || return 0
  cat <<EOF >&2

  note: sync reported 0 imported / 0 updated users. Common causes:
    - LDAP has no users under ou=people yet (wait for ldap-bootstrap-import Job, or ldapadd ldap-samples/bootstrap.ldif from security/ldap per docs/OPERATOR_GUIDE.md).
    - OpenLDAP is not in this cluster (expect openldap.ldap.svc.cluster.local).
    - User DN / object classes do not match the LDAP provider (see ldap-provider.json).

  Quick LDAP check (needs kubectl + ldap namespace + LDAP_BIND_PASSWORD):
EOF
  if command -v kubectl >/dev/null 2>&1 && [[ -n ${LDAP_BIND_PASSWORD:-} ]]; then
    echo '    kubectl exec -n ldap deploy/openldap -- ldapsearch -x \' >&2
    echo '      -H ldap://127.0.0.1:389 \' >&2
    echo '      -D "cn=admin,dc=kamiwaza,dc=local" -w "<from openldap-secret>" \' >&2
    echo '      -b "ou=people,dc=kamiwaza,dc=local" "(objectClass=inetOrgPerson)" dn' >&2
    echo >&2
    echo "  diagnostic (live):" >&2
    if kubectl exec -n ldap deploy/openldap -- ldapsearch -x \
      -H ldap://127.0.0.1:389 \
      -D "cn=admin,dc=kamiwaza,dc=local" \
      -w "$LDAP_BIND_PASSWORD" \
      -b "ou=people,dc=kamiwaza,dc=local" \
      "(objectClass=inetOrgPerson)" dn 2>/dev/null | head -40 >&2; then
      :
    else
      echo "  (ldapsearch failed — check deploy/openldap in namespace ldap.)" >&2
    fi
  else
    echo "    (kubectl or LDAP_BIND_PASSWORD unavailable; set password or run kubectl from this host.)" >&2
  fi
}

echo "Applying Keycloak LDAP federation from ${DECL_ROOT} (realm: $(realm_name))..."
echo "  KEYCLOAK_URL=${KEYCLOAK_URL}"

TOKEN="$(get_access_token)"
RID="$(realm_internal_id "$TOKEN")"
LDAP_NAME="$(ldap_provider_name)"
LDAP_CID="$(find_ldap_component_id "$TOKEN" "$RID")"

if [[ -n $LDAP_CID ]]; then
  echo "  updating LDAP provider: ${LDAP_NAME} (${LDAP_CID})"
  EXISTING="$(kc_curl -sS -f "$(kc_admin_api)/realms/$(realm_name)/components/${LDAP_CID}" \
    -H "Authorization: Bearer ${TOKEN}")"
  PW="$(ldap_bind_password)"
  MERGED="$(merge_ldap_config "$EXISTING" "$PW")"
  kc_curl -sS -f -X PUT "$(kc_admin_api)/realms/$(realm_name)/components/${LDAP_CID}" \
    -H "Authorization: Bearer ${TOKEN}" \
    -H "Content-Type: application/json" \
    -d "$MERGED" >/dev/null
else
  echo "  creating LDAP provider: ${LDAP_NAME}"
  BODY="$(build_ldap_component_body "$RID")"
  kc_curl -sS -f -X POST "$(kc_admin_api)/realms/$(realm_name)/components" \
    -H "Authorization: Bearer ${TOKEN}" \
    -H "Content-Type: application/json" \
    -d "$BODY" >/dev/null
  LDAP_CID="$(find_ldap_component_id "$TOKEN" "$RID")"
  [[ -n $LDAP_CID ]] || {
    echo "error: LDAP provider created but component id not found" >&2
    exit 1
  }
fi

ensure_top_level_groups_from_manifest "$TOKEN"

_mapper_count="$(jq '.mappers | length' "$_MNF")"
echo "  applying ${_mapper_count} user federation mapper(s) (includes group-ldap-mapper for LDAP groups → Keycloak groups)..."
while IFS= read -r row; do
  [[ -z $row ]] && continue
  f="$(echo "$row" | jq -r .file)"
  apply_mapper "$TOKEN" "$LDAP_CID" "$f"
done < <(jq -c '.mappers[]' "$_MNF")

# One-time cleanup: earlier declarative versions created a duplicate firstName mapper
# named "ldap-attribute-givenName". Keep only the canonical "first name" mapper.
LEGACY_GIVEN_NAME_MAPPER_ID="$(find_mapper_component_id "$TOKEN" "$LDAP_CID" "ldap-attribute-givenName")"
if [[ -n $LEGACY_GIVEN_NAME_MAPPER_ID ]]; then
  kc_curl -sS -f -X DELETE "$(kc_admin_api)/realms/$(realm_name)/components/${LEGACY_GIVEN_NAME_MAPPER_ID}" \
    -H "Authorization: Bearer ${TOKEN}" >/dev/null
  echo "  removed legacy mapper: ldap-attribute-givenName"
fi

verify_federation_mappers_present "$TOKEN" "$LDAP_CID" || exit 1

echo "  applying declared group->realm role mappings..."
apply_declared_group_role_mappings "$TOKEN"
verify_declared_group_role_mappings "$TOKEN" || exit 1

if [[ "$(mnf '.apply.sync_after_apply // true')" == "true" ]]; then
  echo "  running user sync ($(mnf '.apply.sync_action // "triggerFullSync"'))..."
  SYNC_JSON="$(run_full_sync "$TOKEN" "$LDAP_CID")"
  echo "$SYNC_JSON" | jq .
  print_zero_sync_hint "$SYNC_JSON"
fi

echo "Done."
