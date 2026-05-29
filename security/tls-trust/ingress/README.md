# BYO ingress cert — serve Kamiwaza's public TLS from a non-Kamiwaza CA

**Scenario:** make Traefik present an ingress (UI / API / runtime) certificate that
chains to **your own CA**, not the platform `app-ca`, while leaving the internal
cert-manager PKI intact.

Two approaches:

| Approach | What you provide | Who issues the leaf |
| --- | --- | --- |
| **BYO leaf cert** | a ready `kubernetes.io/tls` Secret (leaf cert + key) | your external PKI, offline |
| **CA-issuer** | a CA cert **+ CA private key** Secret | cert-manager, in-cluster, from your CA |

---

## ⚠️ Required on 0.13.0 only

> The manifests in this folder are **required on 0.13.0**, where there is no native
> values knob to serve a BYO ingress cert — so you create the Secret and repoint the
> Traefik default `TLSStore` yourself. On **later releases** the network chart serves
> a BYO ingress cert through a native values knob, so these manifests are **not needed**
> there (and you should **not** hand-apply a `default` TLSStore on a release that
> manages it — helm/Argo sync will fight it).
>
> Why a manifest (not a plain `kubectl` one-off): on a helm/Argo-managed cluster a
> bare `kubectl` repoint of the `default` TLSStore is **reverted on the next sync**.
> On 0.13.0 the platform does not manage a `default` TLSStore (the chart does not
> create one), so applying these manifests is stable there.

---

## Approach 1 — BYO leaf cert

```bash
# 1. Create the kubernetes.io/tls Secret from your cert + key (gitignored material)
kubectl -n kamiwaza create secret tls org-ingress-tls \
  --cert=/path/to/fullchain.pem \
  --key=/path/to/privkey.pem
#   (or edit + apply byo-ingress-tls-secret.template.yaml)

# 2. Point Traefik's default TLSStore at it
kubectl apply -f security/tls-trust/ingress/tlsstore-default-byo.yaml

# 3. Verify the served chain
echo | openssl s_client -connect <host>:443 -servername <your-domain> 2>/dev/null \
  | openssl x509 -noout -issuer -subject
```

**Pass:** handshake completes; issuer chain leads to **your CA**, not `app-ca`.

---

## Approach 2 — CA-issuer (cert-manager issues from your CA)

Provide a Secret holding the **CA cert + CA private key**; cert-manager mints the
leaf and rotates it.

```bash
# 1. CA cert + key Secret (kubernetes.io/tls layout: tls.crt = CA cert, tls.key = CA key)
kubectl -n kamiwaza create secret tls org-ca-keypair \
  --cert=/path/to/org-ca.crt \
  --key=/path/to/org-ca.key

# 2. Issuer (kind: CA) + repointed wildcard Certificate
kubectl apply -f security/tls-trust/ingress/ca-issuer-and-cert.yaml

# 3. Point the default TLSStore at the reissued secret (same as Approach 1 step 2,
#    secretName = the Certificate's secretName)
kubectl apply -f security/tls-trust/ingress/tlsstore-default-byo.yaml
```

The cert-manager `Issuer` (kind: CA) reissues the wildcard leaf chained to your CA.

---

## Recovery from a bad cert

```bash
# roll the Secret back to known-good and (if needed) reapply the TLSStore
kubectl -n kamiwaza create secret tls org-ingress-tls \
  --cert=/path/to/good-fullchain.pem --key=/path/to/good-privkey.pem \
  --dry-run=client -o yaml | kubectl apply -f -

# Observe the failure mode first:
kubectl -n kamiwaza logs deploy/traefik | grep -i "tls\|certificate"
```

Only Traefik is affected; no data loss, no broader pod restarts, no manual k8s surgery
beyond reapplying the known-good Secret.

---

## Files

| File | Use |
| --- | --- |
| [`byo-ingress-tls-secret.template.yaml`](byo-ingress-tls-secret.template.yaml) | `kubernetes.io/tls` Secret template (BYO leaf cert). |
| [`tlsstore-default-byo.yaml`](tlsstore-default-byo.yaml) | Repoint Traefik default `TLSStore` (0.13.0 manifest path). |
| [`ca-issuer-and-cert.yaml`](ca-issuer-and-cert.yaml) | cert-manager `Issuer` (kind: CA) + repointed wildcard `Certificate` (CA-issuer approach). |
