#!/usr/bin/env bash
set -euo pipefail

# Supplies the component certificate material an administrator owns when
# immutable policy selects externally issued certificates.
#
# This environment runs no certificate controller, which is the point: the
# platform must converge on material the administrator supplies. Under that
# policy the operator creates no Certificate object and issues nothing itself
# for the data stores -- it waits for four complete Secrets in the platform
# namespace. This script is the lab stand-in for whatever real authority an
# installation uses.
#
# The material is disposable and regenerated only when missing or expired. No
# key leaves the temporary directory, and nothing here is a production
# authority.

context="${1:?usage: certificates.sh <kubectl-context> <namespace>}"
namespace="${2:?usage: certificates.sh <kubectl-context> <namespace>}"
tmp="$(mktemp -d)"
trap 'rm -rf "${tmp}"' EXIT

# The namespaces this material lands in, created here because this script runs
# before the platform installer: an administrator supplies certificates first,
# and a Gateway whose listener Secret is absent never programs its listener.
# Creating them is idempotent, and the installer creates the same two.
for name in "${namespace}" "${namespace}-system"; do
  kubectl --context "${context}" create namespace "${name}" \
    --dry-run=client -o yaml | kubectl --context "${context}" apply -f - >/dev/null
done

# One authority per environment, kept in its own Secret so a rerun reuses it.
# Regenerating it would orphan every leaf a workload already loaded.
if ! kubectl --context "${context}" -n "${namespace}" get secret platform-component-ca \
  -o 'jsonpath={.data.tls\.crt}' 2>/dev/null | base64 -d >"${tmp}/ca.crt" ||
  ! [ -s "${tmp}/ca.crt" ] ||
  ! kubectl --context "${context}" -n "${namespace}" get secret platform-component-ca \
    -o 'jsonpath={.data.tls\.key}' 2>/dev/null | base64 -d >"${tmp}/ca.key" ||
  ! [ -s "${tmp}/ca.key" ]; then
  # keyUsage and basicConstraints are explicit: OpenSSL 3 refuses to verify a
  # chain whose authority omits them.
  openssl req -x509 -newkey rsa:2048 -noenc -days 30 \
    -subj '/CN=platform-validation-component-ca' \
    -addext 'basicConstraints=critical,CA:TRUE,pathlen:0' \
    -addext 'keyUsage=critical,keyCertSign,cRLSign' \
    -keyout "${tmp}/ca.key" -out "${tmp}/ca.crt" 2>/dev/null
  kubectl --context "${context}" -n "${namespace}" create secret tls platform-component-ca \
    --cert="${tmp}/ca.crt" --key="${tmp}/ca.key" \
    --dry-run=client -o yaml | kubectl --context "${context}" apply --server-side -f - >/dev/null
fi

etcd_names() {
  local role="$1" names='DNS:core-etcd,DNS:core-etcd.'"${namespace}"',DNS:core-etcd.'"${namespace}"'.svc.cluster.local'
  local ordinal
  for ordinal in 0 1 2; do
    names="${names},DNS:core-etcd-${ordinal}"
    names="${names},DNS:core-etcd-${ordinal}.core-etcd"
    names="${names},DNS:core-etcd-${ordinal}.core-etcd.${namespace}"
    names="${names},DNS:core-etcd-${ordinal}.core-etcd.${namespace}.svc"
    names="${names},DNS:core-etcd-${ordinal}.core-etcd.${namespace}.svc.cluster.local"
  done
  case "${role}" in
  server) printf '%s,DNS:localhost,IP:127.0.0.1' "${names}" ;;
  peer) printf '%s,DNS:*.core-etcd.%s.svc.cluster.local' "${names}" "${namespace}" ;;
  esac
}

# Each Secret carries tls.crt, tls.key and ca.crt, which is what the platform
# reads as a complete identity. A leaf that expires inside the next hour is
# replaced; one that does not is left alone so running workloads keep the
# material they loaded at start.
issue() {
  local secret="$1" common_name="$2" extensions="$3"
  if kubectl --context "${context}" -n "${namespace}" get secret "${secret}" \
    -o 'jsonpath={.data.tls\.crt}' 2>/dev/null | base64 -d >"${tmp}/live.crt" 2>/dev/null &&
    [ -s "${tmp}/live.crt" ] &&
    openssl x509 -in "${tmp}/live.crt" -checkend 3600 >/dev/null 2>&1; then
    return 0
  fi
  openssl req -newkey rsa:2048 -noenc -subj "/CN=${common_name}" \
    -keyout "${tmp}/leaf.key" -out "${tmp}/leaf.csr" 2>/dev/null
  {
    printf 'basicConstraints=critical,CA:FALSE\n'
    printf 'keyUsage=critical,digitalSignature,keyEncipherment\n'
    printf 'extendedKeyUsage=serverAuth,clientAuth\n'
    if [ -n "${extensions}" ]; then
      printf 'subjectAltName=%s\n' "${extensions}"
    fi
  } >"${tmp}/leaf.ext"
  openssl x509 -req -in "${tmp}/leaf.csr" -CA "${tmp}/ca.crt" -CAkey "${tmp}/ca.key" \
    -days 30 -extfile "${tmp}/leaf.ext" -out "${tmp}/leaf.crt" 2>/dev/null
  kubectl --context "${context}" -n "${namespace}" create secret generic "${secret}" \
    --type=kubernetes.io/tls \
    --from-file=tls.crt="${tmp}/leaf.crt" \
    --from-file=tls.key="${tmp}/leaf.key" \
    --from-file=ca.crt="${tmp}/ca.crt" \
    --dry-run=client -o yaml | kubectl --context "${context}" apply --server-side -f - >/dev/null
}

issue core-etcd-server-tls core-etcd-server "$(etcd_names server)"
issue core-etcd-peer-tls core-etcd-peer "$(etcd_names peer)"
issue core-etcd-client-tls core-etcd-client ''
issue core-client-tls core ''

# The retrieval streamer serves TLS from a Secret that cert-manager would fill
# under the managed policy. Under externally issued certificates the platform
# creates no Certificate object, so the administrator supplies this one too.
# Its names are the Service this streamer answers on, plus the platform
# domain.
issue core-retrieval-streamer-tls core-retrieval-streamer \
  "DNS:core-retrieval-streamer,DNS:core-retrieval-streamer.${namespace},DNS:core-retrieval-streamer.${namespace}.svc,DNS:core-retrieval-streamer.${namespace}.svc.cluster.local,DNS:kamiwaza-examples.example.com"

# The Gateway listener's own certificate. The routing implementation refuses
# to provision a data plane for a listener whose Secret is absent, so without
# this the Gateway reports Accepted while Programmed stays false and no route
# is ever served -- including the callback route an extension uses.
issue kamiwaza-gateway-tls "${domain:-kamiwaza-examples.example.com}" \
  "DNS:${domain:-kamiwaza-examples.example.com}"

# The transport policy fragment names two administrator authorities in a
# rotation overlap, read from a Secret in the namespace the manager runs in.
# Trust distribution refuses to publish a bundle while a declared authority is
# missing, so this environment supplies both: the retiring anchor is this
# environment's own component authority, and the current one is the authority
# the external dependency fixtures already use, which is what a client here
# actually has to trust.
kubectl --context "${context}" -n platform-validation-dependencies get configmap \
  platform-validation-ca -o 'jsonpath={.data.ca\.crt}' >"${tmp}/fixtures-ca.crt"
[ -s "${tmp}/fixtures-ca.crt" ] || {
  echo "the external dependency fixtures have published no authority yet; run fixtures/apply.sh first" >&2
  exit 1
}
kubectl --context "${context}" -n "${namespace}-system" create secret generic enterprise-trust \
  --from-file=root-2026.pem="${tmp}/ca.crt" \
  --from-file=root-2027.pem="${tmp}/fixtures-ca.crt" \
  --dry-run=client -o yaml | kubectl --context "${context}" apply --server-side -f - >/dev/null
