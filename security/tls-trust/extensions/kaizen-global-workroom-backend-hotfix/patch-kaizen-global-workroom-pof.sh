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
