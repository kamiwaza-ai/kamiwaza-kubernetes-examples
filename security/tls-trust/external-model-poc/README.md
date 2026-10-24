# Trial escape hatch: unverified external model endpoints

**Scenario:** during a trial or proof of concept, Kamiwaza has to reach an
external model endpoint (chat, embedding, reranking, vision) whose certificate
it cannot verify yet, and nobody has set up the CA. This turns off certificate
verification for those external hosts only, loudly, until the CA is in place.

**Kamiwaza 1.4 and later.** **Tags:** #security #tls #poc #helm-values

> **Use the CA instead whenever you can.** Add the provider's root CA, and any
> issuing CA, to `global.trust.extraAnchors`, as described in
> [Custom TLS trust](../README.md). That keeps verification on and needs no
> setting with a risk in its name.

## The risk

Without verification, Kamiwaza sends the long-lived API keys it holds for the
provider to whoever answers DNS for that host or sits on the network path. Any
DNS change you do not control (site or corporate DNS, a compromised resolver)
can redirect those keys. The setting is named for this:
`core.scheduler.externalTlsInsecureWithDnsRetargetingRisk`.

## How it relates to `tlsInsecure`

| Setting | Covers | Never covers |
| --- | --- | --- |
| `core.scheduler.tlsInsecure` | The platform's own origins: its domain, names Kamiwaza is configured with, loopback, `localhost`, in-cluster `*.svc` / `*.cluster.local` services, paired federation clusters | External model hosts (from 1.4, in Core as well as Kaizen), including servers addressed by a private IP or a short hostname |
| `core.scheduler.externalTlsInsecureWithDnsRetargetingRisk` | External model hosts: `true` for all, or a list of exact hostnames | The platform's own origins |

From 1.4, Core verifies every external model host it calls unless this
setting names it. Neither `tlsInsecure` nor the Context Service or OmniParse
TLS settings relax an external host any more. A site that relied on them must,
on upgrade, add the CA to `global.trust.extraAnchors` or list the host here.
This setting does not reach OmniParse translation endpoints, which always
verify an external host; trust their CA through `global.trust.extraAnchors`.

## Steps

1. Merge [`values-snippet.yaml`](values-snippet.yaml) into your values file,
   replacing `models.example.com` with the exact, fully qualified hostname of
   the endpoint. List each host separately: `models.example.com` does not cover
   `eu.models.example.com`. An IPv4 address such as `10.0.0.5` can be listed;
   to cover an IPv6 address, use `true`.
2. Run your usual `helm upgrade --install`. The chart refuses an entry with a
   wildcard, scheme, port, or path, a single-label name, or an IPv6 address,
   and says why.
3. Redeploy the extensions that call the endpoint (for example, Kaizen) so
   they pick up the setting.

## Verification

- The install notes print a `WARNING:` naming
  `externalTlsInsecureWithDnsRetargetingRisk` and the hosts.
- The Core ConfigMap carries the normalized value:

  ```bash
  kubectl -n kamiwaza get configmap -o yaml | \
    grep KAMIWAZA_EXTERNAL_TLS_INSECURE_WITH_DNS_RETARGETING_RISK
  ```

- Core and Kaizen log one warning naming the DNS-retargeting risk and the
  hosts; Kaizen's diagnostics show the setting.

## Rollback

Delete the setting (or set it to `false`) and rerun `helm upgrade --install`,
then **redeploy every extension that calls an external model** (for example,
Kaizen). Extensions receive the setting only when they are deployed, so a
running extension keeps skipping verification until it is redeployed. After
that, verification is back on for every external host.

## Not affected

Plain `http://` model endpoints have no TLS; neither this setting nor
`tlsInsecure` changes anything for them.
