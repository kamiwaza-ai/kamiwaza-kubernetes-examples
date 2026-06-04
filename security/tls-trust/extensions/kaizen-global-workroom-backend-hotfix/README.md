# Kaizen Global Workroom backend hotfix (0.13.0 proof-of-life)

Use this only for disconnected `release/0.13.0` installs where Workroom
Manager or workroom session binding is broken, but you need a Kaizen
proof-of-life path from App Garden. This patches the Kaizen **backend** image so
Global Workroom is treated as writable by Kaizen and the shell reports that
agents can run.

For the slim copy/paste procedure, use [MANUAL.md](MANUAL.md).

This is a break-glass workaround. It intentionally removes Kaizen's Global
Workroom read-only block. It is for "make Kaizen launch a sandbox now" testing,
not for a security-preserving production fix.

The hotfix derives a new backend image from the bundled offline image tar. It
does **not** run `pip install`, does **not** need source checkout, and does
**not** need internet access. It changes only two runtime source files under
`/app/app`:

- `app/utils/workroom_access.py`
- `app/api/v1/workroom.py`

The goal is to fix **all Kaizens on the host**:

- future Kaizens, by replacing the bundled offline image tar for the same
  `backend:1.8.13` image reference
- existing Kaizens, by replacing that same image reference in Kind containerd
  and restarting every Kaizen backend deployment

The durable product fix is to repair Workroom Manager / ForwardAuth session
binding and backport the intended Global agent lifecycle behavior. This page is
only the emergency image surgery.

## What this changes

The patch does two things:

1. In `workroom_access.py`, `_ensure_workroom_role_write_allowed(...)` returns
   early when the request workroom is the Global Workroom UUID
   `ffffffff-ffff-ffff-ffff-ffffffffffff`.
2. In `workroom.py`, `GET /api/workroom` reports Global as:

   ```python
   interaction_mode="write"
   can_edit=True
   can_run_agents=True
   read_only_reason=None
   status_banner=None
   ```

That backend response unlocks the existing frontend without rebuilding the
frontend image.

## When to run this

Best case, run it after extracting the offline extension bundle, but before
running `install-extensions-bundle.sh` or applying the Kaizen extension
manifest. That covers every future Kaizen launch from this bundle.

If Kaizen is already installed, still run the same image-tar patch, then force
load the patched image into Kind and restart all existing Kaizen backend
deployments. Do not patch a single Kaizen to a one-off image tag unless you
intentionally want a single-instance test.

This procedure patches the extracted bundle root. If you re-pack the aggregate
`kamiwaza-extensions-bundle-*.tar.gz` after this, regenerate its top-level
`.sha256` file too.

This runbook intentionally keeps the original image reference:

```text
ghcr.io/kamiwaza-internal/kamiwaza-extensions-kaizen/images/backend:1.8.13
```

Keeping the same reference means the catalog, app template, and existing
`KamiwazaExtension` CRs can all continue to point at the same image.

## Inputs

Set these to match the extracted bundle on the install host:

```bash
BUNDLE_ROOT="/opt/tmp/2026-05-16/extensions-bundle-full/extracted/kamiwaza-extensions-bundle-20260516-194649"
ORIG_IMAGE="ghcr.io/kamiwaza-internal/kamiwaza-extensions-kaizen/images/backend:1.8.13"
IMAGE_TAR="${BUNDLE_ROOT}/repos/kamiwaza-extensions-kaizen/registry/garden/v3/docker-images/ghcr.io_kamiwaza-internal_kamiwaza-extensions-kaizen_images_backend_1.8.13.tar"
WORKDIR="/tmp/kaizen-global-workroom-backend-hotfix"
KIND_CLUSTER_NAME="${KIND_CLUSTER_NAME:-kamiwaza-prod}"
KIND_NODE="${KIND_CLUSTER_NAME}-control-plane"
BACKEND_SELECTOR="extensions.kamiwaza.io/name=Kaizen,extensions.kamiwaza.io/service=backend"
```

Podman may need storage outside the user's home directory on small RHEL images:

```bash
PODMAN_ROOT="${PODMAN_ROOT:-/opt/tmp/kaizen-global-hotfix-podman-root}"
PODMAN_RUNROOT="${PODMAN_RUNROOT:-/tmp/kaizen-global-hotfix-podman-run}"
mkdir -p "${PODMAN_ROOT}" "${PODMAN_RUNROOT}" "${WORKDIR}"

PODMAN=(podman --root "${PODMAN_ROOT}" --runroot "${PODMAN_RUNROOT}")
```

If rootless `crun` is mis-owned on the host, use `runc`:

```bash
PODMAN=(podman --root "${PODMAN_ROOT}" --runroot "${PODMAN_RUNROOT}" --runtime /usr/bin/runc)
```

## 1. Load the bundled backend image

```bash
test -f "${IMAGE_TAR}"
"${PODMAN[@]}" image exists "${ORIG_IMAGE}" || "${PODMAN[@]}" load -i "${IMAGE_TAR}"
```

## 2. Extract the target source files from the image

```bash
rm -rf "${WORKDIR}"
mkdir -p "${WORKDIR}/root/app/utils" "${WORKDIR}/root/app/api/v1"

CID="$("${PODMAN[@]}" create "${ORIG_IMAGE}")"
"${PODMAN[@]}" cp "${CID}:/app/app/utils/workroom_access.py" "${WORKDIR}/root/app/utils/workroom_access.py"
"${PODMAN[@]}" cp "${CID}:/app/app/api/v1/workroom.py" "${WORKDIR}/root/app/api/v1/workroom.py"
"${PODMAN[@]}" rm -f "${CID}" >/dev/null
```

## 3. Patch the extracted files

Use the repo script if this checkout is available:

```bash
security/tls-trust/extensions/kaizen-global-workroom-backend-hotfix/patch-kaizen-global-workroom-pof.sh \
  "${WORKDIR}/root"
```

Or paste the script from
[`patch-kaizen-global-workroom-pof.sh`](patch-kaizen-global-workroom-pof.sh)
onto the install host and run it against `${WORKDIR}/root`.

The script is intentionally strict. If the customer image has drifted, it fails
with `ERROR:` rather than silently patching the wrong block.

## 4. Build the patched backend image without network

This retags the derived image as the same `backend:1.8.13` reference used by the
`0.13.0` bundle. That is intentional: the catalog and extension manifest do not
need to change when this is done before install.

```bash
cat > "${WORKDIR}/Containerfile" <<'EOF'
ARG ORIG_IMAGE
FROM ${ORIG_IMAGE}
COPY --chown=1001:1001 root/app/utils/workroom_access.py /app/app/utils/workroom_access.py
COPY --chown=1001:1001 root/app/api/v1/workroom.py /app/app/api/v1/workroom.py
USER 1001:1001
EOF

"${PODMAN[@]}" build \
  --pull=false \
  --network none \
  --build-arg ORIG_IMAGE="${ORIG_IMAGE}" \
  -t "${ORIG_IMAGE}" \
  "${WORKDIR}"
```

## 5. Test the patched image

Check Python syntax and verify the patch markers inside the image:

```bash
"${PODMAN[@]}" run --rm --entrypoint python "${ORIG_IMAGE}" \
  -m py_compile \
  /app/app/utils/workroom_access.py \
  /app/app/api/v1/workroom.py

"${PODMAN[@]}" run --rm --entrypoint sh "${ORIG_IMAGE}" -lc '
  set -e
  grep -n "Emergency allowing Global Workroom write" /app/app/utils/workroom_access.py
  sed -n "/if normalized_workroom_id == GLOBAL_WORKROOM_UUID:/,/shared_credentials_enabled=/p" \
    /app/app/api/v1/workroom.py \
    | grep -E "interaction_mode=\"write\"|can_edit=True|can_run_agents=True|read_only_reason=None|status_banner=None"
'
```

Pass criteria:

- `py_compile` exits 0
- the backend image contains the `Emergency allowing Global Workroom write`
  marker
- the Global Workroom API block contains the writable/can-run-agents values

## 6. Replace the extracted bundle image tar

Back up the original tarball, then save the patched image back to the same path.
Use a temporary output path so a failed save cannot leave a truncated bundle
image:

```bash
if [ ! -f "${IMAGE_TAR}.pre-global-workroom-hotfix" ]; then
  cp --preserve=mode,ownership,timestamps \
    "${IMAGE_TAR}" \
    "${IMAGE_TAR}.pre-global-workroom-hotfix"
fi

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
the Kind node's containerd. This covers all existing Kaizens after their backend
pods restart, and all future Kaizens launched on this host.

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

## 8. Restart every existing Kaizen backend

Restart all Kaizen backend deployments. The operator labels Kaizen deployments
with `extensions.kamiwaza.io/name=Kaizen` and service deployments with
`extensions.kamiwaza.io/service=backend`, so this is intentionally all-Kaizens,
not a single instance:

```bash
kubectl -n kamiwaza-extensions rollout restart deployment \
  -l "${BACKEND_SELECTOR}"

kubectl -n kamiwaza-extensions rollout status deployment \
  -l "${BACKEND_SELECTOR}" \
  --timeout=20m
```

If `rollout restart` finds no deployments, there are no existing Kaizen
backends yet. The patched bundle and Kind image still cover future Kaizens.

On some locked-down hosts, the logged-in user may not have a kubeconfig in
`~/.kube`; run the same commands as `sudo kubectl` if the cluster was installed
under root.

## 9. Verify in the running backend

Check the patched source exists in a running backend pod:

```bash
POD="$(kubectl -n kamiwaza-extensions get pod \
  -l "${BACKEND_SELECTOR}" \
  --field-selector=status.phase=Running \
  -o jsonpath='{.items[0].metadata.name}')"

kubectl -n kamiwaza-extensions exec "${POD}" -- sh -lc '
  grep -n "Emergency allowing Global Workroom write" /app/app/utils/workroom_access.py
  sed -n "/if normalized_workroom_id == GLOBAL_WORKROOM_UUID:/,/shared_credentials_enabled=/p" \
    /app/app/api/v1/workroom.py \
    | grep -E "interaction_mode=\"write\"|can_edit=True|can_run_agents=True|read_only_reason=None|status_banner=None"
'
```

Then use the browser:

1. Open App Garden.
2. Launch Kaizen in the Global Workroom scope.
3. Start a new conversation and send a message.
4. Confirm a sandbox launches and the agent run starts.

If the browser still shows read-only Global Workroom state, hard-refresh the
Kaizen tab so the frontend fetches the new `/api/workroom` response.

Check backend logs for the proof marker while testing:

```bash
kubectl -n kamiwaza-extensions logs "${POD}" --tail=200 \
  | grep -F "Emergency allowing Global Workroom write" || true
```

## Troubleshooting

If the patch script exits with `ERROR:`, stop and inspect the printed reason.
The customer image likely has a different source layout or a drifted
`get_current_workroom` block. The script leaves `.bak-global-pof-*` backups next
to each edited file.

If the API is writable but the UI still refuses to send, verify the running
backend returns writable Global status:

```bash
kubectl -n kamiwaza-extensions exec "${POD}" -- sh -lc \
  'grep -n "interaction_mode=\"write\"" /app/app/api/v1/workroom.py && grep -n "can_run_agents=True" /app/app/api/v1/workroom.py'
```

If the UI can create a conversation but the agent does not run, check the run
endpoint path by watching backend logs while pressing send. The broad
`workroom_access.py` bypass should cover create, send, run, pause, approve,
reject, uploads, and context writes because they funnel through the same helper.

If conversation creation returns 404 for the agent, the hotfix worked but the
selected agent is not visible in Global scope for that user. Pick a visible
default agent or create one in whatever path still works.

## Cleanup temporary Podman storage

```bash
podman --root "${PODMAN_ROOT}" \
  --runroot "${PODMAN_RUNROOT}" \
  system reset -f || true

rm -rf "${PODMAN_ROOT}" "${PODMAN_RUNROOT}" "${WORKDIR}"
```
