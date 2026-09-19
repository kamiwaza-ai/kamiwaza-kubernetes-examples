#!/usr/bin/env bash
set -euo pipefail

context="${1:?usage: apply.sh <kubectl-context>}"
root="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
tmp="$(mktemp -d)"
trap 'rm -rf "${tmp}"' EXIT

# Reuse a credential this environment already holds, and generate only what is
# missing. Regenerating on every run left the identity provider with the
# bootstrap administrator password from the FIRST run — it creates that account
# once and nothing rotates it — so the bootstrap Job then failed with
# `invalid_grant` against a password only this script had ever seen.
for name in idp-admin-password lab-user-password oidc-client-secret ldap-admin-password ldap-bind-password; do
  if kubectl --context "${context}" -n platform-validation-dependencies get secret \
    platform-validation-credentials -o "jsonpath={.data.${name}}" 2>/dev/null |
    base64 -d >"${tmp}/${name}" 2>/dev/null && [ -s "${tmp}/${name}" ]; then
    continue
  fi
  # No trailing newline. The same bytes reach a workload as an environment
  # variable and reach a client as a `-y` password file, and one of those two
  # keeps a trailing newline while the other drops it — which presents as
  # `Invalid credentials` against a directory that was seeded correctly.
  openssl rand -hex 32 | tr -d '\n' >"${tmp}/${name}"
done

# Reuse the authority and the leaves this environment already holds, for the
# same reason the credentials are reused: a workload copies its certificate
# material at pod start, so regenerating on every run left slapd serving a
# leaf signed by the previous run's authority while every client validated
# against the new one. The handshake then completed and the client dropped the
# connection, which reads as an unreachable directory.
fetch_existing_material() {
  kubectl --context "${context}" -n platform-validation-dependencies get secret \
    platform-validation-server-tls -o 'jsonpath={.data.tls\.crt}' 2>/dev/null |
    base64 -d >"${tmp}/server.crt" 2>/dev/null || return 1
  kubectl --context "${context}" -n platform-validation-dependencies get secret \
    platform-validation-server-tls -o 'jsonpath={.data.tls\.key}' 2>/dev/null |
    base64 -d >"${tmp}/server.key" 2>/dev/null || return 1
  kubectl --context "${context}" -n platform-validation-dependencies get secret \
    platform-validation-client-tls -o 'jsonpath={.data.tls\.crt}' 2>/dev/null |
    base64 -d >"${tmp}/client.crt" 2>/dev/null || return 1
  kubectl --context "${context}" -n platform-validation-dependencies get secret \
    platform-validation-client-tls -o 'jsonpath={.data.tls\.key}' 2>/dev/null |
    base64 -d >"${tmp}/client.key" 2>/dev/null || return 1
  kubectl --context "${context}" -n platform-validation-dependencies get configmap \
    platform-validation-ca -o 'jsonpath={.data.ca\.crt}' \
    >"${tmp}/ca.crt" 2>/dev/null || return 1
  for file in server.crt server.key client.crt client.key ca.crt; do
    [ -s "${tmp}/${file}" ] || return 1
  done
  # An expired leaf is not reusable material. The generated validity is seven
  # days, so a long-lived lab environment re-mints rather than serving a
  # certificate every client refuses.
  openssl x509 -in "${tmp}/server.crt" -checkend 3600 >/dev/null 2>&1 || return 1
}

generate_material() {
  # keyUsage and basicConstraints are stated, not left to the default: without
  # keyCertSign on the authority, OpenSSL 3 refuses the chain with "CA cert
  # does not include key usage extension" and every fixture presents as a TLS
  # failure rather than as a malformed lab authority.
  openssl req -x509 -newkey rsa:3072 -nodes -days 7 \
    -subj /CN=platform-validation-root \
    -addext 'basicConstraints=critical,CA:TRUE,pathlen:0' \
    -addext 'keyUsage=critical,keyCertSign,cRLSign' \
    -keyout "${tmp}/ca.key" -out "${tmp}/ca.crt" >/dev/null 2>&1
  openssl req -newkey rsa:3072 -nodes \
    -subj /CN=platform-validation-services \
    -keyout "${tmp}/server.key" -out "${tmp}/server.csr" >/dev/null 2>&1
  cat >"${tmp}/server.ext" <<'EOF'
subjectAltName=DNS:external-idp.platform-validation-dependencies.svc.cluster.local,DNS:external-directory.platform-validation-dependencies.svc.cluster.local,DNS:cac-piv-edge.platform-validation-dependencies.svc.cluster.local,DNS:mutual-tls-destination.platform-validation-dependencies.svc.cluster.local,DNS:login.example.com,DNS:ldap.example.com
extendedKeyUsage=serverAuth
EOF
  openssl x509 -req -days 7 -sha256 -in "${tmp}/server.csr" \
    -CA "${tmp}/ca.crt" -CAkey "${tmp}/ca.key" -CAcreateserial \
    -extfile "${tmp}/server.ext" -out "${tmp}/server.crt" >/dev/null 2>&1
  openssl req -newkey rsa:3072 -nodes -subj /CN=platform-validation-client \
    -keyout "${tmp}/client.key" -out "${tmp}/client.csr" >/dev/null 2>&1
  printf '%s\n' 'extendedKeyUsage=clientAuth' >"${tmp}/client.ext"
  openssl x509 -req -days 7 -sha256 -in "${tmp}/client.csr" \
    -CA "${tmp}/ca.crt" -CAkey "${tmp}/ca.key" -CAcreateserial \
    -extfile "${tmp}/client.ext" -out "${tmp}/client.crt" >/dev/null 2>&1
}

minted=false
if ! fetch_existing_material; then
  generate_material
  minted=true
fi
openssl genpkey -algorithm RSA -pkeyopt rsa_keygen_bits:3072 \
  -out "${tmp}/saml-signing-key" >/dev/null 2>&1

kubectl --context "${context}" apply -f "${root}/namespaces.yaml"
for namespace in kamiwaza-examples kamiwaza-examples-secondary; do
  kubectl --context "${context}" create namespace "${namespace}" \
    --dry-run=client -o yaml | kubectl --context "${context}" apply -f - >/dev/null
  kubectl --context "${context}" -n "${namespace}" create secret generic enterprise-oidc-client \
    --from-file=client-secret="${tmp}/oidc-client-secret" --dry-run=client -o yaml |
    kubectl --context "${context}" apply -f - >/dev/null
  kubectl --context "${context}" -n "${namespace}" create secret generic enterprise-ldap-bind \
    --from-file=password="${tmp}/ldap-bind-password" --dry-run=client -o yaml |
    kubectl --context "${context}" apply -f - >/dev/null
  kubectl --context "${context}" -n "${namespace}" create secret generic enterprise-saml-sp \
    --from-file=signing-key="${tmp}/saml-signing-key" --dry-run=client -o yaml |
    kubectl --context "${context}" apply -f - >/dev/null
  kubectl --context "${context}" -n "${namespace}" create secret generic enterprise-trust \
    --from-file=root-2026.pem="${tmp}/ca.crt" --from-file=root-2027.pem="${tmp}/ca.crt" \
    --dry-run=client -o yaml | kubectl --context "${context}" apply -f - >/dev/null
  kubectl --context "${context}" -n "${namespace}" create configmap cac-client-authorities \
    --from-file=authorities.pem="${tmp}/ca.crt" --dry-run=client -o yaml |
    kubectl --context "${context}" apply -f - >/dev/null
done

namespace=platform-validation-dependencies
kubectl --context "${context}" -n "${namespace}" create secret generic platform-validation-credentials \
  --from-file=idp-admin-password="${tmp}/idp-admin-password" \
  --from-file=lab-user-password="${tmp}/lab-user-password" \
  --from-file=oidc-client-secret="${tmp}/oidc-client-secret" \
  --from-file=ldap-admin-password="${tmp}/ldap-admin-password" \
  --from-file=ldap-bind-password="${tmp}/ldap-bind-password" \
  --dry-run=client -o yaml | kubectl --context "${context}" apply -f - >/dev/null
kubectl --context "${context}" -n "${namespace}" create secret tls platform-validation-server-tls \
  --cert="${tmp}/server.crt" --key="${tmp}/server.key" --dry-run=client -o yaml |
  kubectl --context "${context}" apply -f - >/dev/null
kubectl --context "${context}" -n "${namespace}" create secret tls platform-validation-client-tls \
  --cert="${tmp}/client.crt" --key="${tmp}/client.key" --dry-run=client -o yaml |
  kubectl --context "${context}" apply -f - >/dev/null
kubectl --context "${context}" -n "${namespace}" create configmap platform-validation-ca \
  --from-file=ca.crt="${tmp}/ca.crt" --dry-run=client -o yaml |
  kubectl --context "${context}" apply -f - >/dev/null
kubectl --context "${context}" -n platform-validation-client create secret tls platform-validation-client-tls \
  --cert="${tmp}/client.crt" --key="${tmp}/client.key" --dry-run=client -o yaml |
  kubectl --context "${context}" apply -f - >/dev/null
kubectl --context "${context}" -n platform-validation-client create configmap platform-validation-ca \
  --from-file=ca.crt="${tmp}/ca.crt" --dry-run=client -o yaml |
  kubectl --context "${context}" apply -f - >/dev/null

kubectl --context "${context}" -n "${namespace}" delete job \
  external-idp-bootstrap external-directory-bootstrap dependency-validation-check \
  --ignore-not-found --wait=true >/dev/null
kubectl --context "${context}" -n platform-validation-client delete job \
  proxy-validation-check --ignore-not-found --wait=true >/dev/null
kubectl --context "${context}" apply -k "${root}"
# A workload reads its certificate material once, at start. When this run
# minted a new authority, every already-running fixture is still serving a
# leaf the new authority did not sign, and the checks fail as a TLS error
# rather than as the rotation it is. A restart is cheap and only happens on
# the run that actually rotated.
if [ "${minted}" = true ]; then
  kubectl --context "${context}" -n "${namespace}" rollout restart \
    deployment/external-idp deployment/external-directory deployment/cac-piv-edge \
    deployment/egress-proxy deployment/mutual-tls-destination deployment/resumable-stream \
    >/dev/null
fi
for deployment in external-idp external-directory cac-piv-edge egress-proxy mutual-tls-destination resumable-stream; do
  kubectl --context "${context}" -n "${namespace}" rollout status \
    "deployment/${deployment}" --timeout=10m
done
for job in external-idp-bootstrap external-directory-bootstrap; do
  kubectl --context "${context}" -n "${namespace}" wait \
    --for=condition=complete "job/${job}" --timeout=10m
done
kubectl --context "${context}" -n "${namespace}" wait \
  --for=condition=complete job/dependency-validation-check --timeout=10m
kubectl --context "${context}" -n platform-validation-client wait \
  --for=condition=complete job/proxy-validation-check --timeout=10m

kubectl --context "${context}" -n "${namespace}" get configmap enterprise-oidc-metadata \
  -o jsonpath='{.data.metadata\.json}' >"${tmp}/metadata.json"
kubectl --context "${context}" -n "${namespace}" get configmap enterprise-saml-metadata \
  -o jsonpath='{.data.metadata\.xml}' >"${tmp}/metadata.xml"
for target in kamiwaza-examples kamiwaza-examples-secondary; do
  kubectl --context "${context}" -n "${target}" create configmap enterprise-oidc-metadata \
    --from-file=metadata.json="${tmp}/metadata.json" --dry-run=client -o yaml |
    kubectl --context "${context}" apply -f - >/dev/null
  kubectl --context "${context}" -n "${target}" create configmap enterprise-saml-metadata \
    --from-file=metadata.xml="${tmp}/metadata.xml" --dry-run=client -o yaml |
    kubectl --context "${context}" apply -f - >/dev/null
done
