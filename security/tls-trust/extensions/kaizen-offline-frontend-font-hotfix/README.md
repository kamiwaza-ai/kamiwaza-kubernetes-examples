# Kaizen offline frontend font hotfix (0.13.0)

Use this only for disconnected `release/0.13.0` installs where one or more
Kaizen frontends fail during their App Garden startup rebuild because
`next/font/google` tries to reach Google Fonts.

For the slim copy/paste procedure, use [README-manual.md](README-manual.md).

The hotfix derives a new frontend image from the bundled offline image tar. It
does **not** run `npm install`, does **not** need source checkout, and does
**not** need internet access. It changes only the runtime rebuild source under
`/app/src`:

- removes `next/font/google` from `app/layout.tsx`
- defines `--font-geist-sans` and `--font-geist-mono` as system font stacks in
  `app/globals.css`

This trades exact Geist rendering for an offline-safe startup. The goal is to
fix **all Kaizens on the host**:

- future Kaizens, by replacing the bundled offline image tar for the same
  `frontend:1.8.13` image reference
- existing Kaizens, by replacing that same image reference in Kind containerd and
  restarting every Kaizen frontend deployment

The durable product fix is to ship local font files or stop using
`next/font/google` in the release image.

## When to run this

Best case, run it after extracting the offline extension bundle, but before
running `install-extensions-bundle.sh` or applying the Kaizen extension manifest.
That covers every future Kaizen launch from this bundle.

If Kaizen is already installed, still run the same image-tar patch, then force
load the patched image into Kind and restart all existing Kaizen frontends. Do
not patch a single Kaizen to a one-off image tag unless you intentionally want a
single-instance test.

This procedure patches the extracted bundle root. If you re-pack the aggregate
`kamiwaza-extensions-bundle-*.tar.gz` after this, regenerate its top-level
`.sha256` file too.

This runbook intentionally keeps the original image reference:

```text
ghcr.io/kamiwaza-internal/kamiwaza-extensions-kaizen/images/frontend:1.8.13
```

Keeping the same reference means the catalog, app template, and existing
`KamiwazaExtension` CRs can all continue to point at the same image.

## Inputs

Set these to match the extracted bundle on the install host:

```bash
BUNDLE_ROOT="/opt/tmp/2026-05-16/extensions-bundle-full/extracted/kamiwaza-extensions-bundle-20260516-194649"
ORIG_IMAGE="ghcr.io/kamiwaza-internal/kamiwaza-extensions-kaizen/images/frontend:1.8.13"
IMAGE_TAR="${BUNDLE_ROOT}/repos/kamiwaza-extensions-kaizen/registry/garden/v3/docker-images/ghcr.io_kamiwaza-internal_kamiwaza-extensions-kaizen_images_frontend_1.8.13.tar"
WORKDIR="/tmp/kaizen-frontend-font-hotfix"
KIND_CLUSTER_NAME="${KIND_CLUSTER_NAME:-kamiwaza-prod}"
KIND_NODE="${KIND_CLUSTER_NAME}-control-plane"
```

Podman may need storage outside the user's home directory on small RHEL images:

```bash
PODMAN_ROOT="${PODMAN_ROOT:-/opt/tmp/kaizen-font-hotfix-podman-root}"
PODMAN_RUNROOT="${PODMAN_RUNROOT:-/tmp/kaizen-font-hotfix-podman-run}"
mkdir -p "${PODMAN_ROOT}" "${PODMAN_RUNROOT}" "${WORKDIR}"

PODMAN=(podman --root "${PODMAN_ROOT}" --runroot "${PODMAN_RUNROOT}")
```

If rootless `crun` is mis-owned on the host, use `runc`:

```bash
PODMAN=(podman --root "${PODMAN_ROOT}" --runroot "${PODMAN_RUNROOT}" --runtime /usr/bin/runc)
```

## 1. Load the bundled image

```bash
"${PODMAN[@]}" image exists "${ORIG_IMAGE}" || "${PODMAN[@]}" load -i "${IMAGE_TAR}"
```

## 2. Extract the source files from the image

```bash
rm -rf "${WORKDIR}"
mkdir -p "${WORKDIR}"

CID="$("${PODMAN[@]}" create "${ORIG_IMAGE}")"
"${PODMAN[@]}" cp "${CID}:/app/src/app/layout.tsx" "${WORKDIR}/layout.tsx"
"${PODMAN[@]}" cp "${CID}:/app/src/app/globals.css" "${WORKDIR}/globals.css"
"${PODMAN[@]}" rm "${CID}" >/dev/null
```

## 3. Patch the files locally

```bash
cd "${WORKDIR}"

python3 - <<'PY'
import re
from pathlib import Path

layout = Path("layout.tsx")
text = layout.read_text(encoding="utf-8")
text = text.replace('import { Geist, Geist_Mono } from "next/font/google";\n', "")
text = text.replace(
    """const geistSans = Geist({
  variable: "--font-geist-sans",
  subsets: ["latin"],
});

const geistMono = Geist_Mono({
  variable: "--font-geist-mono",
  subsets: ["latin"],
});

""",
    "",
)
text = text.replace(
    "${geistSans.variable} ${geistMono.variable} antialiased${",
    "antialiased${",
)
if "next/font/google" in text or "Geist(" in text or "Geist_Mono(" in text:
    raise SystemExit("layout.tsx still references Google font helpers")
layout.write_text(text, encoding="utf-8")

css_path = Path("globals.css")
css = css_path.read_text(encoding="utf-8")
if "  --font-geist-sans:" not in css:
    css = re.sub(
        r"(:root\s*\{\s*\n)",
        r'\1  --font-geist-sans: ui-sans-serif, system-ui, -apple-system, BlinkMacSystemFont, "Segoe UI", sans-serif;\n'
        r'  --font-geist-mono: ui-monospace, SFMono-Regular, Menlo, Monaco, Consolas, "Liberation Mono", monospace;\n',
        css,
        count=1,
    )
if "  --font-geist-mono:" not in css:
    raise SystemExit("globals.css missing --font-geist-mono after patch")
css_path.write_text(css, encoding="utf-8")
PY
```

## 4. Build the patched image without network

This retags the derived image as the same `frontend:1.8.13` reference used by
the `0.13.0` bundle. That is intentional: the catalog and extension manifest do
not need to change when this is done before install.

```bash
cat > Containerfile <<'EOF'
ARG ORIG_IMAGE
FROM ${ORIG_IMAGE}
COPY --chown=1001:1001 layout.tsx /app/src/app/layout.tsx
COPY --chown=1001:1001 globals.css /app/src/app/globals.css
USER 1001:1001
EOF

"${PODMAN[@]}" build \
  --pull=false \
  --network none \
  --build-arg ORIG_IMAGE="${ORIG_IMAGE}" \
  -t "${ORIG_IMAGE}" \
  .
```

## 5. Test the offline runtime rebuild

This is the important proof. It forces the same path-based-routing rebuild that
Kaizen runs at startup, with the container network disabled:

```bash
"${PODMAN[@]}" run --rm \
  --network none \
  -e KAMIWAZA_APP_PATH=/kaizen-font-hotfix-test \
  -e NEXT_BUILD_MAX_OLD_SPACE_SIZE=1536 \
  "${ORIG_IMAGE}" \
  true
```

Pass criteria:

- `next build` completes
- output includes `Rebuild complete`
- there are no `fonts.googleapis.com`, `fonts.gstatic.com`, or `next/font/google`
  errors

Verify the patched source is present:

```bash
"${PODMAN[@]}" run --rm --entrypoint sh "${ORIG_IMAGE}" -c \
  '! grep -R "next/font/google\|Geist(" -n /app/src/app/layout.tsx && grep -n -- "--font-geist-sans" /app/src/app/globals.css'
```

## 6. Replace the extracted bundle image tar

Back up the original tarball, then save the patched image back to the same path.
Use a temporary output path so a failed save cannot leave a truncated bundle
image:

```bash
cp --preserve=mode,ownership,timestamps \
  "${IMAGE_TAR}" \
  "${IMAGE_TAR}.pre-font-hotfix"

"${PODMAN[@]}" save -o "${IMAGE_TAR}.tmp" "${ORIG_IMAGE}"
mv "${IMAGE_TAR}.tmp" "${IMAGE_TAR}"
```

The `0.13.0` extension bundle generated on `2026-05-16` has a top-level
`bundle-manifest.json` that records repo metadata, not per-image tarball
checksums. There is no per-image manifest to update in that bundle layout.

If the extension bundle is not installed yet, install it normally. The patched
tarball will be loaded into Kind and all new Kaizens will use it:

```bash
"${BUNDLE_ROOT}/scripts/install-extensions-bundle.sh" \
  --bundle-root "${BUNDLE_ROOT}" \
  --container-cli podman \
  --sudo-mode always \
  --api-url https://localhost/api \
  --username admin \
  --password '<admin-password>' \
  --install-all-extensions
```

## 7. Replace the image in Kind for existing Kaizens

If Kaizen may already be installed, force replace the same image reference in
the Kind node's containerd. This covers all existing Kaizens after their
frontend pods restart, and all future Kaizens launched on this host.

The bundled install helper skips image imports when the target image already
exists, so do this explicit replacement for already-installed clusters:

```bash
sudo podman exec "${KIND_NODE}" \
  ctr -n k8s.io images rm "${ORIG_IMAGE}" >/dev/null 2>&1 || true

sudo podman exec -i "${KIND_NODE}" \
  ctr -n k8s.io images import - < "${IMAGE_TAR}"

sudo podman exec "${KIND_NODE}" \
  ctr -n k8s.io images ls | grep -F "${ORIG_IMAGE}"
```

## 8. Restart every existing Kaizen frontend

Restart all Kaizen frontend deployments. The operator labels Kaizen deployments
with `extensions.kamiwaza.io/name=Kaizen` and service deployments with
`extensions.kamiwaza.io/service=frontend`, so this is intentionally
all-Kaizens, not a single instance:

```bash
kubectl -n kamiwaza-extensions rollout restart deployment \
  -l extensions.kamiwaza.io/name=Kaizen,extensions.kamiwaza.io/service=frontend

kubectl -n kamiwaza-extensions rollout status deployment \
  -l extensions.kamiwaza.io/name=Kaizen,extensions.kamiwaza.io/service=frontend \
  --timeout=45m
```

If `rollout restart` finds no deployments, there are no existing Kaizen
frontends yet. The patched bundle and Kind image still cover future Kaizens.

Check the new frontend pod logs for the offline rebuild:

```bash
kubectl -n kamiwaza-extensions logs \
  -l extensions.kamiwaza.io/name=Kaizen,extensions.kamiwaza.io/service=frontend \
  --tail=200
```

On the CA test host, `azureuser` did not have a kubeconfig in `~/.kube`, so the
cluster checks had to run as `sudo kubectl` to use `/root/.kube/config`.

## Tested host notes

This procedure was applied on the `0.13.0` CA test host with the bundled
`ghcr.io/kamiwaza-internal/kamiwaza-extensions-kaizen/images/frontend:1.8.13`
tarball. The patched runtime rebuild completed with `--network none` and
`KAMIWAZA_APP_PATH=/kaizen-font-hotfix-test`, then the patched tarball was
imported into `kamiwaza-prod-control-plane` under the original `frontend:1.8.13`
reference.

After restarting the Kaizen frontend deployments, the host had multiple running
Kaizen app instances. The existing `kaizen-foo-test-e2713827` instance and the
`nick-test` workroom's `kaizen-zi0brpb1-8642a3d3` instance both restarted onto
the patched image. A later `nick-test-1` workroom created
`kaizen-ry8cczx9-71c1bf0a`, which also came up on the patched image. In each
checked frontend, `/app/src/app/layout.tsx` no longer had `next/font/google`,
`geistSans`, or `geistMono` references; `/app/src/app/globals.css` contained
local fallback definitions for `--font-geist-sans` and `--font-geist-mono`; and
the pod log included `Rebuild complete`.

Two host-specific findings from that test:

- `/home` was too small for rootless Podman image storage, so `--root` was
  pointed at `/opt/tmp/kaizen-font-hotfix-podman-root`.
- `/run/user/1000/crun` was root-owned, so `--runtime /usr/bin/runc` was needed
  for `podman run`.
