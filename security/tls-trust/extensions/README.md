# Extension trust pattern + Kaizen sandbox follow-on (0.13.0)

Use this folder **after** the parent [`../`](../) packet is green for core / Ray.

The goal here is two-layered:

1. define the **generic extension trust pattern** for declared extension pods
2. document the **Kaizen-specific sandbox follow-on**, where spawned agent pods
   must inherit that trust wiring too

This stays within the same emergency `0.13.0` constraint: additive trust bundle,
verification left ON, and no new images.

## Two layers

### 1. Generic extension trust pattern

For any extension with **declared service pods** in `kamiwaza-extensions`, the
reusable config-only pattern is:

- mount `kamiwaza-trust-bundle`
- set `SSL_CERT_FILE`, `REQUESTS_CA_BUNDLE`, and `AWS_CA_BUNDLE`
- keep TLS verification ON
- allow external egress only when the extension actually needs it

This layer is broadly reusable across extensions even though the helper scripts
in this folder are Kaizen-focused.

### 2. Kaizen-specific sandbox follow-on

Kaizen adds one more boundary:

- declared `backend` / `sandbox-controller` services must pick up the trust
  bundle like any other extension
- **spawned sandbox pods** in `kamiwaza-sandboxes` must inherit that trust
  wiring too
- if the sandbox pod does not show the bundle mount + CA env, stop calling the
  packet complete; that remaining gap belongs to sandbox-controller / operator
  behavior, not customer values

## Files

| File | Purpose |
| --- | --- |
| [`sandbox-target-namespaces-values-snippet.yaml`](sandbox-target-namespaces-values-snippet.yaml) | Generic follow-on values snippet: adds `kamiwaza-sandboxes` to the trust-bundle sync targets. |
| [`apply-kaizen-extension-trust.py`](apply-kaizen-extension-trust.py) | Kaizen-specific helper: patches a live Kaizen `KamiwazaExtension` CR so its declared services pick up the generic trust pattern. |
| [`verify-kaizen.sh`](verify-kaizen.sh) | Kaizen-specific verifier: checks declared backend trust wiring **and** whether the spawned sandbox pod inherited it. |

## Apply order

1. Apply the parent packet in [`../README.md`](../README.md) and make `../verify.sh`
   pass for core / Ray.
2. Merge [`sandbox-target-namespaces-values-snippet.yaml`](sandbox-target-namespaces-values-snippet.yaml)
   into the same Deploy values layer as the parent trust snippet, then sync.
3. For **declared extension pods generally**, apply the generic pattern:
   mount `kamiwaza-trust-bundle`, inject the CA envs, keep verification ON, and
   allow external egress only when needed.

   For **Kaizen specifically**, patch the live extension CR with the helper:

   ```bash
   security/tls-trust/extensions/apply-kaizen-extension-trust.py <extension-name>
   ```

   Example:

   ```bash
   security/tls-trust/extensions/apply-kaizen-extension-trust.py kaizen-a1b2c3d4
   ```

   Optional proxy path for customer/private egress:

   ```bash
   security/tls-trust/extensions/apply-kaizen-extension-trust.py \
     --https-proxy http://squid.internal:3128 \
     --http-proxy http://squid.internal:3128 \
     --no-proxy localhost,127.0.0.1,.svc,.cluster.local \
     kaizen-a1b2c3d4
   ```

   This injects proxy env into the **declared Kaizen backend service** only. It is
   still not assumed to reach spawned sandboxes; that remains a verification
   gate below.

4. For Kaizen, open or resume a conversation so the sandbox-controller actually
   spawns an agent pod in `kamiwaza-sandboxes`.
5. For Kaizen, run the verifier:

   ```bash
   security/tls-trust/extensions/verify-kaizen.sh <extension-name>
   ```

   Optional live TLS probe:

   ```bash
   security/tls-trust/extensions/verify-kaizen.sh <extension-name> https://bedrock.example.com
   ```

## Scale note: raise the Kind pod ceiling to 1000 on 0.13.0

For an offline prod install, add this top-level key to
`/opt/kamiwaza/cluster/values/overrides.yaml`:

```yaml
kind_kubelet_max_pods: 1000
```

Then rerun the installer and pass that same file through to Ansible:

```bash
/opt/kamiwaza/bin/install-prod.sh --offline \
  -e @/opt/kamiwaza/cluster/values/overrides.yaml
```

If the cluster already exists, recreate it first because the Kind kubelet
config is applied at cluster creation:

```bash
/opt/kamiwaza/bin/uninstall-prod.sh
/opt/kamiwaza/bin/install-prod.sh --offline \
  -e @/opt/kamiwaza/cluster/values/overrides.yaml
```

Verify:

```bash
kubectl get nodes -o jsonpath='{range .items[*]}{.metadata.name}{" pods="}{.status.capacity.pods}{"\n"}{end}'
```

Expect `pods=1000`.

## What the Kaizen patcher changes

For the live Kaizen `KamiwazaExtension` CR, the patcher:

- sets `spec.kamiwaza.tlsRejectUnauthorized: "1"`
- sets `spec.networking.networkPolicy.allowExternalAccess: true`
- mounts `kamiwaza-trust-bundle` at `/etc/ssl/certs/ca-certificates.crt`
- injects `SSL_CERT_FILE`, `REQUESTS_CA_BUNDLE`, and `AWS_CA_BUNDLE`
- optionally injects `HTTPS_PROXY`, `HTTP_PROXY`, and `NO_PROXY` into the
  Kaizen backend when you pass them on the command line (or export them in the
  shell running the patcher)
- flips the Kaizen-side verify flags back on:
  - `AGENT_DISABLE_SSL_VERIFY=false`
  - `KAMIWAZA_VERIFY_SSL=true`

This is the Kaizen-specific realization of the generic extension trust pattern.

It patches the **declared** `backend` and `sandbox-controller` services only.
Proxy envs go to the backend because that process constructs `forward_env` for
spawned sandboxes. This packet still does **not** claim to patch the spawned
sandbox pod directly.

## Pass / fail criteria

**Pass for the generic extension trust pattern**

- `kamiwaza-trust-bundle` exists in `kamiwaza-extensions`
- the declared extension pod(s) have the bundle mounted at
  `/etc/ssl/certs/ca-certificates.crt`
- the declared extension pod(s) show `SSL_CERT_FILE`, `REQUESTS_CA_BUNDLE`, and
  `AWS_CA_BUNDLE` pointing at that path

**Additional pass criteria for Kaizen declared services**

- the Kaizen backend pod no longer runs with the Kaizen SSL-bypass flags
- if proxy envs were requested, the Kaizen backend pod shows them too

**Additional pass criteria for the Kaizen sandbox path**

- `kamiwaza-trust-bundle` exists in `kamiwaza-sandboxes`
- a spawned sandbox pod exists for the extension
- that sandbox pod also shows the bundle mount and CA env
- if proxy envs were requested, that sandbox pod shows them too

**Fail / stop**

- no sandbox pod exists yet: create or resume a Kaizen conversation, then rerun
- sandbox pod exists but lacks the mount or env: the current `0.13.0`
  config-only packet stops here; the remaining gap is sandbox-controller /
  operator propagation, not customer Helm values

## Important hostname constraint

The generic extension trust pattern solves **CA trust**. It does **not**
override normal TLS hostname validation.

That matters especially for Kaizen because committed agent configs in the repo
commonly use
HTTPS **IP-literal** endpoints like:

- `https://192.168.100.118:61117/v1`
- `https://192.168.100.115:61109/v1`

Meanwhile, sibling Kamiwaza deployment endpoints present a wildcard DNS cert
like `*.default.deployment.kamiwaza.ai`.

If your sandbox calls an IP-literal HTTPS URL while the server presents a DNS
wildcard cert, you will still fail verification even after the CA bundle is
mounted correctly:

- first failure mode: `self-signed certificate` / unknown CA
- second failure mode after trusting that CA: `IP address mismatch`

So for verification-on success you need **both**:

1. the CA bundle mounted and wired into the caller environment
2. the target hostname in the URL to match the certificate SANs

If the federal/customer endpoint is a private DNS hostname signed by the
customer CA, this packet can still work. If the endpoint is configured as an
IP-literal HTTPS URL, fix the endpoint naming first or use a different routing
pattern; do not assume a wildcard DNS cert or generic private CA patch will
make the IP literal verify.
