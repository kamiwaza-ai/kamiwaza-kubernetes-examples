# Trial escape hatch: unverified external model endpoints

**Scenario:** during a trial or proof of concept, Kamiwaza has to reach an
external model endpoint (chat, embedding, reranking, vision) whose certificate
it cannot verify yet, and nobody has set up the CA. This turns off certificate
verification for those external hosts only, loudly, until the CA is in place.

**Kamiwaza 1.4 and later.** **Tags:** #security #tls #poc #helm-values

> **Use the CA instead whenever you can.** Add the provider's root CA, and any
> issuing CA, to `global.trust.extraAnchors`. That keeps verification on and
> needs no setting with a risk in its name. On 1.4 this is a chart value (the
> [Custom TLS trust](../README.md) recipe describes the older 0.13.x path):
>
> ```yaml
> global:
>   trust:
>     extraAnchors:
>       - name: provider-root
>         pem: |
>           -----BEGIN CERTIFICATE-----
>           ...
>           -----END CERTIFICATE-----
> ```
>
> Each entry is a PEM string or `{name, pem}`. Include the root, not only an
> issuing CA. Rerun `helm upgrade --install`. Core's pods build their trust
> store at startup and changing only the anchors does not restart them, so run
> `kubectl -n kamiwaza rollout restart deployment/core-scheduler deployment/core-raycluster-head deployment/core-raycluster-worker`
> (also `core-api` and `core-retrieval-streamer` if you enabled them as
> separate deployments).
> Then redeploy extensions such as Kaizen so they pick up the new trust bundle.

## Prerequisites

- Kamiwaza 1.4 or later, installed with Helm.
- The exact hostname (or IPv4 address) of each external model endpoint.
- Permission to redeploy App Garden extensions such as Kaizen.

## The risk

Without verification, Kamiwaza sends the long-lived API keys it holds for the
provider to whoever answers DNS for that host or sits on the network path. Any
DNS change you do not control (site or corporate DNS, a compromised resolver)
can redirect those keys. The setting is named for this:
`core.scheduler.externalTlsInsecureWithDnsRetargetingRisk`.

## How it relates to `tlsInsecure`

| Setting                                                    | Covers                                                                                                                                                                        | Never covers                                                                                                                |
| ---------------------------------------------------------- | ----------------------------------------------------------------------------------------------------------------------------------------------------------------------------- | --------------------------------------------------------------------------------------------------------------------------- |
| `core.scheduler.tlsInsecure`                               | The platform's own origins: its domain, names Kamiwaza is configured with, loopback, `localhost`, in-cluster `*.svc` / `*.cluster.local` services, paired federation clusters | External model hosts (from 1.4, in Core as well as Kaizen), including servers addressed by a private IP or a short hostname |
| `core.scheduler.externalTlsInsecureWithDnsRetargetingRisk` | External model hosts: `true` for all, or a list of exact hostnames or IPv4                                                                                                    | The platform's own origins                                                                                                  |

From 1.4, Core verifies every external model host it calls unless this
setting names it. Neither `tlsInsecure` nor the Context Service or OmniParse
TLS settings relax an external host any more. A site that relied on them must,
on upgrade, add the CA to `global.trust.extraAnchors` or list the host here.
This setting does not reach OmniParse translation endpoints, which always
verify an external host; trust their CA through `global.trust.extraAnchors`.
After the upgrade, open and save each OmniParse instance that uses an external
model endpoint so Core rebuilds its TLS setting.

Kaizen classifies hosts more strictly than Core. It never relaxes a short
hostname, an IPv6 address, or an in-cluster `*.svc` / `*.cluster.local` name
through this setting, even with `true`, and its `tlsInsecure` (`KAMIWAZA_VERIFY_SSL=false`)
covers only the exact platform URLs it is configured with.

## Steps

1. Merge [`values-snippet.yaml`](values-snippet.yaml) into your values file,
   replacing `models.example.com` with the exact, fully qualified hostname of
   the endpoint. List each host separately: `models.example.com` does not cover
   `eu.models.example.com`. An IPv4 address such as `10.0.0.5` can be listed.
   A short hostname or an IPv6 address cannot: use a fully qualified name
   (outside `*.svc` / `*.cluster.local`) if one resolves, or `true`. `true`
   turns verification off for **every** external model host, present and
   future, so prefer the CA. To use it, set the key to `true` in place of the
   list. Core then covers the host; Kaizen never relaxes a short
   hostname or an IPv6 address, so for Kaizen use the fully qualified name or
   the CA.
2. Run your usual `helm upgrade --install`. The chart refuses an entry with a
   wildcard, scheme, port, or path, a single-label name, or an IPv6 address,
   and says why.
3. Redeploy the extensions that call the endpoint (for example, Kaizen, from
   App Garden) so they pick up the setting. Core's own pods roll on the
   upgrade, because the setting changes `core-config`.

## Verification

- The install notes print a `WARNING:` naming
  `externalTlsInsecureWithDnsRetargetingRisk` and the hosts.
- The Core ConfigMap carries the normalized value:

  ```bash
  kubectl -n kamiwaza get configmap core-config -o yaml | \
    grep KAMIWAZA_EXTERNAL_TLS_INSECURE_WITH_DNS_RETARGETING_RISK
  ```

- Core and Kaizen log one warning naming the DNS-retargeting risk and the
  hosts; Kaizen's diagnostics show the setting.

## Rollback

Set it to `false` explicitly and rerun `helm upgrade --install`. Do not just
delete the key: an upgrade with `--reuse-values` (or
`--reset-then-reuse-values`) keeps the previous value. Then **redeploy every extension that calls an external model** (for example,
Kaizen). Extensions receive the setting only when they are deployed, so a
running extension keeps skipping verification until it is redeployed. After
that, verification is back on for every external host. Confirm with the
`core-config` check above (the value must read `false`), and in each
redeployed extension pod:

```bash
kubectl -n <extension-namespace> exec <kaizen-pod> -- \
  printenv KAMIWAZA_EXTERNAL_TLS_INSECURE_WITH_DNS_RETARGETING_RISK
```

## Not affected

- Plain `http://` model endpoints have no TLS; neither this setting nor
  `tlsInsecure` changes anything for them.
- Core's External Models engines (Bedrock, OpenAI-compatible registrations)
  always verify and ignore both this setting and `tlsInsecure`; trust their CA
  through `global.trust.extraAnchors`.
- OAuth token endpoints that receive a client secret always verify unless
  they are a platform origin. Trust their CA through
  `global.trust.extraAnchors`.
