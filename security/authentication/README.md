# Enterprise authentication variants

## Purpose

Run five independent authentication profiles: built-in Keycloak, brokered OIDC, SAML, LDAP through Keycloak, and X.509 CAC. Administrator values own trust and provider configuration. Each tenant `KamiwazaPlatform` selects only one approved profile name.

## Grounded design

Confluent's [authentication examples](https://github.com/confluentinc/confluent-kubernetes-examples/tree/master/security) separate identity-provider prerequisites from application custom resources. Kamiwaza strengthens that split: issuer, destination, audience, assurance, session, edge evidence, and Secret or ConfigMap references live in immutable administrator policy. Tenant manifests contain no provider endpoint, credential, certificate, or claim-mapping override.

## Variant matrix

| Variant  | Entry point         | External prerequisites                                              | Required negative result                      |
| -------- | ------------------- | ------------------------------------------------------------------- | --------------------------------------------- |
| Built-in | `variants/built-in` | bootstrap and durable-admin Secrets                                 | malformed bearer denied                       |
| OIDC     | `variants/oidc`     | pinned metadata, client Secret, approved HTTPS destination          | issuer or signature mismatch denied           |
| SAML     | `variants/saml`     | IdP metadata and SP signing Secret                                  | unsigned, stale, or replayed assertion denied |
| LDAP     | `variants/ldap`     | bind Secret and approved TLS directory                              | TLS, bind, or immutable-ID mismatch denied    |
| CAC      | `variants/cac`      | client CA, revocation evidence, edge evidence, edge client identity | direct origin and forged headers denied       |

Names and keys are declared in `operator-values.yaml`; values are not. Replace every `example.com` or `example.invalid` authority with reviewed infrastructure. Do not commit generated Secrets, metadata containing private endpoints, identities, certificate material, or browser session output.

Built-in initialization seeds only `identity-bootstrap-admin` and `default-platform-admin`. Create routine users, groups, admission decisions, and grants through authenticated application APIs. They are application data, not Kubernetes desired state.

## Install and run one variant

Install one operator release with `operator-values.yaml`. It watches five explicit namespaces so each entry point remains standalone.

```bash
VARIANT=oidc
kubectl diff --server-side --field-manager=platform-operator-user -k variants/${VARIANT}
kubectl apply --server-side --field-manager=platform-operator-user -k variants/${VARIANT}
kubectl -n kw-auth-${VARIANT} wait --for=condition=Ready kamiwazaplatform/kamiwaza --timeout=30m
kubectl -n kw-auth-${VARIANT} logs job/auth-check
```

Before `Ready=True`, require the current generation on platform and identity conditions. For OIDC, SAML, or LDAP outage, expect `Ready=False` with a dependency-specific transient reason. Restore the same endpoint or Secret and require recovery without deleting Keycloak, PostgreSQL, authorization data, Pods, or finalizers.

## Positive and negative checks

`auth-checks.yaml` performs unauthenticated denial plus bounded discovery or protocol rejection. Replace public authorities first. Complete one browser sign-in only where redirect protocols require it. Confirm runtime identity uses the provider's immutable subject and the configured audience, ACR/AMR, tenant context, and ReBAC checks.

Run one provider-specific invalid case in disposable infrastructure:

- OIDC: wrong issuer, audience, signature, required ACR, or required AMR.
- SAML: unsigned assertion, wrong audience, expired assertion, and replay.
- LDAP: unavailable StartTLS, invalid bind, and changed username with unchanged `entryUUID`.
- CAC: untrusted issuer, missing client-auth EKU, stale revocation evidence, oversized header, and direct-origin forged headers.

Every case must fail closed. Do not weaken policy to make a provider pass. Current reconciliation must materially project each selected profile into Keycloak, Core, and edge configuration; policy acceptance alone is not a passing authentication test.

## Cleanup

```bash
kubectl delete -k variants/oidc
kubectl -n kw-auth-oidc get pvc
```

`RetainData` preserves local identity and authorization state. External providers and trust stores remain administrator-owned.
