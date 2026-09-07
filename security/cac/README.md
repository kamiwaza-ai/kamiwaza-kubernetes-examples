# CAC / PIV login through an external authentication edge

**Scenario:** admit CAC/PIV certificate login on one platform, where the client certificate is required and verified by an **enterprise TLS edge the administrator owns**. The platform does not run that edge. This example shows what the edge has to prove, what the auth origin enforces, and what the platform publishes and reports — not a configuration that pretends the platform provides the edge.

**Tags:** #security #cac #piv #mtls #external-edge #gateway-api

Every value in this directory is an obviously synthetic placeholder. No credential, private key, certificate body, real host name, distinguished name, EDIPI, FASC-N, certificate serial, or email address appears in any file here, including comments and sample output — the single host name is the reserved documentation domain `kamiwaza.example.com`, and the single port is the registered HTTPS port. A CAC/PIV certificate subject identifies a person, so this example deliberately leaves no field for one to be pasted into: certificate authorities, issuer names, and revocation data all arrive from local files or referenced objects that stay out of Git.

## The split

| Half of the contract                                                                                       | Who owns it       | How it is proven                                                                             |
| ---------------------------------------------------------------------------------------------------------- | ----------------- | -------------------------------------------------------------------------------------------- |
| Requiring and verifying the client certificate                                                             | administrator     | Gateway API frontend validation; the platform reads `Programmed`, `ResolvedRefs`, `Accepted` |
| Forwarding the verified certificate, sanitizing headers, bounding the path, keeping clients off the origin | administrator     | recorded conformance evidence the platform reads by exact name                               |
| Strict parsing, revocation freshness, principal mapping, session policy                                    | platform (origin) | enforced per request; fail-closed                                                            |
| Which operation is forwarded, which Service serves it, which authorities validate                          | platform          | standard `HTTPRoute`, `BackendTLSPolicy`, and client-authority `ConfigMap` only              |

Certificate forwarding is **not expressible in the routing standard**. Gateway API defines no client-certificate header and cannot interpolate connection state, and it exposes no revocation check anywhere. So the platform emits no provider resource kind, no adapter, and no vendor CRD for the edge; it states the public intent and reports somebody else's observation as exactly that. Adding another ingress implementation changes the edge, not the platform.

## What the external edge must prove

For every request on the protected path, the edge must prove through revision-bound conformance evidence that it:

1. required and successfully verified a client certificate under the approved client-CA, certificate-policy, and revocation policy;
2. removed or overwrote **all** inbound instances of `Client-Cert`, `Client-Cert-Chain`, the legacy forwarded-certificate fields, verification markers, edge-auth fields, and user identity fields;
3. added the canonical RFC 9440 fields only **after** successful verification;
4. sent the request to the origin over an authenticated, confidential, integrity- and replay-protected channel;
5. authenticated as the exact approved edge workload identity;
6. routed only the protected CAC/PIV login operation; and
7. prevented clients and unrelated workloads from reaching the protected auth-origin listener directly.

A static success marker, a source IP, namespace membership, or a shared header value is not proof of any of these.

### The five required evidence outcomes

The edge publishes one record per outcome into the object the profile names in `edge.externalEvidenceRef`. All five are required rather than selectable: each covers one way the edge can be bypassed, so four proven outcomes leave the fifth unchecked. An outcome the document is silent about is reported as unproven, never as success.

| Evidence                    | What it asserts                                                                                        | Reason when unproven                |
| --------------------------- | ------------------------------------------------------------------------------------------------------ | ----------------------------------- |
| `ClientCertificateEnforced` | the edge requires and validates client certificates for the path                                       | `ClientCertificateNotEnforced`      |
| `HeadersSanitized`          | caller-controlled certificate, verification, edge-auth, and identity fields are removed or overwritten | `AuthenticationHeadersNotSanitized` |
| `BackendAuthenticated`      | the proxy-origin hop is confidential and authenticates the approved edge                               | `AuthenticationBackendUntrusted`    |
| `PathRestricted`            | only the CAC/PIV login operation receives certificate forwarding                                       | `AuthenticationPathUnbounded`       |
| `DirectOriginDenied`        | clients and unrelated workloads cannot reach the protected origin                                      | `AuthenticationOriginExposed`       |

`RevocationEvidenceFresh` is a sixth record, bound to the profile's own revocation policy rather than to the edge capability, because the origin validates its freshness.

Evidence is credited as `ExternallyObserved` only while it is bound to the running policy revision. A record recorded against a superseded revision describes an edge the administrator has since changed, so it is downgraded to `AdminAttested`; a regulated profile refuses attestation outright. External enforcement is never reported as platform-observed — the platform cannot see it, and a status that claimed otherwise would be the platform vouching for a control it has no view of.

See [edge-conformance-evidence.example.yaml](edge-conformance-evidence.example.yaml) and [revocation-evidence.example.yaml](revocation-evidence.example.yaml) for the record shape. **Do not apply a `Pass` record the edge did not produce.** The platform admits login on the strength of these records and publishes the forwarding route accordingly.

### Bounded forwarding path

`/api/auth/cac/login` is the only operation certificate forwarding is admitted for, and only as an **exact** path match. A prefix match is refused for the same reason a wildcard would be: `/api/auth/cac` as a prefix also admits every operation below it, and the edge strips and re-adds certificate fields for whatever arrives on that route. Enabling certificate authentication must not expose unrelated core, administrator, token, callback, or application paths through the forwarding route.

The origin enforces the same bound independently: a forwarded certificate that arrived for any other original path is refused with `AuthenticationPathUnbounded`.

### Sanitization

Sanitization is the full fixed registry of certificate, chain, verification, edge-auth, and user identity field names — `sanitizeHeaders: AllCertificateVerificationEdgeAuthAndUserIdentityHeaders` — and not a per-install list, because a per-install list is a list that misses one. It covers the canonical RFC 9440 fields and the legacy forwarded-certificate fields alike; under the strict profile the presence of a legacy field means the edge did not overwrite what the caller sent, and the request is rejected.

The order matters: strip everything inbound first, verify the certificate, then add the canonical fields. An edge that adds before it strips forwards a caller-chosen certificate.

### Direct access to the protected origin

`directAccessPolicy: Deny` is the only posture that admits certificate login, and `DirectOriginDenied` evidence is required before login is admitted at all.

**This is reported by the platform and closed by the origin. It is not narrowed at L4, and it cannot be.** NetworkPolicies union, so a policy added here could only widen what reaches the origin and would enforce nothing. The narrowing that would be needed is not expressible either: NetworkPolicy selects at L3/L4, the thing to bound is one L7 path, and the origin port also carries ordinary API traffic that extensions are entitled to make. A blanket L4 narrowing would break the platform to protect a path.

So the origin closes it per request — it accepts certificate fields only on the protected path and only from the authenticated edge identity, and a caller that reaches the listener without traversing the edge is refused — and the platform reports the exposure rather than pretending to enforce it. Which namespaces may reach the request surface at all is a separate admission with its own blast radius and its own owner; it is not a side effect of enabling certificate login. `AuthenticationOriginExposed` is terminal until network policy or routing changes for exactly this reason.

## What the auth origin enforces

- strict RFC 8941 parsing of `Client-Cert` and `Client-Cert-Chain`; a field that does not decode exactly is refused, never repaired, because a parser that fixes a nearly-right field cannot tell a conformant edge from a caller who guessed the encoding;
- configured size and chain-length limits, and rejection of duplicate singleton or malformed fields, before any identity processing;
- certificate time, required usage and policy, and source-identity extraction by named strategy — never a regex over a subject, which is how an attacker-chosen field becomes the principal;
- positive and fresh revocation evidence, with no fail-open under the strict profile;
- one opaque, non-reused principal per provider-scoped source identity, stable across certificate renewal;
- no local identity and no session on any failed check; and
- non-cacheable certificate-dependent and token-bearing responses.

### Authorization boundary

CAC/PIV proves an authentication event and a source identity. It grants nothing. Tenant membership, platform administration, and access to workrooms, models, datasets, applications, and connectors are ReBAC relationships, and this profile requires an explicit relationship before a session is created (`jitAdmission: PreAdmissionRequired`). Certificate possession, `admin` namespace membership, and gateway identity imply no relationship.

## What you have to supply

The platform provides none of this:

| You supply                                                                                      | Where it goes                                                                           |
| ----------------------------------------------------------------------------------------------- | --------------------------------------------------------------------------------------- |
| The TLS edge itself, and its conformance evidence                                               | your infrastructure; the evidence object named in `edge.externalEvidenceRef`            |
| A conformant Gateway with frontend validation in `AllowValidOnly` mode, on Gateway API >= 1.5.0 | [gateway-frontend-validation.yaml](gateway-frontend-validation.yaml) is the shape       |
| The approved client certificate authority bundle                                                | `local-secrets/client-authorities.pem`, published as ConfigMap `cac-client-authorities` |
| The edge workload identity for the proxy-origin hop                                             | `edge.backendClientIdentityRef` in administrator policy                                 |
| The edge shared secret and the principal secret                                                 | Secret `cac-edge-origin`, generated locally (at least 32 characters each)               |
| The issuer names your PKI publishes                                                             | Secret `cac-edge-origin` key `allowed-issuers`                                          |
| Revocation data, refreshed inside its TTL                                                       | Secret `cac-revocation-source`, mounted read-only into the origin                       |
| A published `AuthProfile` in administrator policy                                               | [auth-profile-fragment.yaml](auth-profile-fragment.yaml), merged into `policy.yaml`     |

The revocation document the origin reads is a JSON object with a `generated_at` timestamp and the revoked serials your PKI publishes. This example ships no copy of it and no field for it: those serials are certificate identifiers, and the file belongs in a Secret you create outside this repository.

## Files

| File                                                                             | Purpose                                                                   |
| -------------------------------------------------------------------------------- | ------------------------------------------------------------------------- |
| [auth-profile-fragment.yaml](auth-profile-fragment.yaml)                         | the `authProfiles` entry to merge into the operator's policy document     |
| [platform-profile-selection.yaml](platform-profile-selection.yaml)               | merge patch selecting the approved profile by name                        |
| [gateway-frontend-validation.yaml](gateway-frontend-validation.yaml)             | reference shape for the administrator-owned Gateway                       |
| [edge-conformance-evidence.example.yaml](edge-conformance-evidence.example.yaml) | shape of the five conformance records (not for applying)                  |
| [revocation-evidence.example.yaml](revocation-evidence.example.yaml)             | shape of the revocation record (not for applying)                         |
| [core-values-snippet.yaml](core-values-snippet.yaml)                             | auth-origin configuration for the Helmfile lifecycle                      |
| [kustomization.yaml](kustomization.yaml)                                         | generates `cac-edge-origin` and `cac-client-authorities` from local files |

## Steps

1. **Stand up and prove the edge.** Every scenario in the conformance matrix of the edge contract has to pass, and the run has to produce the five records plus the revocation record. Login stays closed until it does.

2. **Create the local material and apply the generated objects:**

```bash
mkdir -p security/cac/local-secrets
openssl rand -base64 48 | tr -d '\n' > security/cac/local-secrets/edge-shared-secret
openssl rand -base64 48 | tr -d '\n' > security/cac/local-secrets/principal-secret
printf '["<issuer distinguished names your PKI publishes>"]' > security/cac/local-secrets/allowed-issuers
cp <your client authority bundle>.pem security/cac/local-secrets/client-authorities.pem
kubectl diff -k security/cac
kubectl apply -k security/cac
```

3. **Publish the profile.** Merge the `authProfiles` entry from `auth-profile-fragment.yaml` into the AdminCapabilityPolicy document the operator chart mounts, and bump `adminPolicy.revision`. The policy ConfigMap is immutable, so a changed document needs a new revision; evidence recorded against the old revision is downgraded to attestation, and a regulated profile refuses it, so re-record the conformance evidence after the bump.

4. **Point the Gateway at the authorities.** Add `spec.tls.frontend.default.validation` to the administrator-owned Gateway as shown in `gateway-frontend-validation.yaml`. On Gateway API 1.4 and below these fields are silently pruned, which leaves no client-certificate requirement at all.

5. **Select the profile:**

```bash
kubectl -n kamiwaza patch kamiwazaplatform kamiwaza \
  --type merge --patch-file security/cac/platform-profile-selection.yaml
```

6. **Configure the origin.** On the Helmfile lifecycle, merge `core-values-snippet.yaml` into `cluster/values/overrides.yaml` and sync. Setting `AUTH_GATEWAY_CAC_EDGE_PROFILE=rfc9440` is what selects the strict contract; leaving it unset keeps the installation's existing behaviour unchanged.

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

The previous version configured a specific ingress product directly: vendor `Middleware` and `IngressRoute` kinds, non-standard forwarded-certificate field names, and a **plaintext copy of the edge shared secret in a Middleware header**, which put the credential in a values file, in Git, and in every rendered manifest. None of that is part of this contract and the platform emits none of it.

An installation still running that configuration keeps working: the auth origin's legacy forwarded-header flow is unchanged and remains the default, and `AUTH_GATEWAY_CAC_EDGE_PROFILE` unset means exactly today's behaviour. Moving to the contract above means moving your edge to the canonical RFC 9440 fields, proving the five outcomes, and rotating the shared secret that was previously committed.
