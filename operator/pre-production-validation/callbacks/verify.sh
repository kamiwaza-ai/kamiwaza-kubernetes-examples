#!/usr/bin/env bash
set -euo pipefail

# Proves the platform callback contract in one environment.
#
# Every platform-integrated extension component must receive the same
# projected callback origin, and a callback through it must reach both
# published route families: the legacy application API and the native governed
# endpoint. Nothing is patched after reconciliation -- a component with no
# projected origin is a result, not something to fix by hand.
#
# The bundle is content addressed, so this script renders the artifact, hashes
# it, delivers it under the name that digest implies, and pins the Extension to
# the same digest. A bundle whose content does not match its digest is refused
# by the platform, which is the point of pinning one.

context="${1:?usage: verify.sh <kubectl-context> <namespace> <platform-domain>}"
namespace="${2:?usage: verify.sh <kubectl-context> <namespace> <platform-domain>}"
domain="${3:?usage: verify.sh <kubectl-context> <namespace> <platform-domain>}"
root="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
tmp="$(mktemp -d)"
trap 'rm -rf "${tmp}"' EXIT

python3 - "${root}" "${domain}" "${tmp}" <<'PY'
import hashlib
import json
import sys
from pathlib import Path

root, domain, tmp = Path(sys.argv[1]), sys.argv[2], Path(sys.argv[3])
prober = (root / "prober.py").read_text()
# The prober is the file under review, carried into the artifact verbatim, so
# the thing tested and the thing read are the same text.
bundle = (root / "bundle.yaml").read_text()
bundle = bundle.replace("PROBER_SOURCE", json.dumps(prober))
bundle = bundle.replace("PLATFORM_DOMAIN_VALUE", domain)
(tmp / "bundle.yaml").write_text(bundle)
digest = "sha256:" + hashlib.sha256(bundle.encode()).hexdigest()
(tmp / "digest").write_text(digest)
PY

digest="$(cat "${tmp}/digest")"
# The delivery object's name is derived from the digest by the platform, so it
# is derived the same way here rather than carried in the spec beside it.
hex="${digest#sha256:}"
bundle_object="extension-bundle-${hex:0:12}"

kubectl --context "${context}" -n "${namespace}" create configmap "${bundle_object}" \
  --from-file=bundle.yaml="${tmp}/bundle.yaml" \
  --dry-run=client -o yaml | kubectl --context "${context}" apply --server-side -f - >/dev/null

# The runtime that hosts the extension. It is a separate kind because its
# fields have a different owner: an administrator states the domain, storage,
# and sandbox capacity, and an extension never edits them. There is no default
# runtime to fall back to, which is why one is declared here rather than
# assumed.
kubectl --context "${context}" apply --server-side -f - >/dev/null <<EOF
apiVersion: extensions.kamiwaza.io/v1alpha1
kind: ExtensionRuntime
metadata:
  name: validation
  namespace: ${namespace}
spec:
  domain: ${domain}
  storage:
    className: example-rwo
---
apiVersion: extensions.kamiwaza.io/v1alpha1
kind: Extension
metadata:
  name: callback-matrix
  namespace: ${namespace}
  labels:
    # An extension names the runtime that hosts it.
    kamiwaza.io/runtime: validation
spec:
  package:
    repository: examples/callback-matrix
    digest: ${digest}
EOF

for component in api background-worker document-worker; do
  kubectl --context "${context}" -n "${namespace}" wait --for=create \
    "deployment/callback-matrix-${component}" --timeout=2m
  kubectl --context "${context}" -n "${namespace}" rollout status \
    "deployment/callback-matrix-${component}" --timeout=5m
done

origins="${tmp}/origins"
: >"${origins}"
for component in api background-worker document-worker; do
  pod="$(kubectl --context "${context}" -n "${namespace}" get pod \
    -l "app.kubernetes.io/component=${component}" -o jsonpath='{.items[0].metadata.name}')"
  record="$(kubectl --context "${context}" -n "${namespace}" logs "${pod}" --tail=20 |
    grep -m1 '"results"')" || {
    echo "${component} produced no callback record" >&2
    exit 1
  }
  echo "${record}"
  # The record is an argument, not piped input: the program itself arrives on
  # standard input, so a pipe into it is read as the program and the record is
  # never seen.
  python3 - "${component}" "${origins}" "${record}" <<'PY'
import json
import sys

component, origins, record = sys.argv[1], sys.argv[2], json.loads(sys.argv[3])
with open(origins, "a", encoding="utf-8") as handle:
    handle.write(record["origin"] + "\n")
reached = {200, 401, 403, 404}
for family, status in record["results"].items():
    if status not in reached:
        raise SystemExit(f"{component} did not reach the {family} route family: {status}")
PY
done

# One origin for every component. A component that received a different
# address is reaching the platform some other way, which is the failure this
# contract exists to prevent.
if [ "$(sort -u "${origins}" | wc -l)" -ne 1 ]; then
  echo "extension components received different callback origins:" >&2
  cat "${origins}" >&2
  exit 1
fi
echo "every extension component reached both route families through one projected origin"
