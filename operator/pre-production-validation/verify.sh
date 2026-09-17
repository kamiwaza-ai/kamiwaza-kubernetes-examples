#!/usr/bin/env bash
set -euo pipefail

operator_root="${1:?usage: verify.sh <operator-root> <envoy-context> <istio-context>}"
envoy_context="${2:?usage: verify.sh <operator-root> <envoy-context> <istio-context>}"
istio_context="${3:?usage: verify.sh <operator-root> <envoy-context> <istio-context>}"
root="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

python3 "${root}/validate.py" --operator-root "${operator_root}"

if kubectl --context "${envoy_context}" get crd certificates.cert-manager.io >/dev/null 2>&1; then
  echo "Envoy validation environment must not contain a certificate controller" >&2
  exit 1
fi

for row in "${envoy_context}:envoy:kamiwaza-examples:eg" "${istio_context}:istio:kamiwaza-examples-secondary:istio"; do
  IFS=: read -r context environment namespace gateway_class <<<"${row}"
  kubectl --context "${context}" get gatewayclass "${gateway_class}" >/dev/null
  kubectl --context "${context}" apply -k "${root}/environments/${environment}"
  kubectl --context "${context}" -n "${namespace}" wait \
    --for=condition=Accepted gateway/kamiwaza-gateway --timeout=5m
  kubectl --context "${context}" -n "${namespace}" wait \
    --for=condition=Ready kamiwazaplatform/kamiwaza --timeout=45m
  kubectl --context "${context}" -n platform-validation-dependencies wait \
    --for=condition=complete job/dependency-validation-check --timeout=10m
  kubectl --context "${context}" -n platform-validation-client wait \
    --for=condition=complete job/proxy-validation-check --timeout=10m
done
