#!/usr/bin/env bash
set -euo pipefail

context="${1:?usage: apply.sh <kubectl-context>}"
root="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
tmp="$(mktemp -d)"
trap 'rm -rf "${tmp}"' EXIT

for name in idp-admin-password lab-user-password oidc-client-secret ldap-admin-password ldap-bind-password; do
  openssl rand -hex 32 >"${tmp}/${name}"
done

openssl req -x509 -newkey rsa:3072 -nodes -days 7 \
  -subj /CN=platform-validation-root \
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
