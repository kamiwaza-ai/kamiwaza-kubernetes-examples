#!/usr/bin/env bash
#
# download-bundle.sh
#
# Downloads + reassembles the latest Kamiwaza offline bundle from Keygen.
# Step 1 of the offline install docs. Linux amd64 / RHEL 9.
#   https://docs.kamiwaza.ai/installation/offline_install#step-1-download-the-bundle-artifacts
#
# It resolves "latest" from the "Kamiwaza Offline Bundles" Keygen package and
# uses that release's artifact list as the download manifest, so the exact file
# set (helm parts, the timestamped extensions bundle, part counts, rpm name)
# comes straight from Keygen — nothing is hardcoded per release.
#
# Required env:  KEYGEN_LICENSE   (your Kamiwaza license key)
# Optional env:
#   RELEASE      e.g. 1.0.0   (default: latest stable in the package)
#   DEST         download dir (default: /opt/kamiwaza/prereqs)
#   PACKAGE_ID   override the offline-bundles package id
#   KEEP_PARTS=1 keep the split .part-NNN files after assembly
#
# Rerun-safe: existing files are skipped, partial downloads resume.
# Run `--self-test` to check the bundle-grouping logic offline.
set -euo pipefail

ACCOUNT="kamiwaza"
PRODUCT="kamiwaza-prod"
PKG_BASE="https://raw.pkg.keygen.sh/${ACCOUNT}/${PRODUCT}/@bundles"
API="https://api.keygen.sh/v1/accounts/${ACCOUNT}"
# "Kamiwaza Offline Bundles" — every component package has its own 1.0.0, so
# resolving latest is scoped to this one package's releases.
PACKAGE_ID="${PACKAGE_ID:-f72f5b94-a283-48b7-8dc3-327564f98eb9}"

# ---- offline self-test of the part-grouping logic ------------------------
if [[ "${1:-}" == "--self-test" ]]; then
  # fixture mirrors the real manifest: parts + sidecars, NO bare .tar.gz
  files=(kamiwaza-helm.00.tar.part-002 kamiwaza-helm.00.tar.part-000
    kamiwaza-helm.00.tar.part-001 release_origination.md kamiwaza-helm.sha256
    kamiwaza-extensions-bundle-20260710-133916.tar.gz.sha256
    kamiwaza-extensions-bundle-20260710-133916.tar.gz.part-001
    kamiwaza-extensions-bundle-20260710-133916.tar.gz.part-000)
  hp=$(printf '%s\n' "${files[@]}" | grep -E '^kamiwaza-helm\.00\.tar\.part-[0-9]+$' | sort -V | tr '\n' ' ')
  eb=$(printf '%s\n' "${files[@]}" | grep -m1 -E '^kamiwaza-extensions-bundle-[0-9]{8}-[0-9]{6}\.tar\.gz\.part-[0-9]+$' || true)
  eb="${eb%.part-*}"
  ep=$(printf '%s\n' "${files[@]}" | grep -E "^${eb//./\\.}\.part-[0-9]+$" | sort -V | tr '\n' ' ')
  [[ "$hp" == "kamiwaza-helm.00.tar.part-000 kamiwaza-helm.00.tar.part-001 kamiwaza-helm.00.tar.part-002 " ]] || {
    echo "FAIL helm: [$hp]"
    exit 1
  }
  [[ "$eb" == "kamiwaza-extensions-bundle-20260710-133916.tar.gz" ]] || {
    echo "FAIL ext base: [$eb]"
    exit 1
  }
  [[ "$ep" == "kamiwaza-extensions-bundle-20260710-133916.tar.gz.part-000 kamiwaza-extensions-bundle-20260710-133916.tar.gz.part-001 " ]] || {
    echo "FAIL ext parts: [$ep]"
    exit 1
  }
  echo OK
  exit 0
fi

: "${KEYGEN_LICENSE:?set KEYGEN_LICENSE to your Kamiwaza license key}"
command -v python3 >/dev/null || {
  echo "python3 is required (JSON parsing)"
  exit 1
}
DEST="${DEST:-/opt/kamiwaza/prereqs}"
auth=(-H "Authorization: License ${KEYGEN_LICENSE}")

# Set up the download dir up front (fail fast before any API work, and make a
# sudo prompt obvious instead of appearing mid-run).
echo "Download dir: ${DEST}"
if [[ ! -d "$DEST" || ! -w "$DEST" ]]; then
  echo "Creating ${DEST} (may prompt for sudo)…"
  sudo install -d -m 0755 -o "$USER" -g "$USER" "$DEST"
fi
cd "$DEST"

# GET a Keygen API url into a file; on non-200 print the body and fail.
# --globoff: ?page[...] brackets are not curl globs.
api_get() { # api_get <url> <outfile>
  local code
  code="$(curl -sSL --globoff -w '%{http_code}' "${auth[@]}" -o "$2" "$1" 2>/dev/null || echo 000)"
  [[ "$code" == 200 ]] && return 0
  echo "Keygen API error (HTTP ${code}): $1" >&2
  head -c 800 "$2" >&2
  echo >&2
  return 1
}

work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT
rel_json="${work}/releases.json"
art_json="${work}/artifacts.json"

# ---- resolve release + id from the offline-bundles package ----------------
echo "Resolving releases from Keygen (Kamiwaza Offline Bundles)…"
api_get "${API}/releases?page[number]=1&page[size]=100&package=${PACKAGE_ID}" "$rel_json" || {
  echo "Could not list releases (bad license key, or package id changed)." >&2
  exit 1
}

# stable "version<TAB>id" pairs (drop 1.0.0-rc.1 style prereleases)
mapfile -t rels < <(python3 - "$rel_json" <<'PY'
import sys, json
d = json.load(open(sys.argv[1]))
for r in d.get("data", []):
    a = r.get("attributes", {})
    v = a.get("version") or a.get("tag") or ""
    if v and "-" not in v:
        print(v + "\t" + str(r.get("id")))
PY
)
[[ ${#rels[@]} -gt 0 ]] || {
  echo "No stable releases found in the package." >&2
  exit 1
}

if [[ -n "${RELEASE:-}" ]]; then
  RID="$(printf '%s\n' "${rels[@]}" | awk -F'\t' -v v="$RELEASE" '$1==v{print $2; exit}' || true)"
  [[ -n "$RID" ]] || {
    echo "Release ${RELEASE} not found. Available:" >&2
    printf '  %s\n' "${rels[@]%%$'\t'*}" >&2
    exit 1
  }
else
  latest="$(printf '%s\n' "${rels[@]}" | sort -V | tail -1)"
  RELEASE="${latest%%$'\t'*}"
  RID="${latest##*$'\t'}"
fi
BASE="${PKG_BASE}/${RELEASE}"
echo "Release: ${RELEASE}  (id ${RID})"

# ---- artifact manifest for that release -----------------------------------
# ponytail: single page (size 100). A bundle is ~25 files; add pagination if
# one ever exceeds 100.
api_get "${API}/releases/${RID}/artifacts?page[number]=1&page[size]=100" "$art_json" || {
  echo "Could not list artifacts for ${RELEASE}." >&2
  exit 1
}
mapfile -t files < <(python3 - "$art_json" <<'PY'
import sys, json
d = json.load(open(sys.argv[1]))
for r in d.get("data", []):
    f = r.get("attributes", {}).get("filename")
    if f:
        print(f)
PY
)
[[ ${#files[@]} -gt 0 ]] || {
  echo "Empty artifact manifest — aborting." >&2
  exit 1
}
echo "Manifest: ${#files[@]} files"

# ---- identify the bundle parts from the manifest --------------------------
# ponytail: assumes a single helm wrap bundle (kamiwaza-helm.00). Multi-bundle
# releases (.01, .02) would need a loop; not seen yet.
mapfile -t helm_parts < <(printf '%s\n' "${files[@]}" |
  grep -E '^kamiwaza-helm\.00\.tar\.part-[0-9]+$' | sort -V)
# The bare .tar.gz is not in the manifest (only its parts are), so derive the
# base name from a part and strip the .part-NNN suffix.
# grep -m1 (not | head -1): head closing the pipe early SIGPIPEs grep, which
# under `set -o pipefail` fails the pipeline and silently kills the script.
ext_base="$(printf '%s\n' "${files[@]}" |
  grep -m1 -E '^kamiwaza-extensions-bundle-[0-9]{8}-[0-9]{6}\.tar\.gz\.part-[0-9]+$' || true)"
ext_base="${ext_base%.part-*}"
mapfile -t ext_parts < <(printf '%s\n' "${files[@]}" |
  grep -E "^${ext_base//./\\.}\.part-[0-9]+$" | sort -V)
[[ ${#helm_parts[@]} -gt 0 && -n "$ext_base" && ${#ext_parts[@]} -gt 0 ]] || {
  echo "Could not identify bundle parts in the manifest — aborting before assembly." >&2
  exit 1
}

# ---- download -------------------------------------------------------------
fetch() { # fetch <file>: skip if present, resume+retry otherwise
  [[ -f "$1" ]] && return 0
  echo "  ↓ $1"
  curl -fL --retry 5 --retry-delay 10 --retry-all-errors --continue-at - \
    "${auth[@]}" -o "$1" "${BASE}/$1"
}
# Skip a bundle's parts if it's already assembled — parts are removed after a
# successful assemble, so a rerun must not re-fetch the ~12GB it just deleted.
dl=0
for f in "${files[@]}"; do
  case "$f" in
    kamiwaza-helm.00.tar.part-*) [[ -f kamiwaza-helm.00.tar ]] && continue ;;
    "${ext_base}".part-*) [[ -f "$ext_base" ]] && continue ;;
  esac
  [[ -f "$f" ]] || dl=$((dl + 1))
  fetch "$f"
done
echo "Downloads: ${dl} fetched, $((${#files[@]} - dl)) already present/assembled"

# verify each part, re-downloading any that is missing/corrupt (idempotent)
verify_parts() { # verify_parts <part>...
  local p
  for p in "$@"; do
    sha256sum -c "${p}.sha256" >/dev/null 2>&1 && continue
    echo "  ✗ ${p} missing/corrupt — re-downloading"
    rm -f "$p"
    fetch "$p"
    sha256sum -c "${p}.sha256"
  done
}

# concat only if the assembled file isn't already there; .tmp+mv so an
# interrupted concat never leaves a half-file that looks complete.
assemble() { # assemble <out> <part>...
  local out="$1"
  shift
  if [[ -f "$out" ]]; then
    echo "✓ ${out} already assembled — skipping"
    return 0
  fi
  echo "Assembling ${out} ($# parts)…"
  verify_parts "$@"
  cat "$@" >"${out}.tmp" && mv -f "${out}.tmp" "$out"
}

# remove parts (+ .sha256 sidecars) once the bundle is assembled AND verified.
# KEEP_PARTS=1 keeps them (e.g. to re-verify or redistribute the split files).
clean_parts() { # clean_parts <part>...
  [[ "${KEEP_PARTS:-0}" == 1 ]] && return 0
  [[ -f "$1" ]] || return 0 # already cleaned on a prior run
  local p
  for p in "$@"; do rm -f "$p" "${p}.sha256"; done
  echo "  removed $# parts + sidecars (KEEP_PARTS=1 to keep)"
}

# --- helm wrap bundle ---
assemble kamiwaza-helm.00.tar "${helm_parts[@]}"
ln -sf kamiwaza-helm.00.tar kamiwaza-helm.tar
echo "Verifying kamiwaza-helm.tar…"
sha256sum -c kamiwaza-helm.sha256
clean_parts "${helm_parts[@]}"

# --- extensions bundle ---
assemble "$ext_base" "${ext_parts[@]}"
echo "Verifying ${ext_base}…"
sha256sum -c "${ext_base}.sha256"
clean_parts "${ext_parts[@]}"

cat <<DONE

Done. Artifacts in ${DEST}
  RELEASE=${RELEASE}
  EXT_BUNDLE=${ext_base}
Next: Step 2 — Install Prerequisites:
  https://docs.kamiwaza.ai/installation/offline_install#step-2-install-prerequisites
(or relocate the wrap to a registry with deployment/eks-offline-bundle)
DONE
