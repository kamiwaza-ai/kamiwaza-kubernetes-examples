#!/usr/bin/env bash
# Build the `kamiwaza-trust-bundle` ConfigMap WITHOUT trust-manager.
#
# This is the config-only / air-gapped replacement for the trust-manager
# controller. trust-manager did three things; this script does the same three
# with plain `kubectl` + `openssl`:
#
#   1. MERGE  — concatenate the public-CA baseline + platform root-ca + your
#               corporate CA(s) into one additive PEM (deduped by fingerprint).
#   2. CREATE — write ConfigMap `kamiwaza-trust-bundle` (key `ca-certificates.crt`).
#   3. REPLICATE — apply that ConfigMap to every target namespace.
#
# The pod contract is unchanged: `core.trustManager.enabled: true` still mounts
# this exact ConfigMap at /etc/ssl/certs/ca-certificates.crt on scheduler + Ray
# (and the extensions recipe mounts it on extension pods). That Helm value only
# mounts a ConfigMap — it needs no controller. So once this script has created
# the ConfigMap, nothing else about the recipe requires trust-manager.
#
# WHY ADDITIVE: the chart mounts the ConfigMap over the image's system CA file
# with a subPath, i.e. it REPLACES /etc/ssl/certs/ca-certificates.crt. A bundle
# that contained only your corporate CA would therefore break public TLS. So we
# rebuild the full file: public/Mozilla baseline + platform root-ca + your CA.
# (In a sealed air-gap with no public egress you may legitimately not need the
# public baseline — see --no-baseline — but it is included by default to match
# the trust-manager behaviour this replaces.)
#
# Requirements: bash, kubectl (with cluster access), openssl.
#
# Usage:
#   security/tls-trust/build-trust-bundle-configmap.sh --ca-file org-ca.pem
#   security/tls-trust/build-trust-bundle-configmap.sh --ca-file demo-pki/ca-chain.pem
#   security/tls-trust/build-trust-bundle-configmap.sh --ca-file org-ca.pem --include-sandboxes
#   security/tls-trust/build-trust-bundle-configmap.sh --ca-file org-ca.pem --dry-run
#
# After it succeeds: merge trust-bundle-values-snippet.yaml (sets
# core.trustManager.enabled: true) and `helmfile … sync`, OR — if the mount is
# already enabled — roll the pods so the new file is picked up (a subPath mount
# does NOT hot-update; see README "Recovery / rollback").
set -euo pipefail

# ----------------------------------------------------------------------------
# Defaults (the ConfigMap contract — keep in sync with verify.sh + the chart)
# ----------------------------------------------------------------------------
CM_NAME="kamiwaza-trust-bundle"
CM_KEY="ca-certificates.crt"

ROOT_CA_SECRET="root-ca"        # cert-manager-managed platform root CA
ROOT_CA_KEY="ca.crt"
ROOT_CA_NS="kamiwaza"

CUSTOMER_SECRET="kamiwaza-org-ca"   # optional fallback source when no --ca-file
CUSTOMER_SECRET_NS="kamiwaza"

BASELINE_POD="deploy/core-scheduler"   # harvest the public baseline from here
BASELINE_CONTAINER="core"
BASELINE_NS="kamiwaza"
BASELINE_PATH="/etc/ssl/certs/ca-certificates.crt"

DEFAULT_NAMESPACES=(kamiwaza kamiwaza-system kamiwaza-extensions)
SANDBOX_NAMESPACE="kamiwaza-sandboxes"

# ----------------------------------------------------------------------------
# Flag state
# ----------------------------------------------------------------------------
CA_FILES=()
BASELINE_FILE=""
NO_BASELINE=0
NO_ROOT_CA=0
NAMESPACES=()
INCLUDE_SANDBOXES=0
KUBECTL_CONTEXT=""
DRY_RUN=0

err()  { printf '\033[31merror:\033[0m %s\n' "$1" >&2; }
warn() { printf '\033[33mwarn:\033[0m %s\n'  "$1" >&2; }
info() { printf '\033[1m%s\033[0m\n' "$1" >&2; }
die()  { err "$1"; exit 1; }

usage() {
  sed -n '2,40p' "$0" | sed 's/^# \{0,1\}//'
  cat >&2 <<'EOF'

Options:
  --ca-file PATH          Corporate/enterprise CA chain PEM (root + intermediates).
                          Repeatable. If omitted, the Secret kamiwaza-org-ca in ns
                          kamiwaza is used instead (all keys).
  --baseline-file PATH    Use this PEM as the public-CA baseline (deterministic /
                          fully offline). Default: harvest it from a running pod.
  --baseline-pod REF      Pod/workload to harvest the baseline from
                          (default: deploy/core-scheduler, ns kamiwaza).
  --baseline-container C  Container in that pod (default: core).
  --no-baseline           Do NOT include a public baseline. Corporate + root-ca only.
                          WARNING: this breaks public TLS for the mounting pods —
                          only use it for a sealed air-gap with no public egress.
  --no-root-ca            Skip the platform root-ca Secret (rarely wanted; the
                          root CA is what lets pods verify internal platform TLS).
  --namespace NS          Target namespace for the ConfigMap. Repeatable. Replaces
                          the default set (kamiwaza, kamiwaza-system, kamiwaza-extensions).
  --include-sandboxes     Also write to kamiwaza-sandboxes (Kaizen follow-on).
  --configmap-name NAME   ConfigMap name (default: kamiwaza-trust-bundle).
  --context CTX           kubectl --context to use.
  --dry-run               Print the assembled ConfigMap YAML and exit; do not apply.
  -h, --help              This help.
EOF
}

while [ $# -gt 0 ]; do
  case "$1" in
    --ca-file)           CA_FILES+=("${2:?--ca-file needs a path}"); shift 2 ;;
    --baseline-file)     BASELINE_FILE="${2:?--baseline-file needs a path}"; shift 2 ;;
    --baseline-pod)      BASELINE_POD="${2:?--baseline-pod needs a ref}"; shift 2 ;;
    --baseline-container) BASELINE_CONTAINER="${2:?--baseline-container needs a name}"; shift 2 ;;
    --no-baseline)       NO_BASELINE=1; shift ;;
    --no-root-ca)        NO_ROOT_CA=1; shift ;;
    --namespace)         NAMESPACES+=("${2:?--namespace needs a name}"); shift 2 ;;
    --include-sandboxes) INCLUDE_SANDBOXES=1; shift ;;
    --configmap-name)    CM_NAME="${2:?--configmap-name needs a name}"; shift 2 ;;
    --context)           KUBECTL_CONTEXT="${2:?--context needs a name}"; shift 2 ;;
    --dry-run)           DRY_RUN=1; shift ;;
    -h|--help)           usage; exit 0 ;;
    *) err "unknown argument: $1"; usage; exit 2 ;;
  esac
done

command -v kubectl >/dev/null 2>&1 || die "kubectl not found on PATH"
command -v openssl >/dev/null 2>&1 || die "openssl not found on PATH"

kc() { kubectl ${KUBECTL_CONTEXT:+--context "$KUBECTL_CONTEXT"} "$@"; }

# Resolve target namespaces.
if [ "${#NAMESPACES[@]}" -eq 0 ]; then
  NAMESPACES=("${DEFAULT_NAMESPACES[@]}")
fi
if [ "$INCLUDE_SANDBOXES" -eq 1 ]; then
  case " ${NAMESPACES[*]} " in
    *" $SANDBOX_NAMESPACE "*) : ;;
    *) NAMESPACES+=("$SANDBOX_NAMESPACE") ;;
  esac
fi

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
RAW="$WORK/raw.pem"
: > "$RAW"

# ----------------------------------------------------------------------------
# decode a Kubernetes Secret data value (base64) portably
# ----------------------------------------------------------------------------
b64d() { openssl base64 -d -A; }

# ----------------------------------------------------------------------------
# 1. Public / Mozilla baseline (keeps the bundle additive)
# ----------------------------------------------------------------------------
if [ "$NO_BASELINE" -eq 1 ]; then
  warn "--no-baseline: the bundle will contain ONLY your corporate CA(s) + root-ca."
  warn "Pods mounting it will no longer trust public CAs — air-gap only."
elif [ -n "$BASELINE_FILE" ]; then
  [ -r "$BASELINE_FILE" ] || die "baseline file not readable: $BASELINE_FILE"
  info "Baseline: from file $BASELINE_FILE"
  cat "$BASELINE_FILE" >> "$RAW"; printf '\n' >> "$RAW"
else
  info "Baseline: harvesting public CA set from $BASELINE_NS/$BASELINE_POD ($BASELINE_CONTAINER:$BASELINE_PATH)"
  if ! kc -n "$BASELINE_NS" exec "$BASELINE_POD" -c "$BASELINE_CONTAINER" -- \
        cat "$BASELINE_PATH" >> "$RAW" 2>"$WORK/baseline.err"; then
    err "could not harvest the public baseline from $BASELINE_NS/$BASELINE_POD."
    sed 's/^/    /' "$WORK/baseline.err" >&2 || true
    err "Fixes: ensure the platform is running (the scheduler pod must exist), or"
    err "pass --baseline-file <mozilla-or-system-ca-bundle.pem> for a fully offline run,"
    err "or pass --no-baseline if this is a sealed air-gap with no public egress."
    exit 1
  fi
  printf '\n' >> "$RAW"
fi

# ----------------------------------------------------------------------------
# 2. Platform root CA (cert-manager) — so pods still trust internal platform TLS
# ----------------------------------------------------------------------------
if [ "$NO_ROOT_CA" -eq 1 ]; then
  warn "--no-root-ca: platform root CA omitted; internal platform TLS may not verify."
else
  ROOT_B64="$(kc -n "$ROOT_CA_NS" get secret "$ROOT_CA_SECRET" \
    -o "jsonpath={.data.${ROOT_CA_KEY//./\\.}}" 2>/dev/null || true)"
  if [ -n "$ROOT_B64" ]; then
    info "Root CA: from secret $ROOT_CA_NS/$ROOT_CA_SECRET (key $ROOT_CA_KEY)"
    printf '%s' "$ROOT_B64" | b64d >> "$RAW"; printf '\n' >> "$RAW"
  else
    warn "platform root-ca secret $ROOT_CA_NS/$ROOT_CA_SECRET (key $ROOT_CA_KEY) not found — skipping."
    warn "Internal platform TLS from these pods may fail to verify. (Use --no-root-ca to silence.)"
  fi
fi

# ----------------------------------------------------------------------------
# 3. Customer / corporate CA(s) — the whole point of the recipe
# ----------------------------------------------------------------------------
CUSTOMER_CERTS_BEFORE="$(grep -c 'BEGIN CERTIFICATE' "$RAW" 2>/dev/null || echo 0)"
if [ "${#CA_FILES[@]}" -gt 0 ]; then
  for f in "${CA_FILES[@]}"; do
    [ -r "$f" ] || die "--ca-file not readable: $f"
    grep -q 'BEGIN CERTIFICATE' "$f" || die "--ca-file has no PEM certificate: $f"
    info "Customer CA: from file $f"
    cat "$f" >> "$RAW"; printf '\n' >> "$RAW"
  done
else
  info "Customer CA: no --ca-file given; reading secret $CUSTOMER_SECRET_NS/$CUSTOMER_SECRET (all keys)"
  SECRET_JSON_KEYS="$(kc -n "$CUSTOMER_SECRET_NS" get secret "$CUSTOMER_SECRET" \
    -o "go-template={{range \$k,\$v := .data}}{{\$v}}{{\"\n\"}}{{end}}" 2>/dev/null || true)"
  if [ -z "$SECRET_JSON_KEYS" ]; then
    die "no customer CA: pass --ca-file <pem>, or create secret $CUSTOMER_SECRET_NS/$CUSTOMER_SECRET first
       (see org-ca-secret.template.yaml / kustomization.yaml / demo-pki/)."
  fi
  while IFS= read -r line; do
    [ -n "$line" ] || continue
    printf '%s' "$line" | b64d >> "$RAW"; printf '\n' >> "$RAW"
  done <<< "$SECRET_JSON_KEYS"
fi
CUSTOMER_CERTS_AFTER="$(grep -c 'BEGIN CERTIFICATE' "$RAW" 2>/dev/null || echo 0)"
if [ "$CUSTOMER_CERTS_AFTER" -le "$CUSTOMER_CERTS_BEFORE" ]; then
  die "no certificates were added from the customer CA source — check the file/secret."
fi

# ----------------------------------------------------------------------------
# Split into individual certs and dedupe by SHA-256 fingerprint.
# Makes re-runs idempotent even when the harvested baseline already contains
# certs we are re-adding (e.g. a re-run after the bundle is already mounted).
# ----------------------------------------------------------------------------
BUNDLE="$WORK/ca-certificates.crt"
: > "$BUNDLE"
CERTDIR="$WORK/certs"; mkdir -p "$CERTDIR"
awk -v dir="$CERTDIR" '
  /-----BEGIN CERTIFICATE-----/ { n++; f=sprintf("%s/c%05d.pem", dir, n) }
  n>0 { print > f }
' "$RAW"

SEEN="$WORK/seen.txt"; : > "$SEEN"
KEPT=0
for f in "$CERTDIR"/c*.pem; do
  [ -e "$f" ] || continue
  fp="$(openssl x509 -in "$f" -noout -fingerprint -sha256 2>/dev/null | sed 's/.*=//')" || continue
  [ -n "$fp" ] || continue
  if ! grep -qxF "$fp" "$SEEN"; then
    printf '%s\n' "$fp" >> "$SEEN"
    openssl x509 -in "$f" 2>/dev/null >> "$BUNDLE" || cat "$f" >> "$BUNDLE"
    KEPT=$((KEPT + 1))
  fi
done

[ "$KEPT" -gt 0 ] || die "assembled bundle is empty after parsing — no valid certificates found."
info "Assembled additive bundle: $KEPT unique certificate(s)."
if [ "$NO_BASELINE" -eq 0 ] && [ "$KEPT" -lt 10 ]; then
  warn "only $KEPT certs in the bundle — the public baseline may be missing."
  warn "verify.sh expects >50 in-pod (the Mozilla set). Check --baseline-file/--baseline-pod."
fi

# ----------------------------------------------------------------------------
# Emit / apply the ConfigMap to each target namespace
# ----------------------------------------------------------------------------
render_cm() {
  local ns="$1"
  kc create configmap "$CM_NAME" \
      --from-file="$CM_KEY=$BUNDLE" \
      -n "$ns" --dry-run=client -o yaml \
  | kc label --local -f - -o yaml --dry-run=client \
      app.kubernetes.io/name=trust-bundle \
      app.kubernetes.io/part-of=kamiwaza \
      app.kubernetes.io/managed-by=tls-trust-build-script \
      security.kamiwaza.io/trust-bundle-source=config-only
}

if [ "$DRY_RUN" -eq 1 ]; then
  info "--dry-run: rendering ConfigMap for namespace '${NAMESPACES[0]}' (not applying)"
  render_cm "${NAMESPACES[0]}"
  exit 0
fi

APPLIED=()
SKIPPED=()
for ns in "${NAMESPACES[@]}"; do
  if ! kc get namespace "$ns" >/dev/null 2>&1; then
    warn "namespace '$ns' does not exist — skipping (create it / run the platform first)."
    SKIPPED+=("$ns")
    continue
  fi
  render_cm "$ns" | kc apply -f - >/dev/null
  info "applied $CM_NAME -> namespace $ns"
  APPLIED+=("$ns")
done

echo >&2
info "Done. $CM_NAME ($CM_KEY, $KEPT certs) applied to: ${APPLIED[*]:-(none)}"
[ "${#SKIPPED[@]}" -gt 0 ] && warn "skipped (missing namespace): ${SKIPPED[*]}"
cat >&2 <<EOF

Next steps:
  1. Ensure core.trustManager.enabled: true is set (see trust-bundle-values-snippet.yaml)
     and run a helmfile sync. That value mounts THIS ConfigMap — it needs no controller.
  2. If the mount was already enabled, roll the pods so the new file is read
     (a subPath mount does NOT hot-update on ConfigMap change):
       kubectl -n kamiwaza rollout restart deploy/core-scheduler
       kubectl -n kamiwaza delete pod -l ray.io/cluster=core-raycluster,ray.io/node-type=head
  3. Verify:  security/tls-trust/verify.sh
EOF
