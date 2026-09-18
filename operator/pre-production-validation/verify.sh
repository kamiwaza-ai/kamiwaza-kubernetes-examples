#!/usr/bin/env bash
set -euo pipefail

# Verifies one published platform intent against every routing implementation
# this scenario has an environment for.
#
# Usage: verify.sh <operator-root> <environment>=<context> [...]
#
#   verify.sh ../kamiwaza-platform-operator \
#     envoy=kind-kamiwaza-validation-envoy \
#     istio=kind-kamiwaza-validation-istio \
#     kong=kind-kamiwaza-validation-kong
#
# An environment left off the command line is skipped and reported as skipped.
# A host that cannot hold three platforms at once runs them one after another
# rather than reporting a three-implementation result it never observed.
operator_root="${1:?usage: verify.sh <operator-root> <environment>=<context> [...]}"
shift
root="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

python3 "${root}/validate.py" --operator-root "${operator_root}"

[ "$#" -gt 0 ] || {
  echo "at least one <environment>=<context> pair is required" >&2
  exit 2
}

for pair in "$@"; do
  environment="${pair%%=*}"
  context="${pair#*=}"
  overlay="${root}/environments/${environment}"
  [ -f "${overlay}/kustomization.yaml" ] || {
    echo "no environment named ${environment}" >&2
    exit 2
  }

  # The namespace and the class are the environment's own statements, read
  # from its Gateway rather than restated here: a table of environment
  # properties in this script is a second source of truth for facts the
  # overlay already carries.
  read -r namespace gateway_class <<<"$(python3 -c "
import sys, yaml
gateway = yaml.safe_load(open(sys.argv[1]))
print(gateway['metadata']['namespace'], gateway['spec']['gatewayClassName'])" "${overlay}/gateway.yaml")"

  # The controller-free environment proves the platform converges on
  # administrator-supplied certificate material. A certificate controller in
  # that cluster would make the check prove nothing.
  if [ "${environment}" = envoy ] &&
    kubectl --context "${context}" get crd certificates.cert-manager.io >/dev/null 2>&1; then
    echo "the envoy validation environment must not contain a certificate controller" >&2
    exit 1
  fi

  echo "== ${environment}: ${namespace} through gatewayclass/${gateway_class}"
  kubectl --context "${context}" get gatewayclass "${gateway_class}" >/dev/null
  kubectl --context "${context}" apply -k "${overlay}"
  kubectl --context "${context}" -n "${namespace}" wait \
    --for=condition=Accepted gateway/kamiwaza-gateway --timeout=5m
  kubectl --context "${context}" -n "${namespace}" wait \
    --for=condition=Ready kamiwazaplatform/kamiwaza --timeout=45m
  kubectl --context "${context}" -n platform-validation-dependencies wait \
    --for=condition=complete job/dependency-validation-check --timeout=10m
  kubectl --context "${context}" -n platform-validation-client wait \
    --for=condition=complete job/proxy-validation-check --timeout=10m
done
