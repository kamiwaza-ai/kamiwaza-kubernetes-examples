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
| `core.scheduler.tlsInsecure` | The platform's own origins: its domain, in-cluster services, paired federation clusters | External model hosts (from 1.4, in Core as well as Kaizen) |
| `core.scheduler.externalTlsInsecureWithDnsRetargetingRisk` | External model hosts: `true` for all, or a list of exact hostnames | The platform's own origins |

Before 1.4, `tlsInsecure` also skipped verification for Core's own calls to
external model hosts. A site that relied on that must, on upgrade, add the CA
to `global.trust.extraAnchors` or list the host here.

## Steps

1. Merge [`values-snippet.yaml`](values-snippet.yaml) into your values file,
   replacing `models.example.com` with the exact hostname of the endpoint. List
   each host separately: `models.example.com` does not cover
   `eu.models.example.com`.
2. Run your usual `helm upgrade --install`. The chart refuses an entry with a
   wildcard, scheme, port, or path, and says why.
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
then redeploy the extensions. Verification is back on for every external host.
