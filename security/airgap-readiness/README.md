# Offline / air-gap readiness test harness

Use this packet to test whether an offline Kamiwaza install is actually usable
without public internet from both sides of the deployment:

- the user's browser or client VM can reach only the Kamiwaza instance
- the Kamiwaza server or cluster cannot reach public internet during runtime

This is a validation harness, not the offline bundle builder. Build and install
the target instance first with the Kajiya offline flow, then run these checks
against the installed system.

## Files

| File | Purpose |
| --- | --- |
| [`scripts/launch-airgap-chrome.sh`](scripts/launch-airgap-chrome.sh) | macOS/Linux Chrome launcher with a dead proxy and a Kamiwaza-only bypass list. |
| [`scripts/Launch-AirgapChrome.ps1`](scripts/Launch-AirgapChrome.ps1) | Windows PowerShell version of the Chrome dead-proxy launcher. |
| [`scripts/summarize-har-origins.py`](scripts/summarize-har-origins.py) | Reads an exported Chrome DevTools HAR and reports non-Kamiwaza origins. |
| [`scripts/client-lockdown-nft.sh`](scripts/client-lockdown-nft.sh) | Disposable Linux client VM output firewall: allow Kamiwaza and optional DNS only. |
| [`scripts/server-egress-probe.sh`](scripts/server-egress-probe.sh) | Server-side evidence collector for public egress probes, pod probes, and image references. |
| [`evidence-template.md`](evidence-template.md) | Short template for the final pass/fail notes. |

## Prerequisites

- A Kamiwaza offline install, usually produced by `Kajiya Offline Ad-hoc Bundler Build`.
- SSH access to the client VM and server/install VM.
- Browser access from the test client.
- `python3` for the HAR summarizer and server evidence parsing.
- `nft` on a disposable Linux client VM for the Stage 2 lock-down test.
- `kubectl` on the server/install VM for the Stage 3 server evidence script.

Do not apply the client lock-down script on your primary workstation unless you
have a tested recovery path. Use a disposable VM.

## Phase 0: build and install the offline target

Use the existing Kajiya ad-hoc offline workflow. For a release branch:

```bash
gh workflow run kajiya-offline-ad-hoc-bundler-build.yml \
  -R kamiwaza-internal/kajiya \
  -f kajiya_ref=release/0.13.1 \
  -f deploy_ref=release/0.13.1 \
  -f kamiwaza_ref=release/0.13.1 \
  -f containers_ref=release/0.13.1 \
  -f sdk_ref=release/0.13.1 \
  -f smoke_domain=test.kamiwaza.dev
```

Watch the run:

```bash
gh run watch -R kamiwaza-internal/kajiya \
  "$(gh run list -R kamiwaza-internal/kajiya \
      --workflow=kajiya-offline-ad-hoc-bundler-build.yml \
      --limit=1 --json databaseId --jq '.[0].databaseId')"
```

When the install VM is ready, record:

```bash
export KAMIWAZA_URL=https://test.kamiwaza.dev
export KAMIWAZA_HOST=test.kamiwaza.dev
export KAMIWAZA_IP=<install-vm-private-or-public-ip>
```

Prefer the private IP and private DNS path when the client VM is in the same
Azure network.

## Phase 1: browser-only smoke

This catches obvious browser-loaded public dependencies such as Google Fonts,
CDNs, analytics, public auth redirects, external model/docs assets, or
extension background calls.

On macOS or Linux:

```bash
security/airgap-readiness/scripts/launch-airgap-chrome.sh "$KAMIWAZA_URL"
```

On Windows PowerShell:

```powershell
.\security\airgap-readiness\scripts\Launch-AirgapChrome.ps1 `
  -KamiwazaUrl "https://test.kamiwaza.dev"
```

In Chrome DevTools:

1. Open Network.
2. Enable Preserve log.
3. Disable cache.
4. Reload the page.
5. Run the core and Kaizen workflow matrix below.
6. Export the network log as HAR.

Summarize the HAR:

```bash
python3 security/airgap-readiness/scripts/summarize-har-origins.py \
  --har ~/Downloads/kamiwaza-airgap.har \
  --allow-host "$KAMIWAZA_HOST" \
  --allow-host localhost \
  --allow-host 127.0.0.1
```

Pass criteria:

- required requests are served by the Kamiwaza origin
- any non-Kamiwaza origin is classified as eliminated, non-blocking noise, or a
  release-blocking dependency

This phase is fast but not sufficient as a release gate. DNS still resolves,
non-browser processes are unaffected, and the server may still have egress.

## Phase 2: locked-down client VM

Copy this scenario folder to the disposable client VM:

```bash
scp -r security/airgap-readiness azureuser@<client-vm>:/home/azureuser/
ssh azureuser@<client-vm>
cd ~/airgap-readiness
export KAMIWAZA_URL=https://test.kamiwaza.dev
export KAMIWAZA_HOST=test.kamiwaza.dev
export KAMIWAZA_IP=<install-vm-private-or-public-ip>
```

If DNS should be blocked, map the Kamiwaza hostname before applying the firewall:

```bash
echo "$KAMIWAZA_IP  $KAMIWAZA_HOST" | sudo tee -a /etc/hosts
```

Apply the client VM egress lock-down. This allows loopback, established
connections, the Kamiwaza IP on TCP 443, and optional internal DNS only.

```bash
sudo ./scripts/client-lockdown-nft.sh apply \
  --kamiwaza-ip "$KAMIWAZA_IP" \
  --kamiwaza-host "$KAMIWAZA_HOST" \
  --dns-ip <internal-dns-ip-if-needed> \
  --ttl-minutes 60
```

Run the browser smoke again from that VM:

```bash
./scripts/launch-airgap-chrome.sh "$KAMIWAZA_URL"
```

Remove the lock-down when finished:

```bash
sudo ./scripts/client-lockdown-nft.sh remove
```

Pass criteria:

- the browser can complete the workflow matrix
- HAR review shows no required public origin
- the client firewall logs or command output show only Kamiwaza and approved
  internal DNS egress

## Phase 3: server-side egress deny

Use Azure NSG, Azure Firewall, or the target environment's equivalent control
to deny public egress from the Kamiwaza install VM/subnet/cluster.

Allow only explicitly approved private/internal dependencies, for example:

- intra-cluster traffic
- internal DNS
- private model/object/artifact stores
- Azure metadata only if approved for the target environment

Block public destinations such as:

- `huggingface.co`
- `pypi.org`
- public npm/OCI registries
- `info.kamiwaza.ai`
- Google Fonts/CDNs
- public object storage unless explicitly approved
- public auth/provider APIs unless explicitly approved
- analytics and telemetry endpoints

After the deny policy is active, run the server evidence script on the install
VM:

```bash
ssh azureuser@<install-vm>
cd ~/airgap-readiness
export KAMIWAZA_URL=https://test.kamiwaza.dev
./scripts/server-egress-probe.sh \
  --kamiwaza-url "$KAMIWAZA_URL" \
  --namespace kamiwaza
```

If you know a good in-cluster pod for runtime probes, pass it explicitly:

```bash
./scripts/server-egress-probe.sh \
  --kamiwaza-url "$KAMIWAZA_URL" \
  --pod kamiwaza/<running-core-or-backend-pod-name>
```

The public probes should fail after server egress is denied. The Kamiwaza health
probe should still connect. The script also writes `pods.json`,
`image-summary.txt`, and probe logs under `airgap-evidence-<timestamp>/`.

Pass criteria:

- host public probes are blocked
- selected pod public probes are blocked, or skipped with a documented reason
- Kamiwaza health remains reachable
- pod image references are local/offline or explicitly approved
- Azure NSG/Azure Firewall logs show no required public egress during workflows

## Workflow matrix

Run this matrix from the locked-down client while server egress deny is active.

Kamiwaza core:

- load web UI
- login and logout
- navigate dashboard and primary pages
- confirm frontend assets load only from the Kamiwaza origin
- list available models
- use a preloaded/offline chat model
- run a basic inference/chat workflow
- confirm bundled embedding model behavior
- upload and download files where applicable
- confirm local/offline App Garden or extension catalog behavior
- install or activate bundled extensions from the offline extension bundle

Kaizen:

- launch Kaizen from Kamiwaza
- create a workroom
- start an agent/task using an internal/preloaded model
- upload and download files in workroom flows
- run a basic skill
- run one skill with Python requirements to verify the known runtime dependency
  install case
- confirm no public PyPI/pip dependency is required for release-gate workflows

Bundled extensions:

- DDE: launch and internal communication
- Graphiti: service availability and internal API flow
- Milvus: service availability and vector workflow
- Vespa: activation and query flow; remote model/tokenizer assets must be
  bundled, configured locally, or disabled
- Omniparse: basic file parsing; advanced URL/transcription/translation/vision
  modes must be classified as internal-only, disabled, or allowlist-required
- Connector Builder: test against internal/mock APIs unless public API access is
  explicitly in scope
- Workroom/outcome manager, if bundled: launch and file workflows

## Known risks to classify

- No bundled/default offline chat model.
- Vespa references to remote model/tokenizer assets.
- Kaizen runtime pip install for skill requirements, tracked as EXT-837.
- Public object storage configuration in workroom/context/file flows.
- Omniparse advanced modes that require URL fetch, transcription, translation,
  or vision endpoints.
- Connector Builder flows that discover or call public APIs.
- Non-blocking egress noise such as telemetry, news, model guide refreshes,
  Google Fonts attempts, or browser background calls.

For Kaizen frontend rebuild failures caused by `next/font/google`, use the
related runbook:

```text
security/tls-trust/extensions/kaizen-frontend-offline-rebuild-hotfix/
```

## Final acceptance criteria

The test passes only if:

- browser DevTools shows no required successful requests to non-Kamiwaza public
  origins
- client VM firewall or NSG logs show no required public egress
- server firewall or NSG logs show no required public egress for core and Kaizen
  workflows
- Kamiwaza core loads and basic workflows complete
- Kaizen loads and basic agent/workroom workflows complete
- required models are available without public downloads
- bundled extension install/activation works from the offline bundle for the
  supported extensions
- public egress attempts are eliminated or documented as non-blocking noise
- any blocking gaps have a Linear issue with owner, priority, and reproduction
  steps
