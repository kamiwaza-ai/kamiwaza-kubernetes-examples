# Security scenarios index

This folder follows a scenario-first layout: one subdirectory per runnable security pattern, each with a `README.md`, explicit prerequisites, step ordering, and verification commands.

## Dimensions

| Dimension           | Options in this repo today                                           |
| ------------------- | -------------------------------------------------------------------- |
| Identity source     | Keycloak local users, LDAP federation, CAC/PIV cert flow             |
| Authorization model | RBAC baseline, optional ReBAC tenant-aware checks                    |
| TLS / mTLS          | Standard TLS, Traefik mTLS for CAC endpoint                          |
| Secret handling     | Kubernetes Secrets (templates + kustomize generation for local labs) |
| Values integration  | Merge snippets into Deploy `cluster/values/overrides.yaml`           |

## Scenario matrix

| Scenario                         | Identity source              | Authorization                | TLS / mTLS             | Key toggles / knobs                                                            | Main artifacts                                                                             |
| -------------------------------- | ---------------------------- | ---------------------------- | ---------------------- | ------------------------------------------------------------------------------ | ------------------------------------------------------------------------------------------ |
| [consent-banner](consent-banner) | Pre-login consent UX         | N/A                          | TLS                    | `core.security.consent.enabled`, `core.security.banner.enabled`                | Kustomize ConfigMap + values snippet                                                       |
| [cac](cac)                       | CAC/PIV certificate login    | RBAC/ReBAC compatible        | mTLS + cert-forwarding | `AUTH_GATEWAY_CAC_*`, `AUTH_GATEWAY_MTLS_REQUIRED`, Traefik `tlsOptions.mtls`  | Values snippet + secret templates + kustomize secret generator                             |
| [rebac](rebac)                   | Keycloak JWT claims          | ReBAC (tenant-scoped tuples) | TLS                    | `core.rebac.*`, `core.scheduler.rebac.*`, optional tenant registry enforcement | Values snippets + tenant manifest examples                                                 |
| [ldap](ldap)                     | LDAP via Keycloak federation | RBAC/ReBAC compatible        | TLS                    | `auth.enabled: true` + declarative Keycloak federation bundle                  | Kustomize stack (OpenLDAP, UI, Jobs) + declarative Keycloak bundle + optional LDIF samples |
| [tls-trust](tls-trust)           | N/A (transport trust)        | N/A                          | Custom CA + BYO TLS     | `ca.trustBundle.customerCASecret`, `core.trustManager.enabled`, `AWS_CA_BUNDLE`/`SSL_CERT_FILE` | Values snippet + CA Secret (kustomize/template) + BYO ingress manifests + verify.sh |

## Structure expectations for new scenarios

Keep each scenario self-contained:

1. `README.md` with goal, prerequisites, steps, and verification.
2. `*-snippet.yaml` for Helm values overlays (when chart settings are needed).
3. Kubernetes manifests and/or kustomization files in the same scenario folder.
4. Optional sample data/scripts clearly marked as lab-only.
