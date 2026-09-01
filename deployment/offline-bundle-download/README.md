# Download an offline release bundle (Keygen)

Fetch and reassemble a Kamiwaza **offline release bundle** from Keygen —
[Step 1: Download the Bundle Artifacts](https://docs.kamiwaza.ai/installation/offline_install#step-1-download-the-bundle-artifacts)
of the [offline install docs](https://docs.kamiwaza.ai/installation/offline_install), and the missing prerequisite of
[deployment/eks-offline-bundle](../eks-offline-bundle) ("Bundle: downloaded + extracted").

The bundle is distributed as **split parts** (`*.part-000`, `*.part-001`, …) with a
`.sha256` per part. [`download-bundle.sh`](download-bundle.sh) resolves the release,
downloads every artifact, verifies the parts, concatenates them, and checks the
assembled bundle against its published checksum.

**Nothing is hardcoded per release.** The script asks Keygen for the release list of the
*Kamiwaza Offline Bundles* package, picks the newest stable version (or `$RELEASE`), and
uses **that release's artifact list as the download manifest** — so part counts, the
timestamped extensions-bundle name, and the RPM filename all come from the API.

## Prerequisites

| Requirement | Notes |
| --- | --- |
| Kamiwaza license key | Your Keygen license key, passed as `KEYGEN_LICENSE`. Ask your Kamiwaza contact if you don't have one. |
| Internet egress | To `api.keygen.sh` + `raw.pkg.keygen.sh`. Run this on a connected host, then move `$DEST` into the air gap. |
| `curl`, `python3`, `sha256sum` | `python3` only parses the Keygen JSON — no packages needed. |
| Disk | **~40 GB free**: the parts plus the assembled bundles (parts are removed after a verified assemble; `KEEP_PARTS=1` keeps them and roughly doubles the requirement). |

## Run it

```bash
KEYGEN_LICENSE="<your-license-key>" \
RELEASE="1.2.0" \
DEST="./artifacts/kamiwaza-bundle-v1.2.0" \
  deployment/offline-bundle-download/download-bundle.sh
```

| Env | Default | Meaning |
| --- | --- | --- |
| `KEYGEN_LICENSE` | *(required)* | Your Kamiwaza license key (sent as `Authorization: License …`). |
| `RELEASE` | latest stable | **Which bundle version to fetch** — any published release, not just the newest (see below). Omit it to take the latest stable. |
| `DEST` | `/opt/kamiwaza/prereqs` | Download directory; created with `sudo install -d` if it doesn't exist. |
| `KEEP_PARTS` | `0` | `1` keeps the `.part-NNN` files + sidecars after assembly (to re-verify or redistribute the split files). |
| `PACKAGE_ID` | offline-bundles pkg | Override the Keygen package id. |

### Choosing a release

`RELEASE` pins the bundle version. Set it to **whatever version you want** — the newest,
or an older one your cluster / runbook was validated against (e.g. matching an existing
install, or reproducing a customer's environment). Leave it unset only if "whatever is
newest today" is genuinely what you want; a pinned version makes the download
reproducible.

To see what's published, ask for a version that doesn't exist — the script lists the
available ones and exits before downloading anything:

```bash
KEYGEN_LICENSE="<key>" RELEASE=list DEST=. deployment/offline-bundle-download/download-bundle.sh
# Release list not found. Available:
#   1.0.0
#   1.1.0
#   1.2.0
```

Prereleases (`1.2.0-rc.1`) are filtered out of both the list and the "latest" pick.

**Reruns are safe and cheap.** Present files are skipped, interrupted downloads resume
(`curl --continue-at -`), and an already-assembled bundle short-circuits the re-fetch of
its (deleted) parts — a rerun after a completed run downloads nothing.

Check the part-grouping logic without a license key or network:

```bash
deployment/offline-bundle-download/download-bundle.sh --self-test   # -> OK
```

## What you get

```
$DEST/
├── kamiwaza-helm.00.tar        # the helm-dt wrap: chart + images + Images.lock, assembled
├── kamiwaza-helm.tar           # symlink -> kamiwaza-helm.00.tar (what the runbook references)
├── kamiwaza-helm.sha256/.asc   # checksum + detached GPG signature
├── kamiwaza-tools-rpm.pub.gpg  # signature pubkey
├── kamiwaza-prod-<sha>.rpm     # deploy code -> /opt/kamiwaza (charts, cluster/, ansible,
│                               #   bundled helm/helmfile/kind + helm-dt plugin)
├── kamiwaza-extensions-bundle-<ts>.tar.gz  # extensions + offline-extension-catalog, assembled
└── release_origination.md      # what this release was built from
```

## Verify

The script fails loudly on a checksum mismatch, so a clean exit already means verified.
To re-check by hand — and to validate the GPG signature the script does *not* check:

```bash
cd "$DEST"
sha256sum -c kamiwaza-helm.sha256                       # kamiwaza-helm.tar: OK
sha256sum -c kamiwaza-extensions-bundle-*.tar.gz.sha256 # ...tar.gz: OK
gpg --import kamiwaza-tools-rpm.pub.gpg
gpg --verify kamiwaza-helm.asc kamiwaza-helm.sha256     # Good signature
tar -tf kamiwaza-helm.tar | head                        # kamiwaza-helm/*.wrap
```

## Next

- **Extract** the deploy code and the wraps:
  ```bash
  mkdir -p extracted && rpm2cpio kamiwaza-prod-*.rpm | (cd extracted && cpio -idm)  # -> opt/kamiwaza
  mkdir -p wrap && tar -xf kamiwaza-helm.tar -C wrap                                # -> wrap/kamiwaza-helm/*.wrap
  ```
- **VM / air-gapped host:** continue at
  [Step 2: Install Prerequisites](https://docs.kamiwaza.ai/installation/offline_install#step-2-install-prerequisites) and the rest of
  the [offline install docs](https://docs.kamiwaza.ai/installation/offline_install) (Step 4 pre-extracts the extensions bundle above).
- **Kubernetes:** [deployment/eks-offline-bundle](../eks-offline-bundle) relocates the
  wrap into Amazon ECR and deploys the offline Helmfile onto an existing EKS cluster
  (point its `config.env` `WORK=` / `WRAP_DIR=` at the two paths above).

## Gotchas

- **`RELEASE` is the bundle's version, not the platform version.** Every Keygen package
  has its own `1.0.0`; this script scopes the lookup to the *Kamiwaza Offline Bundles*
  package so "latest" means the newest bundle. Prereleases (`1.2.0-rc.1`) are ignored.
- **`DEST` on the right disk.** ~12 GB of parts get concatenated into ~12 GB of bundle;
  a small `/opt` fills up mid-assemble. Point `DEST` at the big volume up front.
- **Long download, expiring shell.** The wrap is multi-GB — run it under `tmux`/`nohup`.
  If it dies anyway, rerun: it resumes.
- **The bare `.tar.gz` is not in the manifest**, only its parts are — which is why the
  script derives the extensions filename from a part name.
- **Assumes one wrap bundle** (`kamiwaza-helm.00`). A release split across `.01`/`.02`
  would need the grouping loop extended (not seen so far).
