# CAC / PIV login (mTLS + certificate forwarding)

**Scenario:** enable CAC login for Kamiwaza by combining Traefik mTLS, header sanitization, and auth-gateway CAC settings. This mirrors Deploy `cluster/values/values-cac.yaml`, but in reusable example form with safe placeholders (no real secrets).

**Tags:** #security #cac #mtls #helm-values

## What you get

- **`core-values-snippet.yaml`**: Helm values overlay for CAC env vars + Traefik middlewares/route for `POST /api/auth/cac/login`.
- **`kustomization.yaml`**: local-secret driven generator for `auth-gateway-edge` + `traefik-client-ca`.
- **`auth-gateway-edge-secret.template.yaml`** and **`traefik-client-ca-secret.template.yaml`**: direct apply templates if you prefer explicit manifests.

## Prerequisites

- Kamiwaza deployed with auth enabled (`auth.enabled: true`).
- Access to Deploy values layering (e.g. `cluster/values/overrides.yaml`).
- A CAC/PKI workflow that provides:
  - a client certificate CA bundle (PEM), and
  - a shared edge secret value.

## Steps

1. Create required Secrets in namespace `kamiwaza` (pick one approach):

```bash
# Option A (recommended): kustomize with local secret files
mkdir -p security/cac/local-secrets
cp security/cac/auth-gateway-edge.secret.example security/cac/local-secrets/auth-gateway-edge.secret
cp security/cac/traefik-client-ca.crt.example security/cac/local-secrets/traefik-client-ca.crt
# edit both files with real values first
kubectl apply -k security/cac

# Option B: apply explicit Secret templates
# 1) shared edge secret (same cleartext used in values snippet middleware header)
kubectl apply -f security/cac/auth-gateway-edge-secret.template.yaml

# 2) client CA bundle secret referenced by Traefik tlsOptions.mtls.clientAuth.secretNames
kubectl apply -f security/cac/traefik-client-ca-secret.template.yaml
```

2. Merge `security/cac/core-values-snippet.yaml` into Deploy `cluster/values/overrides.yaml` (or equivalent later-layer values file).

3. Replace placeholders before sync:

   - `AUTH_GATEWAY_CAC_ALLOWED_ISSUERS`
   - `REPLACE_WITH_EDGE_SHARED_SECRET` (must match Secret `auth-gateway-edge` key `secret`)
   - ``Host(`kamiwaza.test`)`` if your domain differs

4. Sync Helm values (from Deploy repo):

```bash
helmfile -f cluster/helmfile.yaml.gotmpl -e full sync
```

5. Restart scheduler if needed:

```bash
kubectl rollout restart deployment/core-scheduler -n kamiwaza
```

## Verification

```bash
# secrets required by snippet
kubectl -n kamiwaza get secret auth-gateway-edge traefik-client-ca

# scheduler env includes CAC flags
kubectl -n kamiwaza exec deploy/core-scheduler -c core -- env | grep '^AUTH_GATEWAY_CAC_'

# route/middlewares rendered by values snippet
kubectl -n kamiwaza get ingressroute core-auth-cac-login
kubectl -n kamiwaza get middleware cac-strip-auth-headers cac-pass-client-cert cac-edge-auth
```

For API/runtime details, see `kamiwaza/docs-internal/topics/auth/setup.md` in the Kamiwaza repo.

## Notes

- This example intentionally avoids generating PKI artifacts. Bring your org PKI or a separate dev PKI bootstrap workflow.
- Do not commit real issuer DNs, cert material, or shared secrets.
