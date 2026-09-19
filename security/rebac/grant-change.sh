#!/usr/bin/env bash
# Plan, review, and apply one administrator-automation grant bundle.
#
# The order is the point. `plan` writes a plan to out/ and never mutates
# anything; `diff` renders that saved file for a human to review; `apply` and
# `remove` refuse to run without the digest of a plan that was written. An
# authorization change applied without a diff is one nobody reviewed.
#
# Operations, headers, status codes, and field names come from
# specs/002-identity-transport-runtime/contracts/grant-service.openapi.yaml in
# the platform operator repository. This script implements no policy of its
# own: every decision, every vocabulary check, and every ownership rule belongs
# to the grant service, which is the only writer to the relationship store.
#
# Usage:
#   API_BASE=https://<your platform>/api GRANT_ADMIN_TOKEN=<token> \
#     ./grant-change.sh plan   grant-manifest.example.yaml
#   ./grant-change.sh diff     grant-manifest.example.yaml
#   ./grant-change.sh apply    grant-manifest.example.yaml
#   ./grant-change.sh remove   grant-manifest.example.yaml <entryID> [entryID...]
#   ./grant-change.sh observe  <operationID>
#
# Requires: curl, jq, and either yq or python3 with PyYAML (to send a YAML
# manifest as the JSON body the contract declares).
#
# The bearer token is read from the environment and passed to curl through a
# configuration file on standard input, so it never appears in the process
# arguments any other user on the host can read. It is never written to out/,
# never echoed, and never logged.
set -euo pipefail

API_BASE=${API_BASE:-https://kamiwaza.example.invalid/api}
OUT_DIR=${OUT_DIR:-$(dirname "$0")/out}

die() {
  echo "grant-change: $*" >&2
  exit 1
}

require_tools() {
  command -v curl >/dev/null || die "curl is required"
  command -v jq >/dev/null || die "jq is required"
  [[ -n ${GRANT_ADMIN_TOKEN:-} ]] ||
    die "GRANT_ADMIN_TOKEN is not set; the caller supplies its own token"
}

# The contract's request bodies are JSON. The manifests here are YAML because a
# human reviews them.
manifest_json() {
  local manifest=$1
  if command -v yq >/dev/null; then
    yq -o=json '.' "$manifest"
  elif command -v python3 >/dev/null; then
    python3 -c 'import json,sys,yaml; json.dump(yaml.safe_load(open(sys.argv[1])),sys.stdout)' "$manifest"
  else
    die "install yq, or python3 with PyYAML, to convert $manifest to JSON"
  fi
}

slug() {
  local manifest=$1 body
  body=$(manifest_json "$manifest")
  jq -r '"\(.bundleID)-\(.revision)"' <<<"$body"
}

plan_path() {
  echo "$OUT_DIR/$(slug "$1").plan.json"
}

# One idempotency key per bundle revision and operation, kept on disk. A retry
# of an interrupted apply must reuse its key: a fresh key is a second
# operation, and the contract's replay guarantee only covers the same key.
idempotency_key() {
  local key_file=$1
  if [[ ! -s $key_file ]]; then
    if [[ -r /proc/sys/kernel/random/uuid ]]; then
      tr -d '\n' </proc/sys/kernel/random/uuid >"$key_file"
    elif command -v uuidgen >/dev/null; then
      uuidgen | tr '[:upper:]' '[:lower:]' | tr -d '\n' >"$key_file"
    else
      die "no UUID source found for the mandatory Idempotency-Key header"
    fi
  fi
  cat "$key_file"
}

# Returns the HTTP status code and leaves the response body in $2.
call() {
  local method=$1 body_out=$2 url=$3 request_body=${4:-} idempotency=${5:-}
  local -a args=(-sS -X "$method" -o "$body_out" -w '%{http_code}')
  args+=(-H 'Accept: application/json')
  [[ -n $request_body ]] && args+=(-H 'Content-Type: application/json' --data-binary "@$request_body")
  [[ -n $idempotency ]] && args+=(-H "Idempotency-Key: $idempotency")
  printf 'header = "Authorization: Bearer %s"\n' "$GRANT_ADMIN_TOKEN" |
    curl "${args[@]}" -K - "$url"
}

render_plan() {
  local plan=$1
  echo "sourceRevision: $(jq -r '.sourceRevision' "$plan")"
  echo "planDigest:     $(jq -r '.planDigest' "$plan")"
  echo
  printf '%-44s %-9s %-12s %s\n' ENTRY ACTION OWNERS-AFTER BACKEND-WRITE
  jq -r '.changes[] | [.entryID, .action, (.ownerCount|tostring),
    (if .backendChangeRequired then "yes" else "no" end)] | @tsv' "$plan" |
    while IFS=$'\t' read -r entry action owners backend; do
      printf '%-44s %-9s %-12s %s\n' "$entry" "$action" "$owners" "$backend"
    done
  local blockers
  blockers=$(jq -r '.blockers | length' "$plan")
  if [[ $blockers != 0 ]]; then
    echo
    echo "blockers ($blockers) — nothing is applied while any blocker stands:"
    jq -r '.blockers[] | "  \(.code): \(.message)"' "$plan"
    return 1
  fi
}

cmd_plan() {
  local manifest=${1:?manifest path required} plan code body
  mkdir -p "$OUT_DIR"
  body=$(mktemp)
  manifest_json "$manifest" >"$body"
  plan=$(plan_path "$manifest")
  code=$(call POST "$plan" "$API_BASE/v1/grants/changes:plan" "$body")
  rm -f "$body"
  case $code in
  200) ;;
  404) die "HTTP 404: this platform does not serve the grant contract. A grant is not applied." ;;
  *) die "HTTP $code from :plan — $(jq -r '.code // "no problem document"' "$plan")" ;;
  esac
  echo "plan written: $plan"
  render_plan "$plan"
}

cmd_diff() {
  local plan
  plan=$(plan_path "${1:?manifest path required}")
  [[ -s $plan ]] || die "no plan at $plan; run plan first"
  render_plan "$plan"
}

cmd_apply() {
  local manifest=${1:?manifest path required} plan digest body request code result
  plan=$(plan_path "$manifest")
  [[ -s $plan ]] || die "no plan at $plan; run plan first"
  render_plan "$plan" >/dev/null || die "plan has blockers; fix the manifest and plan again"
  digest=$(jq -r '.planDigest' "$plan")
  body=$(mktemp)
  request=$(mktemp)
  manifest_json "$manifest" >"$body"
  jq -n --slurpfile m "$body" --arg d "$digest" \
    '{manifest: $m[0], approvedPlanDigest: $d}' >"$request"
  result=$OUT_DIR/$(slug "$manifest").apply.json
  code=$(call POST "$result" "$API_BASE/v1/grants/changes:apply" "$request" \
    "$(idempotency_key "$OUT_DIR/$(slug "$manifest").apply-key")")
  rm -f "$body" "$request"
  report_operation "$code" "$result" apply
}

cmd_remove() {
  local manifest=${1:?manifest path required}
  shift
  [[ $# -ge 1 ]] || die "name at least one entryID to release"
  local plan digest request result code manifest_body
  plan=$(plan_path "$manifest")
  [[ -s $plan ]] || die "no plan at $plan; plan the revision that drops these entries first"
  render_plan "$plan" >/dev/null || die "plan has blockers; fix the manifest and plan again"
  digest=$(jq -r '.planDigest' "$plan")
  manifest_body=$(manifest_json "$manifest")
  request=$(mktemp)
  jq -n --arg b "$(jq -r '.bundleID' <<<"$manifest_body")" \
    --arg r "$(jq -r '.revision' <<<"$manifest_body")" \
    --arg d "$digest" --args \
    '{bundleID: $b, revision: $r, approvedPlanDigest: $d, entryIDs: $ARGS.positional}' \
    "$@" >"$request"
  result=$OUT_DIR/$(slug "$manifest").remove.json
  code=$(call POST "$result" "$API_BASE/v1/grants/changes:remove" "$request" \
    "$(idempotency_key "$OUT_DIR/$(slug "$manifest").remove-key")")
  rm -f "$request"
  report_operation "$code" "$result" remove
}

report_operation() {
  local code=$1 result=$2 what=$3
  case $code in
  200 | 202)
    echo "$what accepted: operationID $(jq -r '.operationID' "$result"), state $(jq -r '.state' "$result")"
    echo "observe it before treating the change as live:"
    echo "  $0 observe $(jq -r '.operationID' "$result")"
    ;;
  409)
    die "HTTP 409: revision, plan digest, idempotency, principal, or ownership conflict. Nothing was written. Plan again."
    ;;
  503)
    die "HTTP 503: the grant projection or checkpoint is unavailable. The operation is NOT complete."
    ;;
  *)
    die "HTTP $code from :$what — $(jq -r '.code // "no problem document"' "$result")"
    ;;
  esac
}

# A change is live when the operation reports Succeeded with a checkpoint. Any
# other state, and any failure to read the operation at all, means a caller
# must not assume the new access is in effect yet.
cmd_observe() {
  local operation=${1:?operationID required} result code state
  mkdir -p "$OUT_DIR"
  result=$OUT_DIR/operation-$operation.json
  code=$(call GET "$result" "$API_BASE/v1/grants/operations/$operation")
  [[ $code == 200 ]] || die "HTTP $code reading operation $operation; the change cannot be treated as live"
  state=$(jq -r '.state' "$result")
  echo "state: $state"
  printf '%-44s %-9s %-12s %s\n' ENTRY ACTION OWNERS-AFTER EDGE-STATE
  jq -r '.edgeOutcomes[] | [.entryID, .action, (.ownerCount|tostring), .state] | @tsv' "$result" |
    while IFS=$'\t' read -r entry action owners edge_state; do
      printf '%-44s %-9s %-12s %s\n' "$entry" "$action" "$owners" "$edge_state"
    done
  local observed
  observed=$(jq -r '.checkpoint.observedAt // empty' "$result")
  if [[ $state == Succeeded && -n $observed ]]; then
    echo "checkpoint observed at $observed; the change is live"
    return 0
  fi
  echo "no observed checkpoint for state $state; do not treat this change as live" >&2
  jq -r '.problem | select(. != null) | "problem \(.code): \(.message)"' "$result" >&2
  return 2
}

main() {
  require_tools
  local command=${1:-}
  shift || true
  case $command in
  plan) cmd_plan "$@" ;;
  diff) cmd_diff "$@" ;;
  apply) cmd_apply "$@" ;;
  remove) cmd_remove "$@" ;;
  observe) cmd_observe "$@" ;;
  *) die "usage: $0 {plan|diff|apply|remove|observe} ..." ;;
  esac
}

main "$@"
