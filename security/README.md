# Security scenarios index

This folder follows a scenario-first layout: one subdirectory per runnable security pattern, each with a `README.md`, explicit prerequisites, step ordering, and verification commands.

## Dimensions

| Dimension           | Options in this repo today                                                 |
| ------------------- | -------------------------------------------------------------------------- |
| Identity source     | Keycloak local users, LDAP federation, CAC/PIV cert flow                   |
| Authorization model | RBAC baseline, optional ReBAC tenant-aware checks                          |
| TLS / mTLS          | Standard TLS, client-certificate validation at an administrator-owned edge |
| Secret handling     | Kubernetes Secrets (templates + kustomize generation for local labs)       |
| Values integration  | Merge snippets into Deploy `cluster/values/overrides.yaml`                 |

## Scenario matrix

| Scenario                         | Identity source              | Authorization                     | TLS / mTLS                              | Key toggles / knobs                                                                                                          | Main artifacts                                                                                                                   |
| -------------------------------- | ---------------------------- | --------------------------------- | --------------------------------------- | ---------------------------------------------------------------------------------------------------------------------------- | -------------------------------------------------------------------------------------------------------------------------------- |
| [consent-banner](consent-banner) | Pre-login consent UX         | N/A                               | TLS                                     | `core.security.consent.enabled`, `core.security.banner.enabled`                                                              | Kustomize ConfigMap + values snippet                                                                                             |
| [cac](cac)                       | CAC/PIV certificate login    | ReBAC pre-admission               | client certificates at an external edge | auth profile `X509CAC` method, `AUTH_GATEWAY_CAC_EDGE_PROFILE=rfc9440`                                                       | Auth profile fragment + platform patch + Gateway reference + evidence shapes + values snippet                                    |
| [rebac](rebac)                   | Keycloak JWT claims          | ReBAC, producer-owned grant edges | TLS                                     | `AUTH_GATEWAY_GRANT_PRODUCER_PROFILE=producer_owned`, `AUTH_GATEWAY_ROLE_SEPARATION_PROFILE=least_privilege`, `core.rebac.*` | Plan/diff/apply workflow script + `GrantManifest` examples (one refused on purpose) + values snippet + tenant registry fragments |
| [ldap](ldap)                     | LDAP via Keycloak federation | RBAC/ReBAC compatible             | TLS                                     | `auth.enabled: true` + declarative read-only Keycloak federation bundle                                                      | Digest-pinned kustomize stack (directory + bootstrap Job) + declarative bundle + auth profile fragment                           |
| [tls-trust](tls-trust)           | N/A (transport trust)        | N/A                               | Custom CA + BYO TLS                     | `core.trustManager.enabled`, `AWS_CA_BUNDLE`/`SSL_CERT_FILE`, `build-trust-bundle-configmap.sh`                              | Values snippet + CA Secret (kustomize/template) + build-trust-bundle-configmap.sh + BYO ingress manifests + verify.sh            |

## Structure expectations for new scenarios

Keep each scenario self-contained:

1. `README.md` with goal, prerequisites, steps, and verification.
2. `*-snippet.yaml` for Helm values overlays (when chart settings are needed).
3. Kubernetes manifests and/or kustomization files in the same scenario folder.
4. Optional sample data/scripts clearly marked as lab-only.
