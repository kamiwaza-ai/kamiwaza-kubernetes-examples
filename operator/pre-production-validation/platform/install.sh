#!/usr/bin/env bash
set -euo pipefail

# Installs the reviewed platform-operator build into one validation
# environment, with the scenario's two administrator policy fragments merged
# into the immutable policy the manager loads at startup.
#
# Required environment:
#   MANAGER_IMAGE                   digest reference for the manager
#   TRANSPORT_SIGNER_IMAGE          digest reference for the certificate signer
#   WORKLOAD_IDENTITY_AGENT_IMAGE   digest reference for the identity agent
#   TRANSPORT_PROXY_IMAGE           digest reference for the transport proxy
#   REGISTRY_CREDENTIALS_FILE       Docker configuration file that can pull the
#                                   platform images
#
# Every image is a digest reference because immutable policy requires digests.
# The credentials file is read, never copied into any file this repository
# keeps.

operator_root="${1:?usage: install.sh <operator-root> <kubectl-context> <namespace>}"
context="${2:?usage: install.sh <operator-root> <kubectl-context> <namespace>}"
namespace="${3:?usage: install.sh <operator-root> <kubectl-context> <namespace>}"
root="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
scenario="$(cd "${root}/.." && pwd)"
examples="$(cd "${scenario}/../.." && pwd)"
chart="${operator_root}/charts/kamiwaza-platform-operator"

: "${MANAGER_IMAGE:?MANAGER_IMAGE is required}"
: "${TRANSPORT_SIGNER_IMAGE:?TRANSPORT_SIGNER_IMAGE is required}"
: "${WORKLOAD_IDENTITY_AGENT_IMAGE:?WORKLOAD_IDENTITY_AGENT_IMAGE is required}"
: "${TRANSPORT_PROXY_IMAGE:?TRANSPORT_PROXY_IMAGE is required}"
: "${REGISTRY_CREDENTIALS_FILE:?REGISTRY_CREDENTIALS_FILE is required}"

tmp="$(mktemp -d)"
trap 'rm -rf "${tmp}"' EXIT

for name in "${namespace}" "${namespace}-system"; do
  kubectl --context "${context}" create namespace "${name}" \
    --dry-run=client -o yaml | kubectl --context "${context}" apply -f - >/dev/null
done

kubectl --context "${context}" -n "${namespace}" create secret generic registry-pull \
  --from-file=.dockerconfigjson="${REGISTRY_CREDENTIALS_FILE}" \
  --type=kubernetes.io/dockerconfigjson \
  --dry-run=client -o yaml | kubectl --context "${context}" apply --server-side -f - >/dev/null

# The checked-in platform intent names a dynamic RWO class, which this
# environment provides under that name rather than by editing the example.
kubectl --context "${context}" apply -f "${root}/storageclass.yaml" >/dev/null

# Merge the administrator policy fragments into chart values. This is the
# scenario's "merge both fragments into the immutable administrator policy"
# step, done in one place so the fragments the repository publishes are the
# fragments the manager loads.
python3 - "${scenario}/policy" "${tmp}/policy-values.yaml" "${namespace}" <<'PY'
import sys
from pathlib import Path

import yaml

fragments = Path(sys.argv[1])
namespace = sys.argv[3]
transport = yaml.safe_load((fragments / "transport-policy-fragment.yaml").read_text())["transport"]
profiles = yaml.safe_load((fragments / "auth-profile-fragment.yaml").read_text())["profiles"]
# The published fragment names the namespaces of a default installation. Trust
# distribution reaches only namespaces the manager is allowed to write, so an
# environment that owns one namespace distributes to that one; leaving the
# published names in place blocks the platform with no distribution at all.
transport["trust"]["targetNamespaces"] = [namespace]
# Accepted workload identities name the namespace their peer runs in, and this
# installation's namespace is not the default one the published fragment
# shows. Rewriting the namespace segment keeps the peer set exact: the
# alternative is an accepted identity for a workload that does not exist here.
for hop in transport.get("internal", {}).get("hops", []):
    identity = hop.get("authentication", {}).get("workloadIdentityX509")
    if not identity:
        continue
    identity["acceptedIdentities"] = [
        accepted.replace("/ns/kamiwaza/", f"/ns/{namespace}/")
        for accepted in identity["acceptedIdentities"]
    ]
document = {"adminPolicy": {"transport": transport, "authProfiles": profiles}}
Path(sys.argv[2]).write_text(yaml.safe_dump(document, sort_keys=False))
PY

# The policy ConfigMap name is derived from the document's content hash, so a
# revision that changes with the images keeps an upgrade from trying to mutate
# an immutable object.
POLICY_REVISION="validation-$(printf '%s' \
  "${MANAGER_IMAGE}${TRANSPORT_SIGNER_IMAGE}${WORKLOAD_IDENTITY_AGENT_IMAGE}${TRANSPORT_PROXY_IMAGE}" |
  sha256sum | cut -c1-8)"
LAB_IMAGE_PREFIX="${TRANSPORT_SIGNER_IMAGE%%/*}/"
export POLICY_REVISION LAB_IMAGE_PREFIX PLATFORM_NAMESPACE="${namespace}"
export TRANSPORT_SIGNER_IMAGE WORKLOAD_IDENTITY_AGENT_IMAGE TRANSPORT_PROXY_IMAGE
envsubst <"${root}/values-overlay.yaml" >"${tmp}/values-overlay.yaml"

# A failed install stays in place: this scenario exists to read why a manager
# did not start, and a rollback deletes exactly that evidence.
helm --kube-context "${context}" upgrade --install kamiwaza-platform-operator "${chart}" \
  --namespace "${namespace}-system" \
  --values "${examples}/operator/quickstart/operator-values.yaml" \
  --values "${tmp}/values-overlay.yaml" \
  --values "${tmp}/policy-values.yaml" \
  --set-string image.registry="${MANAGER_IMAGE%%/*}" \
  --set-string image.repository="$(
    ref="${MANAGER_IMAGE#*/}"
    printf '%s' "${ref%@*}"
  )" \
  --set-string image.digest="${MANAGER_IMAGE#*@}" \
  --wait --timeout=10m

kubectl --context "${context}" -n "${namespace}-system" rollout status \
  deployment/kamiwaza-platform-operator --timeout=5m
