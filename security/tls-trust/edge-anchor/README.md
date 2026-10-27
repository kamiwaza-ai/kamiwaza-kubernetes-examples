# Edge anchor for GreyMatter and BYO edge certificates

**Scenario:** you are installing or upgrading to Kamiwaza 1.4 on OpenShift with
GreyMatter, or on Istio or Envoy with your own edge certificate
(`network.tls.mode: byo`, the default). The install stops with:

```text
ENG-14728 preflight: Context runtime model calls verify TLS by default since 1.4.0 (core.context.embedding.verifySsl: true), but the certificate for https://<domain> is minted outside this chart ...
```

From 1.4.0 the Context Service verifies TLS on its embedding and LLM calls to
the platform's own domain. The chart cannot read the CA of a certificate it did
not create, so you must give it one of three answers before it installs.

**Kamiwaza 1.4 and later.** **Tags:** #security #tls #greymatter #byo #helm-values

## The three fixes

| Option          | Value                                           | Verification | When                                                               |
| --------------- | ----------------------------------------------- | ------------ | ------------------------------------------------------------------ |
| 1 (recommended) | `global.trust.edgeAnchor.pem`                   | on           | Any private or self-signed edge certificate. Always on GreyMatter. |
| 2               | `global.trust.edgeAnchor.publiclyTrusted: true` | on           | The edge certificate chains to a public CA.                        |
| 3               | `core.context.embedding.verifySsl: false`       | **off**      | Stopgap only, until you can do option 1.                           |

All three are in [`values-snippet.yaml`](values-snippet.yaml). Merge one into
your site values file and rerun `helm upgrade --install`.

## Option 1: get the CA

**GreyMatter:** the mesh CA is the `ca.crt` of Secret `greymatter-edge-ingress`:

```bash
oc -n kamiwaza get secret greymatter-edge-ingress \
  -o jsonpath='{.data.ca\.crt}' | base64 -d > edge-ca.crt
```

**Istio or Envoy, BYO:** use the CA chain that issued your edge certificate,
root included, not the leaf. For a self-signed certificate, use the certificate
itself.

Pass it with `--set-file global.trust.edgeAnchor.pem=edge-ca.crt`, or paste it
into the values file. The chart publishes it in the `kamiwaza-edge-trust`
ConfigMap; do not create that ConfigMap yourself. On a running installation,
restart Core's pods afterward so they reload their trust store:

```bash
kubectl -n kamiwaza rollout restart deployment/core-api deployment/core-scheduler \
  deployment/core-raycluster-head deployment/core-raycluster-worker
```

## Risks

- **Option 2** keeps verification on. If the certificate is not actually
  publicly trusted, Context calls fail with a certificate error, and Core logs
  `TLS certificate verification failed for platform origin <host> ...`.
- **Option 3** turns verification off for the Context Service's calls to the
  platform's own domain. Anyone who can redirect that domain, through site DNS
  or from inside the cluster, can read those calls and the tokens they carry.
  The install notes print `WARNING: TLS verification is DISABLED for: ...` and
  Core logs it at every start until you remove the setting.

## Verification

```bash
# Core resolved verification on (prints True), unless you chose option 3:
kubectl -n kamiwaza exec deploy/core-api -- python -c \
  "from kamiwaza.services.context.config import settings; print(settings.embedding_ssl_verify)"

# No verification failures since the restart:
kubectl -n kamiwaza logs deploy/core-api | grep 'TLS certificate verification failed for platform origin'
```

See also the public docs:
[Edge certificates minted outside the chart](https://docs.kamiwaza.ai/configuration#context-tls-preflight).
