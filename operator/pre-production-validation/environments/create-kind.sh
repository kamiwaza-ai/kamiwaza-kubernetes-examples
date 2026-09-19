#!/usr/bin/env bash
set -euo pipefail

# One disposable cluster per environment directory. The set of environments is
# read from the directories themselves, so adding a fourth routing
# implementation is a directory and an installer branch, never an edit here.
root="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
for path in "${root}"/*/kustomization.yaml; do
  environment="$(basename "$(dirname "${path}")")"
  cluster="kamiwaza-validation-${environment}"
  if ! kind get clusters | grep -Fxq "${cluster}"; then
    kind create cluster --name "${cluster}" --config "${root}/kind.yaml"
  fi
done

# The first environment is the controller-free one: it proves the platform
# converges on administrator-supplied certificate material with no certificate
# controller present at all, so a controller in that cluster would make the
# check prove nothing.
if kubectl --context kind-kamiwaza-validation-envoy get crd certificates.cert-manager.io >/dev/null 2>&1; then
  echo "envoy validation cluster must not contain a certificate controller" >&2
  exit 1
fi
