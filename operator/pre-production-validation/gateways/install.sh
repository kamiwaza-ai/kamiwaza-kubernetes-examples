#!/usr/bin/env bash
set -euo pipefail

implementation="${1:?usage: install.sh <envoy|istio|kong> <kubectl-context>}"
context="${2:?usage: install.sh <envoy|istio|kong> <kubectl-context>}"
gateway_api_version=v1.6.2
root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

# Two of the three implementations ship no GatewayClass of their own, so those
# environments declare the administrator-owned class their Gateway selects. It
# is applied here rather than from the environment overlay because verify.sh
# requires the class to exist before it applies that overlay.
gateway_class_manifest=""

# One implementation reconciles Gateway API only when the CRDs were present
# before its controller started, so its bundle is applied first. The others
# take the bundle afterwards because their charts ship one and would otherwise
# decide the Gateway API version for their own cluster.
#
# Server-side, because the experimental channel's HTTPRoute schema exceeds the
# 262144-byte last-applied-configuration annotation a client-side apply writes,
# which fails the install outright. --force-conflicts takes those fields back
# from a chart that installed its own bundle.
bundle_applied=false
apply_bundle() {
  [ "${bundle_applied}" = true ] && return 0
  kubectl --context "${context}" apply --server-side --force-conflicts -f \
    "https://github.com/kubernetes-sigs/gateway-api/releases/download/${gateway_api_version}/experimental-install.yaml"
  bundle_applied=true
}

case "${implementation}" in
envoy)
  gateway_class=eg
  gateway_class_manifest="${root}/environments/envoy/gatewayclass.yaml"
  # --force-conflicts because this chart ships its own Gateway API bundle
  # alongside its gateway.envoyproxy.io CRDs under one `crds.enabled` flag,
  # so the bundle cannot be skipped without also dropping the CRDs the
  # controller needs.
  helm --kube-context "${context}" upgrade --install envoy-gateway \
    oci://docker.io/envoyproxy/gateway-helm --force-conflicts \
    --version v1.9.1 --namespace envoy-gateway-system --create-namespace --wait
  ;;
istio)
  gateway_class=istio
  helm --kube-context "${context}" upgrade --install istio-base \
    oci://gcr.io/istio-release/charts/base \
    --version 1.30.4 --namespace istio-system --create-namespace --wait
  helm --kube-context "${context}" upgrade --install istiod \
    oci://gcr.io/istio-release/charts/istiod \
    --version 1.30.4 --namespace istio-system --wait
  ;;
kong)
  gateway_class=kong
  gateway_class_manifest="${root}/environments/kong/gatewayclass.yaml"
  # This controller watches Gateway API only when the definitions existed
  # before it started, so the bundle goes in first and the class is applied
  # before the controller can look for it.
  apply_bundle
  kubectl --context "${context}" apply -f "${gateway_class_manifest}"
  # The Gateway API support this implementation counts as alpha is behind its
  # own feature gate, and the standard BackendTLSPolicy it implements is part
  # of that set. NodePort because its proxy Service defaults to LoadBalancer,
  # which stays Pending on a cluster with no load balancer and leaves every
  # listener unprogrammed. The chart name is given alone with --repo: a
  # `repo/chart` reference resolves against locally added repositories, and
  # naming both is refused.
  helm --kube-context "${context}" upgrade --install kong \
    ingress --repo https://charts.konghq.com \
    --version 0.24.0 --namespace kong --create-namespace --wait \
    --set gateway.proxy.type=NodePort \
    --set controller.ingressController.env.feature_gates=GatewayAlpha=true
  ;;
*)
  echo "unknown Gateway API implementation: ${implementation}" >&2
  exit 2
  ;;
esac

apply_bundle

if [ -n "${gateway_class_manifest}" ]; then
  kubectl --context "${context}" apply -f "${gateway_class_manifest}"
fi

# Istio's own controller creates its GatewayClass, and it does so only after
# the Gateway API CRDs exist -- which is after this script applies the pinned
# bundle. Waiting for a condition on an object that does not exist yet fails
# immediately, so wait for the class to appear before waiting for it to be
# accepted.
kubectl --context "${context}" wait \
  --for=create "gatewayclass/${gateway_class}" --timeout=5m
kubectl --context "${context}" wait \
  --for=condition=Accepted "gatewayclass/${gateway_class}" --timeout=5m
