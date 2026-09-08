# Security scenarios index

This folder follows a scenario-first layout: one subdirectory per runnable security pattern, each with a `README.md`, explicit prerequisites, step ordering, and verification commands.

## Dimensions

| Dimension           | Options in this repo today                                                 |
| ------------------- | -------------------------------------------------------------------------- |
| Identity source     | Keycloak local users, LDAP federation, CAC/PIV cert flow                   |
| Authorization model | RBAC baseline, optional ReBAC tenant-aware checks                          |
| TLS / mTLS          | Standard TLS, client-certificate validation at an administrator-owned edge |
| Transport planes    | Issuance, trust distribution, edge, internal hops, egress                  |
| Secret handling     | Kubernetes Secrets (templates + kustomize generation for local labs)       |
| Values integration  | Merge snippets into Deploy `cluster/values/overrides.yaml`                 |

## Scenario matrix

| Scenario                         | Identity source              | Authorization                     | TLS / mTLS                                                     | Key toggles / knobs                                                                                                          | Main artifacts                                                                                                                   |
| -------------------------------- | ---------------------------- | --------------------------------- | -------------------------------------------------------------- | ---------------------------------------------------------------------------------------------------------------------------- | -------------------------------------------------------------------------------------------------------------------------------- |
| [consent-banner](consent-banner) | Pre-login consent UX         | N/A                               | TLS                                                            | `core.security.consent.enabled`, `core.security.banner.enabled`                                                              | Kustomize ConfigMap + values snippet                                                                                             |
| [cac](cac)                       | CAC/PIV certificate login    | ReBAC pre-admission               | client certificates at an external edge                        | auth profile `X509CAC` method, `AUTH_GATEWAY_CAC_EDGE_PROFILE=rfc9440`                                                       | Auth profile fragment + platform patch + Gateway reference + evidence shapes + values snippet                                    |
| [rebac](rebac)                   | Keycloak JWT claims          | ReBAC, producer-owned grant edges | TLS                                                            | `AUTH_GATEWAY_GRANT_PRODUCER_PROFILE=producer_owned`, `AUTH_GATEWAY_ROLE_SEPARATION_PROFILE=least_privilege`, `core.rebac.*` | Plan/diff/apply workflow script + `GrantManifest` examples (one refused on purpose) + values snippet + tenant registry fragments |
| [ldap](ldap)                     | LDAP via Keycloak federation | RBAC/ReBAC compatible             | TLS                                                            | `auth.enabled: true` + declarative read-only Keycloak federation bundle                                                      | Digest-pinned kustomize stack (directory + bootstrap Job) + declarative bundle + auth profile fragment                           |
| [tls-trust](tls-trust)           | N/A (transport trust)        | N/A                               | Custom CA + BYO TLS                                            | `core.trustManager.enabled`, `AWS_CA_BUNDLE`/`SSL_CERT_FILE`, `build-trust-bundle-configmap.sh`                              | Values snippet + CA Secret (kustomize/template) + build-trust-bundle-configmap.sh + BYO ingress manifests + verify.sh            |
| [external-edge](external-edge)   | N/A (transport edge)         | N/A                               | platform-issued listener certificate, edge client certificates | `transport.edge.*`, Gateway API `>= 1.5.0` for client certificates                                                           | Transport policy fragment + Gateway listener contract + one refused fragment                                                     |
| [egress](egress)                 | N/A (outbound)               | N/A                               | TLS and mutual TLS per destination class                       | `transport.egress.destinations[]`, `enforcementMode`, `transport.egress.proxies[]`                                           | Transport policy fragment with five destination classes + two refused fragments                                                  |
| [failure-modes](failure-modes)   | N/A                          | N/A                               | `AdministratorSupplied` issuance                               | `transport.issuance.mode: AdministratorSupplied`, `expiryWarningBefore`                                                      | The reason and retry-class table + one loadable fragment + two refused fragments                                                 |
| [migration](migration)           | N/A                          | N/A                               | staged adoption of the transport planes                        | absence of `transport` means today's behaviour; `expirationPolicy`                                                           | Three staged policy fragments, one accepted in Full and refused in regulated                                                     |
| [rotation-drain](rotation-drain) | N/A                          | N/A                               | authority rotation, connection drain                           | `expirationPolicy`, `maxConnectionAge`, `transport.kamiwaza.io/rotate-authority`                                             | Transport policy fragment + rotation request patch + one refused fragment                                                        |

## Structure expectations for new scenarios

Keep each scenario self-contained:

1. `README.md` with goal, prerequisites, steps, and verification.
2. `*-snippet.yaml` for Helm values overlays (when chart settings are needed).
3. Kubernetes manifests and/or kustomization files in the same scenario folder.
4. Optional sample data/scripts clearly marked as lab-only.
5. `*-fragment.yaml` for administrator policy fragments, with the root key the published schema declares, so a fragment can be validated before it is merged.
6. At least one refused example per scenario, named `*-refused.yaml`, with the observed refusal quoted in its header. A directory that only shows the happy path teaches nothing about what a cluster does when a dependency is missing, which is when the example is read.
7. A "How this example was validated" section naming the validator per file and its result. Validate against a parser, a schema, or the platform's own loader — never by eye. A published example that does not load costs a reader their own debugging time on somebody else's mistake.
