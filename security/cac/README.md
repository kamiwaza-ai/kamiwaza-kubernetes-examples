# CAC / PIV login through an external authentication edge

**Scenario:** admit CAC/PIV certificate login on one platform. An **enterprise TLS edge that the administrator owns** requires and verifies the client certificate. The platform does not run that edge. This example defines edge proof, origin enforcement, and platform output. It does not claim that the platform provides the edge.

**Tags:** #security #cac #piv #mtls #external-edge #gateway-api

Every value in this directory is a synthetic placeholder. Files, comments, and sample output contain no credential, private key, certificate body, real host name, distinguished name, EDIPI, FASC-N, certificate serial, or email address. The only host name is the reserved documentation domain `kamiwaza.example.com`. The only port is the registered HTTPS port. A CAC/PIV certificate subject identifies a person. Therefore, this example has no field for a subject. Certificate authorities, issuer names, and revocation data arrive from local files or referenced objects outside Git.

## The split

| Half of the contract                                                                                       | Who owns it       | How it is proven                                                                             |
| ---------------------------------------------------------------------------------------------------------- | ----------------- | -------------------------------------------------------------------------------------------- |
| Requiring and verifying the client certificate                                                             | administrator     | Gateway API frontend validation; the platform reads `Programmed`, `ResolvedRefs`, `Accepted` |
| Forwarding the verified certificate, sanitizing headers, bounding the path, keeping clients off the origin | administrator     | recorded conformance evidence the platform reads by exact name                               |
| Strict parsing, revocation freshness, principal mapping, session policy                                    | platform (origin) | enforced per request; fail-closed                                                            |
| Which operation is forwarded, which Service serves it, which authorities validate                          | platform          | standard `HTTPRoute`, `BackendTLSPolicy`, and client-authority `ConfigMap` only              |

Certificate forwarding is **not expressible in the routing standard**. Gateway API defines no client-certificate header and cannot interpolate connection state, and it exposes no revocation check anywhere. So the platform emits no provider resource kind, no adapter, and no vendor CRD for the edge; it states the public intent and reports somebody else's observation as exactly that. Adding another ingress implementation changes the edge, not the platform.

## What the external edge must prove

For every request on the protected path, revision-bound conformance evidence must prove these controls:

1. The edge requires and successfully verifies a client certificate under the approved client CA, certificate policy, and revocation policy.
2. The edge removes or overwrites **all** inbound instances of `Client-Cert`, `Client-Cert-Chain`, legacy forwarded-certificate fields, verification markers, edge-auth fields, and user identity fields.
3. The edge adds canonical RFC 9440 fields only **after** successful verification.
4. The edge sends the request to the origin over an authenticated, confidential, integrity-protected, and replay-protected channel.
5. The edge authenticates as the exact approved edge workload identity.
6. The edge routes only the protected CAC/PIV login operation.
7. The edge prevents clients and unrelated workloads from reaching the protected auth-origin listener directly.

A static success marker, a source IP, namespace membership, or a shared header value is not proof of any of these.

### The five required evidence outcomes

The edge publishes one record per outcome into the object named by `edge.externalEvidenceRef`. All five outcomes are required. Each outcome covers one bypass path. Four proven outcomes leave the fifth path unchecked. An omitted outcome is unproven, never successful.

| Evidence                    | What it asserts                                                                                        | Reason when unproven                |
| --------------------------- | ------------------------------------------------------------------------------------------------------ | ----------------------------------- |
| `ClientCertificateEnforced` | the edge requires and validates client certificates for the path                                       | `ClientCertificateNotEnforced`      |
| `HeadersSanitized`          | caller-controlled certificate, verification, edge-auth, and identity fields are removed or overwritten | `AuthenticationHeadersNotSanitized` |
| `BackendAuthenticated`      | the proxy-origin hop is confidential and authenticates the approved edge                               | `AuthenticationBackendUntrusted`    |
| `PathRestricted`            | only the CAC/PIV login operation receives certificate forwarding                                       | `AuthenticationPathUnbounded`       |
| `DirectOriginDenied`        | clients and unrelated workloads cannot reach the protected origin                                      | `AuthenticationOriginExposed`       |

`RevocationEvidenceFresh` is a sixth record, bound to the profile's own revocation policy rather than to the edge capability, because the origin validates its freshness.

Evidence is `ExternallyObserved` only while it is bound to the running policy revision. A record for a superseded revision describes an edge that the administrator changed. The platform downgrades that record to `AdminAttested`. A regulated profile refuses attestation. The platform never reports external enforcement as platform-observed because the platform cannot see that enforcement. Such status falsely vouches for an unseen control.

See [edge-conformance-evidence.example.yaml](edge-conformance-evidence.example.yaml) and [revocation-evidence.example.yaml](revocation-evidence.example.yaml) for the record shape. **Do not apply a `Pass` record the edge did not produce.** The platform admits login on the strength of these records and publishes the forwarding route accordingly.

### Bounded forwarding path

`/api/auth/cac/login` is the only operation that admits certificate forwarding. The route requires an **exact** path match. A prefix match has the same defect as a wildcard. The `/api/auth/cac` prefix also admits every operation below it. The edge strips and adds certificate fields for every request on that route. Certificate authentication must not expose unrelated core, administrator, token, callback, or application paths.

The origin enforces the same bound independently: a forwarded certificate that arrived for any other original path is refused with `AuthenticationPathUnbounded`.

### Sanitization

Sanitization is the full fixed registry of certificate, chain, verification, edge-auth, and user identity field names — `sanitizeHeaders: AllCertificateVerificationEdgeAuthAndUserIdentityHeaders` — and not a per-install list, because a per-install list is a list that misses one. It covers the canonical RFC 9440 fields and the legacy forwarded-certificate fields alike; under the strict profile the presence of a legacy field means the edge did not overwrite what the caller sent, and the request is rejected.

The order matters: strip everything inbound first, verify the certificate, then add the canonical fields. An edge that adds before it strips forwards a caller-chosen certificate.

### Direct access to the protected origin

`directAccessPolicy: Deny` is the only posture that admits certificate login, and `DirectOriginDenied` evidence is required before login is admitted at all.

**The platform reports this condition, and the origin closes it. L4 policy cannot narrow it.** NetworkPolicies are additive. A policy added here only widens origin access. NetworkPolicy also selects at L3/L4, while the required bound is one L7 path. The origin port carries ordinary API traffic from authorized extensions. A blanket L4 restriction breaks that traffic without protecting only the CAC path.

The origin closes the path per request. It accepts certificate fields only on the protected path and from the authenticated edge identity. It refuses a caller that reaches the listener without the edge. The platform reports the exposure instead of claiming enforcement. Namespace access to the request surface is a separate admission with a separate owner and blast radius. It is not a side effect of certificate login. Therefore, `AuthenticationOriginExposed` is terminal until network policy or routing changes.

## What the auth origin enforces

- Parse `Client-Cert` and `Client-Cert-Chain` strictly as RFC 8941. Refuse a field that does not decode exactly. Never repair malformed input.
- Apply size and chain-length limits before identity processing. Reject duplicate singleton fields and malformed fields.
- Check certificate time, required usage, policy, and source identity. Use a named extraction strategy, never a regular expression over a subject.
- Require positive, fresh revocation evidence. The strict profile never fails open.
- Derive one opaque principal for each provider-scoped source identity. Keep the principal stable across certificate renewal.
- Create no local identity or session after a failed check.
- Make certificate-dependent and token-bearing responses non-cacheable.

### Authorization boundary

CAC/PIV proves an authentication event and a source identity. It grants nothing. ReBAC relationships control tenant membership, platform administration, workrooms, models, datasets, applications, and connectors. This profile requires an explicit relationship before session creation (`jitAdmission: PreAdmissionRequired`). Certificate possession, `admin` namespace membership, and gateway identity imply no relationship.

## What you have to supply

The platform provides none of this:

| You supply                                                                                      | Where it goes                                                                                      |
| ----------------------------------------------------------------------------------------------- | -------------------------------------------------------------------------------------------------- |
| The TLS edge itself, and its conformance evidence                                               | your infrastructure; the evidence object named in `edge.externalEvidenceRef`                       |
| A conformant Gateway with frontend validation in `AllowValidOnly` mode, on Gateway API >= 1.5.0 | [gateway-frontend-validation.yaml](gateway-frontend-validation.yaml) is the shape                  |
| The approved client certificate authority bundle                                                | `local-secrets/client-authorities.pem`, published as ConfigMap `cac-client-authorities`            |
| The proxy-origin mTLS identity                                                                  | [transport-policy-fragment.yaml](transport-policy-fragment.yaml), merged into administrator policy |
| The edge shared secret and the principal secret                                                 | Secret `cac-edge-origin`, generated locally (at least 32 characters each)                          |
| The issuer names your PKI publishes                                                             | Secret `cac-edge-origin` key `allowed-issuers`                                                     |
| Revocation data, refreshed inside its TTL                                                       | Secret `cac-revocation-source`, mounted read-only into the origin                                  |
| Complete NIST assurance evidence for the declared AAL and FAL                                   | protected ConfigMap `cac-assurance-evidence` in the security namespace                             |
| A published `AuthProfile` in administrator policy                                               | [auth-profile-fragment.yaml](auth-profile-fragment.yaml), merged into `policy.yaml`                |

The auth origin reads a revocation JSON document with a `generated_at` timestamp and revoked serials from your PKI. This example contains neither the document nor a field for it. Certificate serials identify credentials. Keep them in a Secret outside this repository.

## Files

| File                                                                             | Purpose                                                                           |
| -------------------------------------------------------------------------------- | --------------------------------------------------------------------------------- |
| [auth-profile-fragment.yaml](auth-profile-fragment.yaml)                         | a loadable `profiles` fragment; merge it as `authProfiles` in the policy document |
| [transport-policy-fragment.yaml](transport-policy-fragment.yaml)                 | loadable declaration of the proxy-origin mTLS identity                            |
| [platform-profile-selection.yaml](platform-profile-selection.yaml)               | merge patch selecting the approved profile by name                                |
| [gateway-frontend-validation.yaml](gateway-frontend-validation.yaml)             | reference shape for the administrator-owned Gateway                               |
| [edge-conformance-evidence.example.yaml](edge-conformance-evidence.example.yaml) | shape of the five conformance records (not for applying)                          |
| [revocation-evidence.example.yaml](revocation-evidence.example.yaml)             | shape of the revocation record (not for applying)                                 |
| [assurance-evidence.example.yaml](assurance-evidence.example.yaml)               | shape of the protected NIST assurance record (not for applying)                   |
| [core-values-snippet.yaml](core-values-snippet.yaml)                             | auth-origin configuration for the Helmfile lifecycle                              |
| [kustomization.yaml](kustomization.yaml)                                         | generates `cac-edge-origin` and `cac-client-authorities` from local files         |

## Steps

1. **Stand up and prove the edge.** Every scenario in the edge conformance matrix must pass. The run produces five edge records and the revocation record. A separate complete NIST conformance run produces the AAL and FAL assurance record. Login stays closed until all required evidence exists for the current policy revision.

2. **Create the local material and apply the generated objects:**

```bash
mkdir -p security/cac/local-secrets
openssl rand -base64 48 | tr -d '\n' > security/cac/local-secrets/edge-shared-secret
openssl rand -base64 48 | tr -d '\n' > security/cac/local-secrets/principal-secret
printf '["<issuer distinguished names your PKI publishes>"]' > security/cac/local-secrets/allowed-issuers
cp <your client authority bundle>.pem security/cac/local-secrets/client-authorities.pem
kubectl apply --server-side --dry-run=server -k security/cac -o name
kubectl apply -k security/cac
```

3. **Publish the profile and transport identity.** Validate `auth-profile-fragment.yaml` with the operator auth-profile loader. Validate `transport-policy-fragment.yaml` with the transport-policy loader. Merge the profile list as `authProfiles`. Append the identity to the existing `transport.clientIdentities` list in AdminCapabilityPolicy. Do not replace other transport settings. Bump `adminPolicy.revision` because the policy ConfigMap is immutable. Record new edge, revocation, and assurance evidence for the new revision.

4. **Point the Gateway at the authorities.** Add `spec.tls.frontend.default.validation` to the administrator-owned Gateway as shown in `gateway-frontend-validation.yaml`. On Gateway API 1.4 and below these fields are silently pruned, which leaves no client-certificate requirement at all.

5. **Select the profile:**

```bash
kubectl -n kamiwaza patch kamiwazaplatform kamiwaza \
  --type merge --patch-file security/cac/platform-profile-selection.yaml
```

6. **Configure the origin.** On the Helmfile lifecycle, merge `core-values-snippet.yaml` into `cluster/values/overrides.yaml` and sync. Setting `AUTH_GATEWAY_CAC_EDGE_PROFILE=rfc9440` is what selects the strict contract; leaving it unset keeps the installation's existing behaviour unchanged.

The profile claims `AAL3` and `FAL2` only while `cac-assurance-evidence` contains externally observed, revision-bound evidence at or above both floors. Do not copy the sample record. Remove the minimums and `evidenceRef` together if the installation has no complete NIST evidence set.

## Verification

```bash
# The published certificate-login verdict: allowed, evidence class, and reason.
kubectl -n kamiwaza get kamiwazaplatform kamiwaza \
  -o jsonpath='{range .status.capabilities[?(@.name=="certificateLogin")]}{.allowed}{"\t"}{.source}{"\t"}{.reason}{"\n"}{end}'

# One advisory per unproven control, so every open action is visible at once.
kubectl -n kamiwaza get kamiwazaplatform kamiwaza \
  -o jsonpath='{range .status.advisories[?(@.capability=="certificateLogin")]}{.reason}{"\t"}{.message}{"\n"}{end}'

# The standard objects the platform publishes for the protected operation.
kubectl -n kamiwaza get httproute cac-login -o yaml
kubectl -n kamiwaza get backendtlspolicy cac-login-origin
kubectl -n kamiwaza get configmap cac-client-authorities

# The listener proof the platform credits: all three, at the observed generation.
kubectl -n kamiwaza get gateway kamiwaza-gateway \
  -o jsonpath='{range .status.listeners[*]}{.name}{"\t"}{range .conditions[*]}{.type}={.status}{" "}{end}{"\n"}{end}'
```

`source` is `ExternallyObserved` or `AdminAttested` and never `PlatformObserved`. `allowed: false` with a reason is the fail-closed state, not an error: the platform publishes no forwarding route for an unproven edge.

## Failure reasons

| Reason                              | Trigger                                                    | Retry class                   |
| ----------------------------------- | ---------------------------------------------------------- | ----------------------------- |
| `AuthenticationEdgeUnavailable`     | required edge capability absent, unreadable, or superseded | retryable                     |
| `ClientCertificateNotEnforced`      | edge does not prove client-certificate validation          | terminal until policy changes |
| `AuthenticationHeadersNotSanitized` | sanitization proof absent or incomplete                    | terminal until edge changes   |
| `AuthenticationBackendUntrusted`    | proxy-origin authentication or confidentiality absent      | by observed cause             |
| `AuthenticationPathUnbounded`       | forwarding reaches unapproved paths                        | terminal until route changes  |
| `AuthenticationOriginExposed`       | direct protected-origin access is possible                 | terminal until policy changes |
| `RevocationEvidenceUnavailable`     | evidence missing, empty, stale, or unreachable             | retryable; login stays closed |
| `ClientCertificateRejected`         | chain, time, usage, policy, or revocation check failed     | terminal for that attempt     |
| `IdentityContextIncomplete`         | source identity, assurance, or ReBAC pre-admission missing | terminal for that attempt     |

## Migration from the previous version of this example

The previous version configured a specific ingress product through vendor `Middleware` and `IngressRoute` kinds. It also put a **plaintext edge shared secret in a Middleware header**. The credential then appeared in a values file, Git, and every rendered manifest. This contract contains none of those surfaces.

An installation with the previous configuration continues to work. The auth origin keeps the legacy forwarded-header flow as the default. An unset `AUTH_GATEWAY_CAC_EDGE_PROFILE` preserves that behavior. Migration requires canonical RFC 9440 fields, five proven outcomes, and rotation of the previously committed shared secret.
