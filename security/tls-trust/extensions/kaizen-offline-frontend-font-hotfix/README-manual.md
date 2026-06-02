# Manual Kaizen frontend font hotfix

## TL;DR

Run this on the disconnected `0.13.0` install host after the extension bundle is
extracted. It patches the bundled Kaizen frontend `1.8.13` image tar, imports
that same image reference into Kind, and restarts every existing Kaizen
frontend. New Kaizens created afterward use the patched image too.

Uses only commands verified on the CA host: `bash`, `python3`, `podman`,
`/usr/bin/runc`, `sudo`, `kubectl`, `grep`, `cp`, `mv`, `rm`, and `mkdir`.
`ctr` is run inside the Kind node through `sudo podman exec`.

Safe to rerun for testing: the backup tar is not overwritten, already-patched
source files stay patched, and the same image reference is re-imported. The
operational impact is that every existing Kaizen frontend is restarted and
rebuilds again.

## Commands

Set the bundle path. Change only this value if your extracted bundle is
somewhere else:

```bash
export BUNDLE_ROOT="/opt/tmp/2026-05-16/extensions-bundle-full/extracted/kamiwaza-extensions-bundle-20260516-194649"
```

Patch the image tar, import it into Kind, and restart all Kaizen frontends:

```bash
set -euo pipefail

ORIG_IMAGE="ghcr.io/kamiwaza-internal/kamiwaza-extensions-kaizen/images/frontend:1.8.13"
IMAGE_TAR="${BUNDLE_ROOT}/repos/kamiwaza-extensions-kaizen/registry/garden/v3/docker-images/ghcr.io_kamiwaza-internal_kamiwaza-extensions-kaizen_images_frontend_1.8.13.tar"
WORKDIR="/tmp/kaizen-frontend-font-hotfix"
PODMAN_ROOT="/opt/tmp/kaizen-font-hotfix-podman-root"
PODMAN_RUNROOT="/tmp/kaizen-font-hotfix-podman-run"
KIND_NODE="${KIND_NODE:-kamiwaza-prod-control-plane}"
FRONTEND_SELECTOR="extensions.kamiwaza.io/name=Kaizen,extensions.kamiwaza.io/service=frontend"
PODMAN=(podman --root "${PODMAN_ROOT}" --runroot "${PODMAN_RUNROOT}" --runtime /usr/bin/runc)

test -f "${IMAGE_TAR}"
rm -rf "${WORKDIR}"
mkdir -p "${WORKDIR}" "${PODMAN_ROOT}" "${PODMAN_RUNROOT}"

"${PODMAN[@]}" load -i "${IMAGE_TAR}"
CID="$("${PODMAN[@]}" create "${ORIG_IMAGE}")"
"${PODMAN[@]}" cp "${CID}:/app/src/app/layout.tsx" "${WORKDIR}/layout.tsx"
"${PODMAN[@]}" cp "${CID}:/app/src/app/globals.css" "${WORKDIR}/globals.css"
"${PODMAN[@]}" rm -f "${CID}" >/dev/null

python3 - "${WORKDIR}/layout.tsx" "${WORKDIR}/globals.css" <<'PY'
import pathlib
import re
import sys

layout_path = pathlib.Path(sys.argv[1])
globals_path = pathlib.Path(sys.argv[2])

layout = layout_path.read_text()
layout = re.sub(
    r'import\s+\{\s*Geist\s*,\s*Geist_Mono\s*\}\s+from\s+["\']next/font/google["\'];\n',
    '',
    layout,
    count=1,
)
layout = re.sub(
    r'\nconst\s+geistSans\s*=\s*Geist\(\{\s*\n\s*variable:\s*["\']--font-geist-sans["\'],\s*\n\s*subsets:\s*\[["\']latin["\']\],\s*\n\}\);\s*\n',
    '\n',
    layout,
    count=1,
)
layout = re.sub(
    r'\nconst\s+geistMono\s*=\s*Geist_Mono\(\{\s*\n\s*variable:\s*["\']--font-geist-mono["\'],\s*\n\s*subsets:\s*\[["\']latin["\']\],\s*\n\}\);\s*\n',
    '\n',
    layout,
    count=1,
)
layout = layout.replace('${geistSans.variable} ${geistMono.variable} antialiased${', 'antialiased${')
if 'next/font/google' in layout or 'geistSans' in layout or 'geistMono' in layout:
    raise SystemExit('layout.tsx still references Google font helpers')
layout_path.write_text(layout)

css = globals_path.read_text()
if '--font-geist-sans:' not in css:
    css = re.sub(
        r'(:root\s*\{\s*\n)',
        r'\1  --font-geist-sans: ui-sans-serif, system-ui, -apple-system, BlinkMacSystemFont, "Segoe UI", sans-serif;\n  --font-geist-mono: ui-monospace, SFMono-Regular, Menlo, Monaco, Consolas, "Liberation Mono", monospace;\n',
        css,
        count=1,
    )
if '--font-geist-sans:' not in css or '--font-geist-mono:' not in css:
    raise SystemExit('globals.css font variables were not added')
globals_path.write_text(css)
PY

cat > "${WORKDIR}/Containerfile" <<'EOF'
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
  "${WORKDIR}"

"${PODMAN[@]}" run --rm \
  --network none \
  -e KAMIWAZA_APP_PATH=/kaizen-font-hotfix-test \
  -e NEXT_BUILD_MAX_OLD_SPACE_SIZE=1536 \
  "${ORIG_IMAGE}" \
  true

if [ ! -f "${IMAGE_TAR}.pre-font-hotfix" ]; then
  cp --preserve=mode,ownership,timestamps "${IMAGE_TAR}" "${IMAGE_TAR}.pre-font-hotfix"
fi

"${PODMAN[@]}" save -o "${IMAGE_TAR}.tmp" "${ORIG_IMAGE}"
mv "${IMAGE_TAR}.tmp" "${IMAGE_TAR}"

sudo -n podman exec "${KIND_NODE}" \
  ctr -n k8s.io images rm "${ORIG_IMAGE}" >/dev/null 2>&1 || true
sudo -n podman exec -i "${KIND_NODE}" \
  ctr -n k8s.io images import - < "${IMAGE_TAR}"

FRONTENDS="$(sudo -n kubectl -n kamiwaza-extensions get deployment \
  -l "${FRONTEND_SELECTOR}" \
  -o name)"

if [ -n "${FRONTENDS}" ]; then
  sudo -n kubectl -n kamiwaza-extensions rollout restart deployment \
    -l "${FRONTEND_SELECTOR}"
  sudo -n kubectl -n kamiwaza-extensions rollout status deployment \
    -l "${FRONTEND_SELECTOR}" \
    --timeout=45m
else
  echo "No existing Kaizen frontends found; patched image will be used by future Kaizens."
fi
```

Verify:

```bash
sudo -n kubectl get kamiwazaextensions -n kamiwaza-extensions | grep -i kaizen

sudo -n kubectl -n kamiwaza-extensions get pods \
  -l extensions.kamiwaza.io/name=Kaizen,extensions.kamiwaza.io/service=frontend

POD="$(sudo -n kubectl -n kamiwaza-extensions get pod \
  -l extensions.kamiwaza.io/name=Kaizen,extensions.kamiwaza.io/service=frontend \
  --field-selector=status.phase=Running \
  -o jsonpath='{.items[0].metadata.name}')"

sudo -n kubectl -n kamiwaza-extensions exec "${POD}" -- sh -lc \
  'grep -n "next/font/google\|geistSans\|geistMono" /app/src/app/layout.tsx || true; grep -n -- "--font-geist-sans\|--font-geist-mono" /app/src/app/globals.css'

sudo -n kubectl -n kamiwaza-extensions logs "${POD}" --tail=80 | grep -E "Rebuild complete|Ready in"
```

Clean up temporary Podman storage:

```bash
podman --root /opt/tmp/kaizen-font-hotfix-podman-root \
  --runroot /tmp/kaizen-font-hotfix-podman-run \
  --runtime /usr/bin/runc \
  system reset -f || true

sudo -n rm -rf \
  /opt/tmp/kaizen-font-hotfix-podman-root \
  /tmp/kaizen-font-hotfix-podman-run \
  /tmp/kaizen-frontend-font-hotfix
```
