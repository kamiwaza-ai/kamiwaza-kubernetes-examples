#!/usr/bin/env bash
set -euo pipefail

namespace="${KAMIWAZA_NAMESPACE:-kamiwaza-examples}"
manager_namespace="${KAMIWAZA_MANAGER_NAMESPACE:-kamiwaza-examples-system}"
platform="${KAMIWAZA_PLATFORM_NAME:-kamiwaza}"

echo "Checking the shared manager"
kubectl -n "${manager_namespace}" rollout status \
  deployment/kamiwaza-platform-operator \
  --timeout=5m

echo "Waiting for platform reconciliation"
kubectl -n "${namespace}" wait \
  --for=condition=Ready \
  "kamiwazaplatform/${platform}" \
  --timeout=45m

current_version="$(kubectl -n "${namespace}" get kamiwazaplatform "${platform}" -o jsonpath='{.status.currentVersion}')"
if [[ ${current_version} != "1.3.0" ]]; then
  echo "Expected currentVersion 1.3.0, got '${current_version}'" >&2
  exit 1
fi

echo "Platform components"
kubectl -n "${namespace}" get kamiwazaplatform "${platform}" \
  -o jsonpath='{range .status.components[*]}{.name}{"\t"}{.phase}{"\t"}{.reason}{"\n"}{end}'

echo "Model deployments"
kubectl -n "${namespace}" get modeldeployments.serving.kamiwaza.io
