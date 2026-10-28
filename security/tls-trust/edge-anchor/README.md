# Edge anchor for GreyMatter and BYO edge certificates

**Scenario:** you are installing or upgrading to Kamiwaza 1.4 on OpenShift with
GreyMatter, or on Istio or Envoy with an edge certificate the chart did not
issue from a CA it holds: your own certificate (`network.tls.mode: byo`, the
default, which includes EZUA), `customerCA`, or `cert-manager` with an issuer
other than the platform's `app-ca`. The install stops with:

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

**Istio or Envoy, BYO (EZUA included):** use the CA chain that issued your
edge certificate, root included, not the leaf; on EZUA, the EZUA gateway's CA.
For a self-signed certificate, use the certificate itself.

**`customerCA`:** the customer CA. If you also added it to the `ca` chart's
trust bundle, put the same CA here; the product chart cannot see that one.

**`cert-manager` with a custom issuer** (`global.certificates.issuers.app.name`
not `app-ca`): that issuer's CA.

Pass it with `--set-file global.trust.edgeAnchor.pem=edge-ca.crt`, or paste it
into the values file. The chart publishes it in the `kamiwaza-edge-trust`
ConfigMap; do not create that ConfigMap yourself. On a running installation,
restart Core's pods afterward so they reload their trust store:

```bash
kubectl -n kamiwaza rollout restart deployment/core-api deployment/core-scheduler \
  deployment/core-raycluster-head deployment/core-raycluster-worker
```

## Custom cluster domain: gateway certificate names

From 1.4, extensions reach the platform in-cluster through
`KAMIWAZA_PLATFORM_GATEWAY_URL`, and Core builds default gateway hosts on your
cluster's DNS domain instead of a fixed `.svc.cluster.local`. A gateway host
you configure yourself (`global.ingress.gateway.serviceHostname` on Istio,
`KAMIWAZA_INTERNAL_GATEWAY_URL` on Envoy) is used as given; update it. A
certificate the chart did not issue must carry the name each caller verifies:

- **GreyMatter:** `KAMIWAZA_GATEWAY_TLS_SERVER_NAME`. On a chart install that
  is `global.greymatter.edge.tlsServerName`, or the public domain when that is
  unset, so the edge certificate needs no new name; only the dialed edge host
  follows the cluster domain. Only without the chart, when
  `KAMIWAZA_GREYMATTER_EDGE_TLS_SERVER_NAME` is unset on Core, is it
  `<edge-service>.<namespace>.svc.<cluster-domain>`. Extensions managed by the
  extension operator get no server name and verify the public domain.
- **Envoy:** the public domain, plus
  `kamiwaza-envoy.<namespace>.svc.<cluster-domain>`. Core points
  `KAMIWAZA_API_URL` at that Service.
- **Istio:** the public domain. Extensions send it as the TLS server name.

On a cluster whose domain is not `cluster.local`, set `global.clusterDomain`
so that the chart and Core agree. Certificates the chart issues already carry
these names. Clusters on `cluster.local` need no change.

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
