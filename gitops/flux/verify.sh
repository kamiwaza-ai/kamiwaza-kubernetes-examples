#!/usr/bin/env bash
set -euo pipefail

# Verifies the delivery, not just the platform. A platform that is Ready
# proves the operator converged; it does not prove Flux ever knew, and a
# delivery that reports success while the platform is still pulling images is
# the failure this scenario exists to rule out.

namespace="${KAMIWAZA_NAMESPACE:-kamiwaza-examples}"
manager_namespace="${KAMIWAZA_MANAGER_NAMESPACE:-kamiwaza-examples-system}"
platform="${KAMIWAZA_PLATFORM_NAME:-kamiwaza}"
flux_namespace="${FLUX_NAMESPACE:-flux-system}"

echo "Source"
kubectl -n "${flux_namespace}" wait --for=condition=Ready \
  ocirepository/kamiwaza-config --timeout=5m

echo "Manager layer"
kubectl -n "${flux_namespace}" wait --for=condition=Ready \
  kustomization/kamiwaza-manager --timeout=15m
kubectl -n "${manager_namespace}" wait --for=condition=Ready \
  helmrelease/kamiwaza-platform-operator --timeout=15m

echo "Platform layer"
# The Kustomization's own Ready condition is the assertion. It is true only
# after the health expressions in bootstrap.yaml matched, so this fails if
# the platform is unhealthy and also if the expressions silently matched
# nothing.
kubectl -n "${flux_namespace}" wait --for=condition=Ready \
  kustomization/kamiwaza-platform --timeout=60m

echo "Platform"
kubectl -n "${namespace}" wait --for=condition=Ready \
  "kamiwazaplatform/${platform}" --timeout=5m

current_version="$(kubectl -n "${namespace}" get kamiwazaplatform "${platform}" \
  -o jsonpath='{.status.currentVersion}')"
if [[ ${current_version} != "1.3.0" ]]; then
  echo "Expected currentVersion 1.3.0, got '${current_version}'" >&2
  exit 1
fi

observed="$(kubectl -n "${namespace}" get kamiwazaplatform "${platform}" \
  -o jsonpath='{.status.observedGeneration}')"
generation="$(kubectl -n "${namespace}" get kamiwazaplatform "${platform}" \
  -o jsonpath='{.metadata.generation}')"
if [[ ${observed} != "${generation}" ]]; then
  echo "Operator has not observed generation ${generation} (observed ${observed})" >&2
  exit 1
fi

echo "Applied revision"
kubectl -n "${flux_namespace}" get kustomization kamiwaza-platform \
  -o jsonpath='{.status.lastAppliedRevision}{"\n"}'

echo "Platform components"
kubectl -n "${namespace}" get kamiwazaplatform "${platform}" \
  -o jsonpath='{range .status.components[*]}{.name}{"\t"}{.phase}{"\t"}{.reason}{"\n"}{end}'
