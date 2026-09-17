#!/usr/bin/env bash
set -euo pipefail

implementation="${1:?usage: install.sh <envoy|istio> <kubectl-context>}"
context="${2:?usage: install.sh <envoy|istio> <kubectl-context>}"
gateway_api_version=v1.6.2
root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

# Envoy Gateway ships no GatewayClass, unlike Istio, so this environment
# declares the administrator-owned class its Gateway selects. It is applied
# here rather than from the environment overlay because verify.sh requires the
# class to exist before it applies that overlay.
gateway_class_manifest=""

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
*)
  echo "unknown Gateway API implementation: ${implementation}" >&2
  exit 2
  ;;
esac

# The pinned bundle is applied after the implementation so both environments
# end on the same Gateway API version: a chart that ships its own bundle would
# otherwise decide the version for its own cluster.
#
# Server-side, because the experimental channel's HTTPRoute schema exceeds the
# 262144-byte last-applied-configuration annotation a client-side apply writes,
# which fails the install outright. --force-conflicts takes those fields back
# from the chart that installed its own bundle.
kubectl --context "${context}" apply --server-side --force-conflicts -f \
  "https://github.com/kubernetes-sigs/gateway-api/releases/download/${gateway_api_version}/experimental-install.yaml"

if [ -n "${gateway_class_manifest}" ]; then
  kubectl --context "${context}" apply -f "${gateway_class_manifest}"
fi

kubectl --context "${context}" wait \
  --for=condition=Accepted "gatewayclass/${gateway_class}" --timeout=5m
