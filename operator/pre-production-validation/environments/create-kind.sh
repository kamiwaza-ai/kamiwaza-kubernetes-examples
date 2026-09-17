#!/usr/bin/env bash
set -euo pipefail

root="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
for environment in envoy istio; do
  cluster="kamiwaza-validation-${environment}"
  if ! kind get clusters | grep -Fxq "${cluster}"; then
    kind create cluster --name "${cluster}" --config "${root}/kind.yaml"
  fi
done

if kubectl --context kind-kamiwaza-validation-envoy get crd certificates.cert-manager.io >/dev/null 2>&1; then
  echo "Envoy validation cluster must not contain a certificate controller" >&2
  exit 1
fi
