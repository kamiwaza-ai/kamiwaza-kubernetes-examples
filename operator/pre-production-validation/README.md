# Pre-production platform validation

Use this scenario before approving a platform-operator release or a new administrator policy. It creates three disposable environments, supplies synthetic external dependencies, and runs the same platform intent through three different Gateway API implementations.

Three, not two, because two implementations can agree by coincidence. The third one disagrees on purpose: it ships no GatewayClass and needs an annotation on the one the environment declares, it reconciles Gateway API only when the definitions predate its controller, it runs one shared proxy for every Gateway with no per-Gateway ownership label, and it supports only one of the two Extended features the other two support. Everything it disagrees about is environment-owned. If a platform field, manifest, or controller branch has to change to serve it, that is the finding.

Nothing here is a production identity system, certificate authority, proxy, or routing default. All identities and certificates are generated for one disposable run. The scripts do not record credentials, certificate contents, private endpoints, certificate subjects, or user identifiers in evidence.

## What this scenario supplies

| Dependency                               | Lab implementation                                                                                                                                     |
| ---------------------------------------- | ------------------------------------------------------------------------------------------------------------------------------------------------------ |
| Three Gateway API implementations        | Envoy Gateway `v1.9.1`, Istio `1.30.4`, and Kong Ingress Controller `3.5` with Kong `3.9` (chart `kong/ingress` `0.24.0`), all on Gateway API `v1.6.2` |
| Cluster without a certificate controller | Fresh Kind environment; the PlatformIssued path must work without cert-manager                                                                         |
| OIDC and SAML provider                   | Keycloak `26.7.4`, digest pinned, with one generated user and client credential                                                                        |
| LDAP provider                            | Digest-pinned OpenLDAP over TLS with a generated read-only federation account                                                                          |
| CAC/PIV edge                             | Mutual-TLS lab edge that strips caller identity headers and accepts only the login path                                                                |
| Enforcing egress proxy                   | CONNECT proxy with one allowed destination plus NetworkPolicy denial of direct client egress                                                           |
| Mutual-TLS destination                   | TLS endpoint that requires a client certificate signed by the generated lab authority                                                                  |
| Resumable stream                         | Two-replica SSE endpoint that resumes from `Last-Event-ID`                                                                                             |

The administrator policy fragments use reserved documentation hosts. Replace those hosts with the reviewed addresses that expose these fixtures in your lab. Do not weaken `deniedNetworks` to make a private endpoint pass.

## Prerequisites

Use Helm 4 or later. The Gateway installer passes `--force-conflicts` so the reviewed controller chart and the pinned Gateway API bundle can transfer CRD field ownership safely; Helm 3 does not support that option.

## Repository validation

```bash
python3 operator/pre-production-validation/validate.py \
  --operator-root ../kamiwaza-platform-operator
```

This validates the matrix, renders every Kustomize package, checks both policy fragments against the operator's published schemas and semantic cross-reference rules, and validates the quickstart platform resource against the current CRD.

## Create three disposable environments

```bash
operator/pre-production-validation/environments/create-kind.sh

operator/pre-production-validation/gateways/install.sh \
  envoy kind-kamiwaza-validation-envoy
operator/pre-production-validation/gateways/install.sh \
  istio kind-kamiwaza-validation-istio
operator/pre-production-validation/gateways/install.sh \
  kong kind-kamiwaza-validation-kong
```

`create-kind.sh` creates one cluster per directory under `environments/`, so a fourth implementation is a directory plus a branch in `gateways/install.sh` and nothing else.

Install the same reviewed platform-operator build into every cluster. Namespaces are `kamiwaza-examples`, `kamiwaza-examples-secondary`, and `kamiwaza-examples-third`. Apply the same `operator/quickstart/kamiwaza-platform.yaml` intent in all three. Only administrator-owned Gateway and external dependency addresses may differ.

```bash
operator/pre-production-validation/platform/certificates.sh \
  kind-kamiwaza-validation-kong kamiwaza-examples-third
operator/pre-production-validation/platform/install.sh \
  ../kamiwaza-platform-operator kind-kamiwaza-validation-kong \
  kamiwaza-examples-third kong
```

Order matters twice. The component certificates come first, because these environments run no certificate controller and a Gateway with no TLS material never programs its listener. The installer then applies that environment's Gateway itself, because immutable policy is sealed at startup: the callback origin and the data plane namespace must be real addresses before the manager loads them, not names filled in afterwards.

Each environment states three things about itself in `environments/<name>/dataplane.env`: where its implementation runs the proxy, how that Service is identified, and which Gateway API conformance features its administrator attests. The third of those is the honest part of portability — the Kong environment attests one Extended feature and not the other, so the platform must withhold the unattested one and report the gap rather than emitting an object that implementation would ignore.

## Install lab dependencies

```bash
for context in kind-kamiwaza-validation-envoy kind-kamiwaza-validation-istio \
  kind-kamiwaza-validation-kong; do
  operator/pre-production-validation/fixtures/apply.sh "${context}"
done
```

The installer generates all credentials and certificates in a temporary directory, creates Kubernetes Secrets through standard input, then removes the directory. It waits for the identity bootstrap, read-only LDAP proof, header-sanitization check, resumable-stream check, approved proxy path, and direct-egress denial.

## Run platform checks

Merge `policy/auth-profile-fragment.yaml` and `policy/transport-policy-fragment.yaml` into the immutable administrator policy for each environment. Replace documentation hosts with reviewed lab routes. Bump the policy revision.

Run:

```bash
operator/pre-production-validation/verify.sh \
  ../kamiwaza-platform-operator \
  envoy=kind-kamiwaza-validation-envoy \
  istio=kind-kamiwaza-validation-istio \
  kong=kind-kamiwaza-validation-kong
```

Each pair is one environment. Leave a pair off to run that implementation later on a host that cannot hold three platforms at once; `verify.sh` reports what it skipped rather than reporting a three-implementation result it never observed. It reads each environment's namespace and GatewayClass from that environment's own Gateway, so there is no table of environment properties to keep in step.

Then execute `validation-matrix.yaml` in order. For identity and edge checks, include valid and invalid issuer, audience, signature, replay, certificate-time, certificate-policy, revocation, spoofed-header, and direct-origin cases. For runtime checks, roll the API surface while a finite request and resumable stream are active, drain one node, and verify the stream resumes within the declared bound.

Record only fields present in `evidence-template.yaml`. Never copy a generated Secret, token, certificate, private endpoint, certificate subject, or personal identifier into the evidence file.

## Cleanup

These clusters are disposable:

```bash
kind delete cluster --name kamiwaza-validation-envoy
kind delete cluster --name kamiwaza-validation-istio
kind delete cluster --name kamiwaza-validation-kong
```
