# Pre-production platform validation

Use this scenario before approving a platform-operator release or a new administrator policy. It creates two disposable environments, supplies synthetic external dependencies, and runs the same platform intent through two Gateway API implementations.

Nothing here is a production identity system, certificate authority, proxy, or routing default. All identities and certificates are generated for one disposable run. The scripts do not record credentials, certificate contents, private endpoints, certificate subjects, or user identifiers in evidence.

## What this scenario supplies

| Dependency                               | Lab implementation                                                                           |
| ---------------------------------------- | -------------------------------------------------------------------------------------------- |
| Two Gateway API implementations          | Envoy Gateway `v1.9.1` and Istio `1.30.4`, both on Gateway API `v1.6.2`                      |
| Cluster without a certificate controller | Fresh Kind environment; the PlatformIssued path must work without cert-manager               |
| OIDC and SAML provider                   | Keycloak `26.7.4`, digest pinned, with one generated user and client credential              |
| LDAP provider                            | Digest-pinned OpenLDAP over TLS with a generated read-only federation account                |
| CAC/PIV edge                             | Mutual-TLS lab edge that strips caller identity headers and accepts only the login path      |
| Enforcing egress proxy                   | CONNECT proxy with one allowed destination plus NetworkPolicy denial of direct client egress |
| Mutual-TLS destination                   | TLS endpoint that requires a client certificate signed by the generated lab authority        |
| Resumable stream                         | Two-replica SSE endpoint that resumes from `Last-Event-ID`                                   |

The administrator policy fragments use reserved documentation hosts. Replace those hosts with the reviewed addresses that expose these fixtures in your lab. Do not weaken `deniedNetworks` to make a private endpoint pass.

## Repository validation

```bash
python3 operator/pre-production-validation/validate.py \
  --operator-root ../kamiwaza-platform-operator
```

This validates the matrix, renders every Kustomize package, checks both policy fragments against the operator's published schemas and semantic cross-reference rules, and validates the quickstart platform resource against the current CRD.

## Create two disposable environments

```bash
operator/pre-production-validation/environments/create-kind.sh

operator/pre-production-validation/gateways/install.sh \
  envoy kind-kamiwaza-validation-envoy
operator/pre-production-validation/gateways/install.sh \
  istio kind-kamiwaza-validation-istio
```

Install the same reviewed platform-operator build into both clusters. Use namespaces `kamiwaza-examples` and `kamiwaza-examples-secondary`. Apply the same `operator/quickstart/kamiwaza-platform.yaml` intent in both environments. Only administrator-owned Gateway and external dependency addresses may differ.

## Install lab dependencies

```bash
operator/pre-production-validation/fixtures/apply.sh \
  kind-kamiwaza-validation-envoy
operator/pre-production-validation/fixtures/apply.sh \
  kind-kamiwaza-validation-istio
```

The installer generates all credentials and certificates in a temporary directory, creates Kubernetes Secrets through standard input, then removes the directory. It waits for the identity bootstrap, read-only LDAP proof, header-sanitization check, resumable-stream check, approved proxy path, and direct-egress denial.

## Run platform checks

Merge `policy/auth-profile-fragment.yaml` and `policy/transport-policy-fragment.yaml` into the immutable administrator policy for each environment. Replace documentation hosts with reviewed lab routes. Bump the policy revision.

Run:

```bash
operator/pre-production-validation/verify.sh \
  ../kamiwaza-platform-operator \
  kind-kamiwaza-validation-envoy \
  kind-kamiwaza-validation-istio
```

Then execute `validation-matrix.yaml` in order. For identity and edge checks, include valid and invalid issuer, audience, signature, replay, certificate-time, certificate-policy, revocation, spoofed-header, and direct-origin cases. For runtime checks, roll the API surface while a finite request and resumable stream are active, drain one node, and verify the stream resumes within the declared bound.

Record only fields present in `evidence-template.yaml`. Never copy a generated Secret, token, certificate, private endpoint, certificate subject, or personal identifier into the evidence file.

## Cleanup

These clusters are disposable:

```bash
kind delete cluster --name kamiwaza-validation-envoy
kind delete cluster --name kamiwaza-validation-istio
```
