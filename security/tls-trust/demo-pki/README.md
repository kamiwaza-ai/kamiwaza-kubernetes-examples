# Demo PKI — FAKE, throwaway certificates for the tls-trust example

> ## ⚠️ DO NOT TRUST OR REUSE THIS MATERIAL
>
> Every key and certificate in this directory is **fake, public, and throwaway**.
> The private keys are committed to a public repo **on purpose** so the example
> manifests apply with zero local generation. **Never** add any of this to a real
> trust store, serve it from a real endpoint, or reuse these keys anywhere.

This directory exists so you can walk the **entire** tls-trust cycle —
outbound CA trust **and** BYO ingress — end to end without first standing up your
own PKI. It is the "just show me it working" path. For a real deployment you still
bring your own CA material (the parent [`README.md`](../README.md) covers that).

## The hierarchy

```
Kamiwaza Demo Root CA (FAKE)              root-ca.crt / root-ca.key
  └── Kamiwaza Demo Intermediate CA      intermediate-ca.crt / intermediate-ca.key
        └── *.kamiwaza.test  (leaf)      ingress.crt / ingress.key
```

| File                                          | What it is                              | Used as                                                                       |
| --------------------------------------------- | --------------------------------------- | ----------------------------------------------------------------------------- |
| `root-ca.crt` / `root-ca.key`                 | self-signed root                        | top of trust                                                                  |
| `intermediate-ca.crt` / `intermediate-ca.key` | issuing CA (pathlen:0)                  | signs the leaf; also the CA-issuer keypair for ingress Approach 2             |
| `ingress.crt` / `ingress.key`                 | leaf for `*.kamiwaza.test` (+ apex SAN) | the BYO serving cert for ingress Approach 1                                   |
| `ca-chain.pem`                                | root **+** intermediate                 | **outbound** trust anchor — the `org-ca.pem` for the `kamiwaza-org-ca` Secret |
| `ingress-fullchain.pem`                       | leaf **+** intermediate                 | **inbound** served chain (what Traefik presents)                              |

## Ready-to-apply Secret manifests

So the cert material and the YAML never drift, `generate.sh` also emits the three
Secrets the example consumes (each pinned to `namespace: kamiwaza`):

| Manifest                      | Secret                                     | For                                         |
| ----------------------------- | ------------------------------------------ | ------------------------------------------- |
| `secret-kamiwaza-org-ca.yaml` | `kamiwaza-org-ca` (`Opaque`, `org-ca.pem`) | outbound CA trust — parent README Step 1    |
| `secret-org-ingress-tls.yaml` | `org-ingress-tls` (`kubernetes.io/tls`)    | ingress Approach 1 (BYO leaf)               |
| `secret-org-ca-keypair.yaml`  | `org-ca-keypair` (`kubernetes.io/tls`)     | ingress Approach 2 (cert-manager CA issuer) |

```bash
# Outbound trust (then merge the values snippet + sync — see parent README):
kubectl apply -f security/tls-trust/demo-pki/secret-kamiwaza-org-ca.yaml

# Inbound BYO ingress, Approach 1:
kubectl apply -f security/tls-trust/demo-pki/secret-org-ingress-tls.yaml
kubectl apply -f security/tls-trust/ingress/tlsstore-default-byo.yaml

# Inbound BYO ingress, Approach 2 (cert-manager issues from the demo intermediate):
kubectl apply -f security/tls-trust/demo-pki/secret-org-ca-keypair.yaml
sed 's/REPLACE_WITH_YOUR_DOMAIN/kamiwaza.test/g' \
  security/tls-trust/ingress/ca-issuer-and-cert.yaml | kubectl apply -f -
kubectl apply -f security/tls-trust/ingress/tlsstore-default-byo.yaml
```

The leaf is issued for `*.kamiwaza.test` (with `kamiwaza.test` as an additional
SAN). If your cluster serves a different domain, regenerate (below) with `DOMAIN=`.

## Regenerate / rotate

```bash
cd security/tls-trust/demo-pki
./generate.sh                 # default domain kamiwaza.test
DOMAIN=corp.example ./generate.sh   # different served domain
```

`generate.sh` rebuilds the whole chain (new serials/dates, same shape), re-emits
the three Secret manifests, and runs `openssl verify` to prove the leaf chains to
the root through the intermediate. CAs are valid 10 years; the leaf 825 days.

## Verify the chain by hand

```bash
# leaf → intermediate → root
openssl verify -CAfile root-ca.crt -untrusted intermediate-ca.crt ingress.crt

# what each bundle contains
openssl crl2pkcs7 -nocrl -certfile ca-chain.pem | openssl pkcs7 -print_certs -noout
```
