#!/usr/bin/env bash
set -euo pipefail

# Verifies the delivery, not just the platform. An Application reporting
# Healthy while the platform is still pulling images is the failure this
# scenario exists to rule out, and it is what happens without the health
# customization this scenario installs.

namespace="${KAMIWAZA_NAMESPACE:-kamiwaza-examples}"
platform="${KAMIWAZA_PLATFORM_NAME:-kamiwaza}"
argocd_namespace="${ARGOCD_NAMESPACE:-argocd}"

health_of() {
  kubectl -n "${argocd_namespace}" get application "$1" \
    -o jsonpath='{.status.health.status}'
}

sync_of() {
  kubectl -n "${argocd_namespace}" get application "$1" \
    -o jsonpath='{.status.sync.status}'
}

echo "Health customization"
# The assertion is that the entry exists and carries a script. Grepping the
# script for the kind's name would fail on a correct entry: the kind appears
# in the key, not in the Lua.
customization="$(kubectl -n "${argocd_namespace}" get configmap argocd-cm \
  -o jsonpath='{.data.resource\.customizations\.health\.platform\.kamiwaza\.io_KamiwazaPlatform}')"
if [[ -z ${customization} ]]; then
  # Without it every KamiwazaPlatform is Healthy on creation, so the waits
  # below would pass against a platform that has not started.
  echo "argocd-cm carries no health assessment for KamiwazaPlatform" >&2
  exit 1
fi

for application in kamiwaza kamiwaza-manager kamiwaza-platform; do
  echo "Application ${application}"
  kubectl -n "${argocd_namespace}" wait --for=jsonpath='{.status.health.status}'=Healthy \
    "application/${application}" --timeout=60m
  echo "  health=$(health_of "${application}") sync=$(sync_of "${application}")"
done

echo "Platform"
kubectl -n "${namespace}" wait --for=condition=Ready \
  "kamiwazaplatform/${platform}" --timeout=5m

current_version="$(kubectl -n "${namespace}" get kamiwazaplatform "${platform}" \
  -o jsonpath='{.status.currentVersion}')"
if [[ ${current_version} != "1.3.0" ]]; then
  echo "Expected currentVersion 1.3.0, got '${current_version}'" >&2
  exit 1
fi

echo "Platform components"
kubectl -n "${namespace}" get kamiwazaplatform "${platform}" \
  -o jsonpath='{range .status.components[*]}{.name}{"\t"}{.phase}{"\t"}{.reason}{"\n"}{end}'
