# Custom outbound TLS trust

**Scenario:** add an administrator-approved certificate authority to operator-managed Kamiwaza workloads. Keep TLS verification enabled. Do not rebuild images or edit the generated trust-bundle ConfigMap.

**Tags:** #security #tls #pki #ca-trust #operator

## Contract

Administrator policy owns trust. A platform owner cannot add a certificate authority through `KamiwazaPlatform` intent.

The operator reads each approved authority from one exact-name Secret or ConfigMap in the manager namespace. It validates the PEM chain, merges the authority with platform roots and public roots, enforces the bundle-size ceiling, and publishes `kamiwaza-trust-bundle` in each approved workload namespace.

Core workloads mount the published bundle at `/app/trust/ca-certificates.crt`. The operator sets `SSL_CERT_FILE`, `REQUESTS_CA_BUNDLE`, and `AWS_CA_BUNDLE` to that path. A policy revision changes the workload template digest and causes a controlled rollout.

This example covers outbound server trust. It does not configure the inbound Gateway certificate. Use [external-edge](../external-edge/) for the listener contract.

## Files

| File                                                             | Purpose                                                         |
| ---------------------------------------------------------------- | --------------------------------------------------------------- |
| [transport-policy-fragment.yaml](transport-policy-fragment.yaml) | Loadable operator policy fragment with one additional authority |
| [inline-authority-refused.yaml](inline-authority-refused.yaml)   | Refused inline-certificate example                              |
| [kustomization.yaml](kustomization.yaml)                         | Generates the exact-name authority Secret from a local PEM file |
| [org-ca-secret.template.yaml](org-ca-secret.template.yaml)       | Reference Secret shape; do not put real PEM in Git              |

Files and directories for the retired 0.13 Deploy procedure remain historical evidence only. Do not use `build-trust-bundle-configmap.sh`, `trust-bundle-values-snippet.yaml`, `verify.sh`, `ingress/`, `extensions/`, or `bedrock-custom-region/` with an operator-managed installation. The operator replaces the manual ConfigMap builder and workload patching.

## Prerequisites

- Operator-managed platform is Ready.
- Manager namespace and workload namespace are known.
- Administrator policy uses `transport.trust.publicRoots: Include` unless the installation is an explicitly reviewed sealed environment.
- Root and intermediate certificates are in leaf-to-root order in one PEM file. The file contains certificates only.
- A test HTTPS endpoint presents a certificate whose DNS name matches the requested host.

Examples below use these standard names:

```bash
export MANAGER_NAMESPACE=kamiwaza-system
export PLATFORM_NAMESPACE=kamiwaza
export PLATFORM_NAME=kamiwaza
```

## 1. Create the authority source

Keep the PEM outside Git:

```bash
mkdir -p security/tls-trust/local-secrets
cp /path/to/root-and-intermediate.pem \
  security/tls-trust/local-secrets/org-ca.pem
```

`local-secrets/` is ignored by Git. Do not run `kubectl diff` on the generated Secret because a diff prints Secret data. Validate object names without printing object content, then apply:

```bash
kubectl apply --server-side --dry-run=server \
  -k security/tls-trust -o name
kubectl apply -k security/tls-trust
```

The supplied `kustomization.yaml` targets `kamiwaza-system`. Change that namespace to the actual manager namespace before applying.

## 2. Publish the policy revision

Validate [transport-policy-fragment.yaml](transport-policy-fragment.yaml) with the operator transport-policy loader. Merge only its `transport.trust.additionalAuthorities` item into the installation's existing trust policy. Keep its existing issuance, internal-hop, egress, target-namespace, public-root, and size settings.

Set the reference to the Secret from step 1:

```yaml
transport:
  trust:
    additionalAuthorities:
      - name: organization-root
        description: Organization outbound TLS authority
        secretRef:
          name: kamiwaza-org-ca
          key: org-ca.pem
```

Bump `adminPolicy.revision` and upgrade the operator release. The policy ConfigMap is immutable, so a changed document needs a new revision.

Do not paste PEM into administrator policy. [inline-authority-refused.yaml](inline-authority-refused.yaml) shows the rejected shape.

## 3. Wait for reconciliation

Wait for the platform to report the new policy revision and become Ready:

```bash
kubectl -n "$PLATFORM_NAMESPACE" wait \
  --for=jsonpath='{.status.adminPolicyRevision}'='<new-policy-revision>' \
  kamiwazaplatform/"$PLATFORM_NAME" --timeout=300s

kubectl -n "$PLATFORM_NAMESPACE" wait \
  --for=condition=Ready kamiwazaplatform/"$PLATFORM_NAME" --timeout=300s
```

Read the public trust verdict. Status contains a digest and counts, not certificate material:

```bash
kubectl -n "$PLATFORM_NAMESPACE" get kamiwazaplatform "$PLATFORM_NAME" \
  -o jsonpath='{range .status.capabilities[?(@.name=="trust")]}{.allowed}{"\t"}{.reason}{"\t"}{.message}{"\n"}{end}'
```

Expected reason: `TransportReady`.

## 4. Verify the published bundle

Save the generated bundle to a protected temporary file and verify that it trusts the supplied authority:

```bash
umask 077
kubectl -n "$PLATFORM_NAMESPACE" get configmap kamiwaza-trust-bundle \
  -o jsonpath='{.data.ca-certificates\.crt}' > /tmp/kamiwaza-trust-bundle.pem
openssl verify -CAfile /tmp/kamiwaza-trust-bundle.pem \
  security/tls-trust/local-secrets/org-ca.pem
rm /tmp/kamiwaza-trust-bundle.pem
```

Check the Core workload contract:

```bash
kubectl -n "$PLATFORM_NAMESPACE" get deployment core-api -o json | jq '{
  bundle: [.spec.template.spec.volumes[] | select(.configMap.name == "kamiwaza-trust-bundle")],
  environment: [.spec.template.spec.containers[].env[]? |
    select(.name == "SSL_CERT_FILE" or .name == "REQUESTS_CA_BUNDLE" or .name == "AWS_CA_BUNDLE")]
}'
```

## 5. Prove a real TLS handshake

Probe an HTTPS endpoint that uses the added authority. Use the endpoint DNS name from its certificate:

```bash
export TRUST_TEST_URL=https://service.example.invalid/healthz
kubectl -n "$PLATFORM_NAMESPACE" exec deploy/core-api -- \
  env TRUST_TEST_URL="$TRUST_TEST_URL" \
  /app/.venv/bin/python -c \
  'import os, urllib.request; print(urllib.request.urlopen(os.environ["TRUST_TEST_URL"], timeout=10).status)'
```

Do not use `curl -k`, `urllib` with an unverified context, `SSL_VERIFY=false`, or `AUTH_GATEWAY_TLS_INSECURE`. Those options suppress the control that this example proves.

## Failure behavior

| Reason                   | Meaning                                                                                                  | Action                                                             |
| ------------------------ | -------------------------------------------------------------------------------------------------------- | ------------------------------------------------------------------ |
| `EgressTrustPending`     | Referenced object does not exist yet, or one anchor expired while another stays valid                    | Publish or refresh the referenced authority; retry remains bounded |
| `EgressTrustReadFailed`  | API read failed for a transient cause                                                                    | Restore API access; the operator retries with backoff              |
| `EgressTrustForbidden`   | Manager lacks permission to read the exact-name object                                                   | Correct administrator RBAC and publish a reviewed policy revision  |
| `EgressAuthorityMissing` | A referenced key is empty or the configured sources contribute no valid anchor                           | Correct the named source object                                    |
| `EgressAuthorityInvalid` | PEM is malformed, material is not a CA, chain order is invalid, or the merged bundle exceeds the ceiling | Correct the source or reviewed ceiling; never weaken verification  |

The operator never publishes a partial replacement after invalid input. The previous valid bundle remains available while the new revision is blocked.

## Rotation and removal

For rotation, add the new authority beside the old authority. Wait for clients and servers to use the new chain. Remove the old authority in a later policy revision.

For removal, delete the authority from administrator policy first. Wait for the platform and workloads to become Ready on the new revision. Delete the source Secret only after no active policy references it.

## How this example was validated

- `transport-policy-fragment.yaml`: accepted by `adminpolicy.LoadTransportPolicy`.
- `inline-authority-refused.yaml`: rejected by the same loader because the authority contains inline certificate data.
- `kustomization.yaml`: rendered with a synthetic CA and passed server-side dry-run without printing Secret contents.
- Live k0s: a TLS request from `core-api` failed with `CERTIFICATE_VERIFY_FAILED` before policy admission. After the authority was added, the operator reported `TransportReady`, rolled Core, and the same verified request returned HTTP 200. Removing the authority restored the original policy and trust bundle.
