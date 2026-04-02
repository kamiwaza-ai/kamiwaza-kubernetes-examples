# shellcheck shell=bash
# Shared helpers for apply-keycloak-ldap.sh and revert-keycloak-ldap.sh.
# Requires: bash, curl, jq

set -euo pipefail

DECL_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
export DECL_ROOT

manifest_path() {
  echo "${DECL_ROOT}/manifest.json"
}

load_manifest() {
  local mf
  mf="$(manifest_path)"
  [[ -f $mf ]] || {
    echo "error: missing ${mf}" >&2
    exit 1
  }
  export _MNF="$mf"
}

mnf() {
  jq -r "$1" "$_MNF"
}

require_cmd() {
  command -v "$1" >/dev/null 2>&1 || {
    echo "error: required command not found: $1" >&2
    exit 1
  }
}

# Wrap curl for optional TLS skip (local dev: cert-manager / mkcert not in system trust store).
# Set KEYCLOAK_INSECURE_TLS=1 only when you accept MITM risk (e.g. https://kamiwaza.test from your laptop).
kc_curl() {
  local insecure=()
  case "${KEYCLOAK_INSECURE_TLS:-}" in
  1 | true | TRUE | yes | YES) insecure=(-k) ;;
  esac
  curl "${insecure[@]}" "$@"
}

# Defaults for local Kamiwaza Kind stack. Override by exporting before running the script.
# mode: "apply" also fills LDAP_BIND_PASSWORD from kubectl when unset.
kc_decl_load_env() {
  local mode="${1:-apply}"
  export KEYCLOAK_URL="${KEYCLOAK_URL:-https://kamiwaza.test}"
  # Local dev hostname: curl usually lacks the cluster CA; skip verify unless caller set explicitly.
  if [[ -z ${KEYCLOAK_INSECURE_TLS+x} ]]; then
    case "$KEYCLOAK_URL" in *kamiwaza.test*) export KEYCLOAK_INSECURE_TLS=1 ;; esac
  fi
  if [[ -z ${KEYCLOAK_ADMIN_PASSWORD:-} ]] && command -v kubectl >/dev/null 2>&1; then
    local pw
    pw="$(kubectl get secret -n kamiwaza keycloak-admin -o jsonpath='{.data.password}' 2>/dev/null | base64 -d || true)"
    [[ -n $pw ]] && export KEYCLOAK_ADMIN_PASSWORD="$pw"
  fi
  if [[ $mode == "apply" ]] && [[ -z ${LDAP_BIND_PASSWORD:-} ]] && command -v kubectl >/dev/null 2>&1; then
    local lb
    lb="$(kubectl get secret -n ldap openldap-secret -o jsonpath='{.data.admin-password}' 2>/dev/null | base64 -d || true)"
    [[ -n $lb ]] && export LDAP_BIND_PASSWORD="$lb"
  fi
}

# Base URL with no trailing slash (e.g. https://kamiwaza.test)
kc_admin_base() {
  local u="${KEYCLOAK_URL:-}"
  u="${u%/}"
  [[ -n $u ]] || {
    echo "error: KEYCLOAK_URL is not set (example: https://kamiwaza.test)" >&2
    exit 1
  }
  echo "$u"
}

kc_token_url() {
  local realm="${KEYCLOAK_TOKEN_REALM:-master}"
  echo "$(kc_admin_base)/realms/${realm}/protocol/openid-connect/token"
}

kc_admin_api() {
  echo "$(kc_admin_base)/admin"
}

get_access_token() {
  local user pass
  user="${KEYCLOAK_ADMIN:-admin}"
  pass="${KEYCLOAK_ADMIN_PASSWORD:-}"
  [[ -n $pass ]] || {
    echo "error: KEYCLOAK_ADMIN_PASSWORD is not set" >&2
    exit 1
  }
  local resp
  resp="$(kc_curl -sS -X POST "$(kc_token_url)" \
    -H "Content-Type: application/x-www-form-urlencoded" \
    -d "client_id=admin-cli" \
    -d "username=${user}" \
    -d "password=${pass}" \
    -d "grant_type=password")"
  local tok
  tok="$(echo "$resp" | jq -r '.access_token // empty')"
  [[ -n $tok && $tok != "null" ]] || {
    echo "error: failed to obtain admin access_token (check URL, realm, and credentials)" >&2
    echo "$resp" | jq . >&2 2>/dev/null || echo "$resp" >&2
    exit 1
  }
  echo "$tok"
}

realm_name() {
  mnf '.realm'
}

realm_internal_id() {
  local token="$1"
  kc_curl -sS -f "$(kc_admin_api)/realms/$(realm_name)" \
    -H "Authorization: Bearer ${token}" | jq -r .id
}

ldap_provider_name() {
  mnf '.ldap_provider.name'
}

ldap_provider_type() {
  mnf '.ldap_provider.provider_type'
}

find_ldap_component_id() {
  local token="$1" realm_id="$2"
  local name
  name="$(ldap_provider_name)"
  kc_curl -sS -f -G "$(kc_admin_api)/realms/$(realm_name)/components" \
    -H "Authorization: Bearer ${token}" \
    --data-urlencode "parent=${realm_id}" \
    --data-urlencode "type=$(ldap_provider_type)" |
    jq -r --arg n "$name" '.[] | select(.name == $n) | .id' | head -1
}

find_mapper_component_id() {
  local token="$1" ldap_cid="$2" mname="$3"
  kc_curl -sS -f -G "$(kc_admin_api)/realms/$(realm_name)/components" \
    -H "Authorization: Bearer ${token}" \
    --data-urlencode "parent=${ldap_cid}" \
    --data-urlencode "type=org.keycloak.storage.ldap.mappers.LDAPStorageMapper" |
    jq -r --arg n "$mname" '.[] | select(.name == $n) | .id' | head -1
}

ldap_bind_password() {
  local p="${LDAP_BIND_PASSWORD:-}"
  [[ -n $p ]] || {
    echo "error: LDAP_BIND_PASSWORD is not set (OpenLDAP admin bind password)" >&2
    exit 1
  }
  echo "$p"
}

build_ldap_component_body() {
  local realm_id="$1"
  local cfg_file
  cfg_file="${DECL_ROOT}/$(jq -r '.ldap_provider.config_file' "$_MNF")"
  [[ -f $cfg_file ]] || {
    echo "error: missing ldap config file: ${cfg_file}" >&2
    exit 1
  }
  local pw
  pw="$(ldap_bind_password)"
  jq --arg pid "$realm_id" --arg pw "$pw" \
    '. + {parentId: $pid} | .config += {bindCredential: [$pw]}' \
    "$cfg_file"
}

merge_ldap_config() {
  local existing_json="$1"
  local pw="$2"
  local cfg_file
  cfg_file="${DECL_ROOT}/$(jq -r '.ldap_provider.config_file' "$_MNF")"
  local desired_cfg
  desired_cfg="$(jq --arg pw "$pw" '.config += {bindCredential: [$pw]} | .config' "$cfg_file")"
  echo "$existing_json" | jq --argjson dc "$desired_cfg" '.config = $dc'
}

verify_federation_mappers_present() {
  local token="$1" ldap_cid="$2"
  local missing=0
  local row fname mname mid
  while IFS= read -r row; do
    [[ -z $row ]] && continue
    fname="$(echo "$row" | jq -r .file)"
    mname="$(jq -r .name "${DECL_ROOT}/${fname}")"
    mid="$(find_mapper_component_id "$token" "$ldap_cid" "$mname")"
    if [[ -z $mid ]]; then
      echo "error: federation mapper not found in Keycloak after apply: ${mname} (${fname})" >&2
      missing=1
    fi
  done < <(jq -c '.mappers[]' "$_MNF")
  return "$missing"
}

apply_mapper() {
  local token="$1" ldap_cid="$2" mapper_file_rel="$3"
  local path="${DECL_ROOT}/${mapper_file_rel}"
  [[ -f $path ]] || {
    echo "error: missing mapper file: ${path}" >&2
    exit 1
  }
  local mname
  mname="$(jq -r .name "$path")"
  echo "  applying federation mapper: ${mname} (${mapper_file_rel})"
  local existing_id
  existing_id="$(find_mapper_component_id "$token" "$ldap_cid" "$mname")"
  local body
  body="$(jq --arg pid "$ldap_cid" '. + {parentId: $pid}' "$path")"
  if [[ -n $existing_id ]]; then
    local current merged
    current="$(kc_curl -sS -f "$(kc_admin_api)/realms/$(realm_name)/components/${existing_id}" \
      -H "Authorization: Bearer ${token}")"
    merged="$(echo "$current" | jq --argjson d "$body" \
      '.name = $d.name | .providerId = $d.providerId | .providerType = $d.providerType | .parentId = $d.parentId | .config = $d.config')"
    kc_curl -sS -f -X PUT "$(kc_admin_api)/realms/$(realm_name)/components/${existing_id}" \
      -H "Authorization: Bearer ${token}" \
      -H "Content-Type: application/json" \
      -d "$merged" >/dev/null
    echo "  updated mapper: ${mname}"
  else
    kc_curl -sS -f -X POST "$(kc_admin_api)/realms/$(realm_name)/components" \
      -H "Authorization: Bearer ${token}" \
      -H "Content-Type: application/json" \
      -d "$body" >/dev/null
    echo "  created mapper: ${mname}"
  fi
}

run_full_sync() {
  local token="$1" ldap_cid="$2"
  local action
  action="$(mnf '.apply.sync_action // "triggerFullSync"')"
  kc_curl -sS -f -X POST \
    "$(kc_admin_api)/realms/$(realm_name)/user-storage/${ldap_cid}/sync?action=${action}" \
    -H "Authorization: Bearer ${token}" \
    -H "Content-Type: application/json" \
    -d '{}'
}

manifest_has_group_role_mappings() {
  [[ "$(jq 'has("group_role_mappings") and (.group_role_mappings | type == "array") and (.group_role_mappings | length > 0)' "$_MNF")" == "true" ]]
}

group_path_from_name() {
  local name="$1"
  if [[ $name == /* ]]; then
    echo "$name"
  else
    echo "/${name}"
  fi
}

find_group_id_by_path() {
  local token="$1" group_path="$2"
  local enc
  enc="$(jq -rn --arg v "$group_path" '$v|@uri')"
  local resp
  resp="$(kc_curl -sS "$(kc_admin_api)/realms/$(realm_name)/group-by-path/${enc}" \
    -H "Authorization: Bearer ${token}" || true)"
  echo "$resp" | jq -r '.id // empty' 2>/dev/null || true
}

# hardcoded-ldap-group-mapper and group-by-path role mappings require these groups to exist.
ensure_top_level_group() {
  local token="$1" gname="$2"
  local gpath
  gpath="$(group_path_from_name "$gname")"
  if [[ -n "$(find_group_id_by_path "$token" "$gpath")" ]]; then
    echo "  realm group ok: ${gpath}"
    return 0
  fi
  echo "  creating realm group: ${gpath} (required for LDAP mappers / group_role_mappings)"
  kc_curl -sS -f -X POST "$(kc_admin_api)/realms/$(realm_name)/groups" \
    -H "Authorization: Bearer ${token}" \
    -H "Content-Type: application/json" \
    -d "$(jq -nc --arg n "$gname" '{name: $n}')" >/dev/null
}

ensure_top_level_groups_from_manifest() {
  local token="$1"
  manifest_has_group_role_mappings || return 0
  local gname
  while IFS= read -r gname; do
    [[ -z $gname ]] && continue
    ensure_top_level_group "$token" "$gname"
  done < <(jq -r '.group_role_mappings[].group_name' "$_MNF" | sort -u)
}

find_realm_role_representation_by_name() {
  local token="$1" role_name="$2"
  local enc
  enc="$(jq -rn --arg v "$role_name" '$v|@uri')"
  local resp
  resp="$(kc_curl -sS "$(kc_admin_api)/realms/$(realm_name)/roles/${enc}" \
    -H "Authorization: Bearer ${token}" || true)"
  if [[ "$(echo "$resp" | jq -r '.name // empty' 2>/dev/null || true)" == "$role_name" ]]; then
    echo "$resp"
  fi
}

ensure_group_has_realm_role() {
  local token="$1" group_name="$2" role_name="$3"
  local gpath gid role_rep role_id has_role
  gpath="$(group_path_from_name "$group_name")"
  gid="$(find_group_id_by_path "$token" "$gpath")"
  [[ -n $gid ]] || {
    echo "error: Keycloak group not found for mapping: ${group_name} (path ${gpath})" >&2
    return 1
  }
  role_rep="$(find_realm_role_representation_by_name "$token" "$role_name")"
  role_id="$(echo "$role_rep" | jq -r '.id // empty')"
  [[ -n $role_id ]] || {
    echo "error: required realm role missing: ${role_name} (mapping ${group_name} -> ${role_name})" >&2
    return 1
  }
  has_role="$(kc_curl -sS -f "$(kc_admin_api)/realms/$(realm_name)/groups/${gid}/role-mappings/realm" \
    -H "Authorization: Bearer ${token}" | jq -r --arg rn "$role_name" 'any(.[]; .name == $rn)')"
  if [[ $has_role == "true" ]]; then
    echo "  role mapping already present: ${group_name} -> ${role_name}"
    return 0
  fi
  kc_curl -sS -f -X POST "$(kc_admin_api)/realms/$(realm_name)/groups/${gid}/role-mappings/realm" \
    -H "Authorization: Bearer ${token}" \
    -H "Content-Type: application/json" \
    -d "[${role_rep}]" >/dev/null
  echo "  added role mapping: ${group_name} -> ${role_name}"
}

remove_group_realm_role_mapping_if_present() {
  local token="$1" group_name="$2" role_name="$3"
  local gpath gid role_rep role_id has_role
  gpath="$(group_path_from_name "$group_name")"
  gid="$(find_group_id_by_path "$token" "$gpath")"
  [[ -n $gid ]] || {
    echo "  group not present while removing mapping: ${group_name} (path ${gpath})"
    return 0
  }
  role_rep="$(find_realm_role_representation_by_name "$token" "$role_name")"
  role_id="$(echo "$role_rep" | jq -r '.id // empty')"
  [[ -n $role_id ]] || {
    echo "  role not present while removing mapping: ${role_name}"
    return 0
  }
  has_role="$(kc_curl -sS -f "$(kc_admin_api)/realms/$(realm_name)/groups/${gid}/role-mappings/realm" \
    -H "Authorization: Bearer ${token}" | jq -r --arg rn "$role_name" 'any(.[]; .name == $rn)')"
  [[ $has_role == "true" ]] || {
    echo "  role mapping not present: ${group_name} -> ${role_name}"
    return 0
  }
  kc_curl -sS -f -X DELETE "$(kc_admin_api)/realms/$(realm_name)/groups/${gid}/role-mappings/realm" \
    -H "Authorization: Bearer ${token}" \
    -H "Content-Type: application/json" \
    -d "[${role_rep}]" >/dev/null
  echo "  removed role mapping: ${group_name} -> ${role_name}"
}

apply_declared_group_role_mappings() {
  local token="$1"
  manifest_has_group_role_mappings || {
    echo "  no group->realm role mappings declared in manifest"
    return 0
  }
  local row gname rname
  while IFS= read -r row; do
    [[ -z $row ]] && continue
    gname="$(echo "$row" | jq -r '.group_name')"
    rname="$(echo "$row" | jq -r '.realm_role_name')"
    ensure_group_has_realm_role "$token" "$gname" "$rname"
  done < <(jq -c '.group_role_mappings[]' "$_MNF")
}

verify_declared_group_role_mappings() {
  local token="$1"
  manifest_has_group_role_mappings || return 0
  local missing=0
  local row gname rname gpath gid has_role
  while IFS= read -r row; do
    [[ -z $row ]] && continue
    gname="$(echo "$row" | jq -r '.group_name')"
    rname="$(echo "$row" | jq -r '.realm_role_name')"
    gpath="$(group_path_from_name "$gname")"
    gid="$(find_group_id_by_path "$token" "$gpath")"
    if [[ -z $gid ]]; then
      echo "error: verify failed, group not found: ${gname} (path ${gpath})" >&2
      missing=1
      continue
    fi
    has_role="$(kc_curl -sS -f "$(kc_admin_api)/realms/$(realm_name)/groups/${gid}/role-mappings/realm" \
      -H "Authorization: Bearer ${token}" | jq -r --arg rn "$rname" 'any(.[]; .name == $rn)')"
    if [[ $has_role != "true" ]]; then
      echo "error: verify failed, mapping missing: ${gname} -> ${rname}" >&2
      missing=1
    fi
  done < <(jq -c '.group_role_mappings[]' "$_MNF")
  return "$missing"
}

remove_declared_group_role_mappings() {
  local token="$1"
  manifest_has_group_role_mappings || {
    echo "  no group->realm role mappings declared in manifest"
    return 0
  }
  local row gname rname
  while IFS= read -r row; do
    [[ -z $row ]] && continue
    gname="$(echo "$row" | jq -r '.group_name')"
    rname="$(echo "$row" | jq -r '.realm_role_name')"
    remove_group_realm_role_mapping_if_present "$token" "$gname" "$rname"
  done < <(jq -c '.group_role_mappings[]' "$_MNF")
}
