# Manual Kaizen Global Workroom backend hotfix

## TL;DR

Run this on the disconnected `0.13.0` install host after the extension bundle is
extracted. It patches the bundled Kaizen backend `1.8.13` image tar, imports
that same image reference into Kind, and restarts every existing Kaizen backend.
New Kaizens created afterward use the patched image too.

Uses only airgap-friendly shell tools plus `podman`, `/usr/bin/runc`, `sudo`,
and `kubectl`. `ctr` is run inside the Kind node through `sudo podman exec`.

Safe to rerun for testing: the patcher is idempotent, backups are timestamped,
and the same image reference is re-imported. The operational impact is that
every existing Kaizen backend is restarted.

## Commands

Set the bundle path. Change only this value if your extracted bundle is
somewhere else:

```bash
export BUNDLE_ROOT="/opt/tmp/2026-05-16/extensions-bundle-full/extracted/kamiwaza-extensions-bundle-20260516-194649"
```

Patch the image tar, import it into Kind, and restart all Kaizen backends:

```bash
set -euo pipefail

ORIG_IMAGE="ghcr.io/kamiwaza-internal/kamiwaza-extensions-kaizen/images/backend:1.8.13"
IMAGE_TAR="${BUNDLE_ROOT}/repos/kamiwaza-extensions-kaizen/registry/garden/v3/docker-images/ghcr.io_kamiwaza-internal_kamiwaza-extensions-kaizen_images_backend_1.8.13.tar"
WORKDIR="/tmp/kaizen-global-workroom-backend-hotfix"
PODMAN_ROOT="/opt/tmp/kaizen-global-hotfix-podman-root"
PODMAN_RUNROOT="/tmp/kaizen-global-hotfix-podman-run"
KIND_NODE="${KIND_NODE:-kamiwaza-prod-control-plane}"
BACKEND_SELECTOR="extensions.kamiwaza.io/name=Kaizen,extensions.kamiwaza.io/service=backend"
PODMAN=(podman --root "${PODMAN_ROOT}" --runroot "${PODMAN_RUNROOT}" --runtime /usr/bin/runc)

test -f "${IMAGE_TAR}"
rm -rf "${WORKDIR}"
mkdir -p \
  "${WORKDIR}/root/app/utils" \
  "${WORKDIR}/root/app/api/v1" \
  "${PODMAN_ROOT}" \
  "${PODMAN_RUNROOT}"

"${PODMAN[@]}" load -i "${IMAGE_TAR}"
CID="$("${PODMAN[@]}" create "${ORIG_IMAGE}")"
"${PODMAN[@]}" cp "${CID}:/app/app/utils/workroom_access.py" "${WORKDIR}/root/app/utils/workroom_access.py"
"${PODMAN[@]}" cp "${CID}:/app/app/api/v1/workroom.py" "${WORKDIR}/root/app/api/v1/workroom.py"
"${PODMAN[@]}" rm -f "${CID}" >/dev/null

cat > "${WORKDIR}/patch-kaizen-global-workroom-pof.sh" <<'PATCH'
#!/usr/bin/env bash
set -euo pipefail

ROOT="${1:-.}"

if [[ ! -d "$ROOT" ]]; then
  echo "usage: $0 /path/to/exploded-image-root" >&2
  exit 2
fi

die() {
  echo "ERROR: $*" >&2
  exit 1
}

find_one() {
  local pattern="$1"
  local found
  found="$(find "$ROOT" -type f -path "$pattern" | sort | head -n 1)"
  if [[ -z "$found" ]]; then
    die "Could not find $pattern under $ROOT"
  fi
  printf '%s\n' "$found"
}

require_text() {
  local needle="$1"
  local file="$2"
  grep -Fq "$needle" "$file" || die "Expected text not found in $file: $needle"
}

WORKROOM_ACCESS="$(find_one '*/app/utils/workroom_access.py')"
WORKROOM_API="$(find_one '*/app/api/v1/workroom.py')"
STAMP="$(date +%Y%m%d%H%M%S)-$$"

global_workroom_block() {
  awk '
    /^async def get_current_workroom\(/ { in_func = 1 }
    in_func && /if normalized_workroom_id == GLOBAL_WORKROOM_UUID:/ {
      printing = 1
      remaining = 32
    }
    printing {
      print
      if ($0 ~ /^        \)$/ || --remaining <= 0) {
        exit
      }
    }
  ' "$WORKROOM_API"
}

echo "Patching:"
echo "  $WORKROOM_ACCESS"
echo "  $WORKROOM_API"

require_text 'def _ensure_workroom_role_write_allowed' "$WORKROOM_ACCESS"
require_text 'GLOBAL_WORKROOM_UUID' "$WORKROOM_ACCESS"
require_text 'async def get_current_workroom' "$WORKROOM_API"
require_text 'if normalized_workroom_id == GLOBAL_WORKROOM_UUID:' "$WORKROOM_API"

cp -p "$WORKROOM_ACCESS" "$WORKROOM_ACCESS.bak-global-pof-$STAMP"
cp -p "$WORKROOM_API" "$WORKROOM_API.bak-global-pof-$STAMP"

if grep -q 'Emergency allowing Global Workroom write' "$WORKROOM_ACCESS"; then
  echo "Global write bypass already present in workroom_access.py"
else
  require_text '"""Reject write operations for missing, read-only, or unrecognized roles."""' "$WORKROOM_ACCESS"
  tmp="$(mktemp)"
  if ! awk '
    /"""Reject write operations for missing, read-only, or unrecognized roles\."""/ {
      print
      print "    if workroom_id is not None and str(workroom_id).lower() == str(GLOBAL_WORKROOM_UUID).lower():"
      print "        logger.warning("
      print "            \"Emergency allowing Global Workroom write for user %s\","
      print "            actor,"
      print "        )"
      print "        return"
      print ""
      inserted = 1
      next
    }
    { print }
    END {
      if (!inserted) {
        exit 42
      }
    }
  ' "$WORKROOM_ACCESS" > "$tmp"; then
    rm -f "$tmp"
    die "Could not insert Global write bypass; workroom_access.py layout differs too much."
  fi
  mv "$tmp" "$WORKROOM_ACCESS"
fi

tmp="$(mktemp)"
if ! awk '
  /^async def get_current_workroom\(/ {
    in_func = 1
  }
  in_func && /^@router\./ {
    in_func = 0
  }
  in_func && /if normalized_workroom_id == GLOBAL_WORKROOM_UUID:/ {
    in_global = 1
    print
    next
  }
  in_global && /interaction_mode="read"/ {
    sub(/interaction_mode="read"/, "interaction_mode=\"write\"")
  }
  in_global && /can_edit=False/ {
    sub(/can_edit=False/, "can_edit=True")
  }
  in_global && /can_run_agents=False/ {
    sub(/can_run_agents=False/, "can_run_agents=True")
  }
  in_global && /read_only_reason=GLOBAL_WORKROOM_READ_ONLY_REASON/ {
    sub(/read_only_reason=GLOBAL_WORKROOM_READ_ONLY_REASON/, "read_only_reason=None")
  }
  in_global && /status_banner=GLOBAL_WORKROOM_STATUS_BANNER/ {
    sub(/status_banner=GLOBAL_WORKROOM_STATUS_BANNER/, "status_banner=None")
  }
  in_global && /^        \)$/ {
    in_global = 0
    patched_global = 1
  }
  { print }
  END {
    if (!patched_global) {
      exit 42
    }
  }
' "$WORKROOM_API" > "$tmp"; then
  rm -f "$tmp"
  die "Could not patch Global Workroom API block; workroom.py layout differs too much."
fi
mv "$tmp" "$WORKROOM_API"

echo
echo "Verifying bypass marker:"
grep -n 'Emergency allowing Global Workroom write' "$WORKROOM_ACCESS" \
  || die "Bypass marker missing after patch."

BLOCK="$(global_workroom_block)"
if [[ -z "$BLOCK" ]]; then
  die "Could not extract get_current_workroom Global Workroom block after patch."
fi

for expected in \
  'interaction_mode="write"' \
  'can_edit=True' \
  'can_run_agents=True' \
  'read_only_reason=None' \
  'status_banner=None'
do
  grep -Fq "$expected" <<<"$BLOCK" || die "Global Workroom block missing expected text: $expected"
done

if grep -Eq 'interaction_mode="read"|can_edit=False|can_run_agents=False|read_only_reason=GLOBAL_WORKROOM_READ_ONLY_REASON|status_banner=GLOBAL_WORKROOM_STATUS_BANNER' <<<"$BLOCK"; then
  echo "$BLOCK" >&2
  die "Global Workroom block still contains read-only values."
fi

echo
echo "Verifying Global Workroom API block:"
printf '%s\n' "$BLOCK"

echo
echo "Done. Backups:"
echo "  $WORKROOM_ACCESS.bak-global-pof-$STAMP"
echo "  $WORKROOM_API.bak-global-pof-$STAMP"
PATCH

chmod +x "${WORKDIR}/patch-kaizen-global-workroom-pof.sh"
"${WORKDIR}/patch-kaizen-global-workroom-pof.sh" "${WORKDIR}/root"

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

if [ ! -f "${IMAGE_TAR}.pre-global-workroom-hotfix" ]; then
  cp --preserve=mode,ownership,timestamps "${IMAGE_TAR}" "${IMAGE_TAR}.pre-global-workroom-hotfix"
fi

"${PODMAN[@]}" save -o "${IMAGE_TAR}.tmp" "${ORIG_IMAGE}"
mv "${IMAGE_TAR}.tmp" "${IMAGE_TAR}"

sudo -n podman exec "${KIND_NODE}" \
  ctr -n k8s.io images rm "${ORIG_IMAGE}" >/dev/null 2>&1 || true
sudo -n podman exec -i "${KIND_NODE}" \
  ctr -n k8s.io images import - < "${IMAGE_TAR}"

BACKENDS="$(sudo -n kubectl -n kamiwaza-extensions get deployment \
  -l "${BACKEND_SELECTOR}" \
  -o name)"

if [ -n "${BACKENDS}" ]; then
  sudo -n kubectl -n kamiwaza-extensions rollout restart deployment \
    -l "${BACKEND_SELECTOR}"
  sudo -n kubectl -n kamiwaza-extensions rollout status deployment \
    -l "${BACKEND_SELECTOR}" \
    --timeout=20m
else
  echo "No existing Kaizen backends found; patched image will be used by future Kaizens."
fi
```

Verify one running backend pod:

```bash
POD="$(sudo -n kubectl -n kamiwaza-extensions get pod \
  -l extensions.kamiwaza.io/name=Kaizen,extensions.kamiwaza.io/service=backend \
  --field-selector=status.phase=Running \
  -o jsonpath='{.items[0].metadata.name}')"

sudo -n kubectl -n kamiwaza-extensions exec "${POD}" -- sh -lc '
  grep -n "Emergency allowing Global Workroom write" /app/app/utils/workroom_access.py
  grep -n "interaction_mode=\"write\"" /app/app/api/v1/workroom.py
  grep -n "can_run_agents=True" /app/app/api/v1/workroom.py
'
```

Browser proof:

1. Open App Garden.
2. Launch Kaizen while the session is still in Global Workroom.
3. Start a new conversation and send a message.
4. Confirm the sandbox starts and the agent run begins.

Clean up temporary Podman storage:

```bash
podman --root /opt/tmp/kaizen-global-hotfix-podman-root \
  --runroot /tmp/kaizen-global-hotfix-podman-run \
  --runtime /usr/bin/runc \
  system reset -f || true

sudo -n rm -rf \
  /opt/tmp/kaizen-global-hotfix-podman-root \
  /tmp/kaizen-global-hotfix-podman-run \
  /tmp/kaizen-global-workroom-backend-hotfix
```
