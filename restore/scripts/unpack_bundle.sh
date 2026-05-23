#!/usr/bin/env bash
# unpack_bundle.sh -- Phase 3 entry point.
# - If input is migration-bundle.tar.zst: verify SHA256, extract to ~/migration-bundle/.
# - If input is an already-extracted ~/migration-bundle/ dir: verify manifest.sha256.
# - Refuses to proceed if integrity check fails.
# - Cron-rerunnable.

set -euo pipefail

PARENT="$(cd "$(dirname "$0")/../.." && pwd)"
BUNDLE_DEFAULT="$HOME/migration-bundle"
INPUT="${1:-$BUNDLE_DEFAULT}"

audit_log() {
  local lane="$1" action="$2" target="$3" rc="$4"
  local logfile="$BUNDLE/migration.log.jsonl"
  [ -d "$BUNDLE" ] || return 0
  printf '{"ts":"%s","lane":"%s","action":"%s","target":"%s","rc":%d}\n' \
    "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$lane" "$action" "$target" "$rc" >> "$logfile"
}

# Step 1: figure out what the user has
if [ -f "$INPUT" ] && [[ "$INPUT" == *.tar.zst ]]; then
  echo "[unpack_bundle] Tarball detected: $INPUT"
  TARBALL="$INPUT"

  # Verify tarball SHA256 if companion .sha256 exists
  if [ -f "${TARBALL}.sha256" ]; then
    EXPECTED=$(awk '{print $1}' "${TARBALL}.sha256")
    ACTUAL=$(shasum -a 256 "$TARBALL" | awk '{print $1}')
    if [ "$EXPECTED" != "$ACTUAL" ]; then
      echo "[unpack_bundle] FATAL: tarball SHA256 mismatch."
      echo "  Expected: $EXPECTED"
      echo "  Actual:   $ACTUAL"
      echo "  User fix: re-transfer tarball from old Mac."
      exit 2
    fi
    echo "[unpack_bundle] Tarball SHA256 OK."
  else
    echo "[unpack_bundle] WARNING: ${TARBALL}.sha256 not present. Skipping tarball-level integrity check."
  fi

  # Extract
  if ! command -v zstd > /dev/null; then
    echo "[unpack_bundle] zstd not installed. Installing via brew..."
    brew install zstd 2>/dev/null || {
      echo "[unpack_bundle] FATAL: zstd install failed. Install zstd manually."
      exit 3
    }
  fi

  mkdir -p "$BUNDLE_DEFAULT"
  echo "[unpack_bundle] Extracting to $BUNDLE_DEFAULT ..."
  tar --use-compress-program=unzstd -xf "$TARBALL" -C "$(dirname "$BUNDLE_DEFAULT")"

  BUNDLE="$BUNDLE_DEFAULT"
elif [ -d "$INPUT" ]; then
  echo "[unpack_bundle] Directory detected: $INPUT"
  BUNDLE="$INPUT"
else
  echo "[unpack_bundle] FATAL: input not found at $INPUT"
  echo "  Expected either a directory or a .tar.zst file."
  exit 1
fi

# Step 2: sanity-check the bundle structure
for required in manifest.json manifest.sha256; do
  if [ ! -f "$BUNDLE/$required" ]; then
    echo "[unpack_bundle] FATAL: missing $BUNDLE/$required"
    echo "  Bundle is incomplete or wrong directory."
    exit 4
  fi
done

# Step 2.5: schema_version compatibility check
# This restore script understands schema_version "1". A bundle written by a
# newer skill version may have fields/layout this restore can't handle.
SUPPORTED_SCHEMA="1"
if command -v jq > /dev/null 2>&1; then
  bundle_schema=$(jq -r '.schema_version // .version // "unknown"' "$BUNDLE/manifest.json" 2>/dev/null)
  if [ "$bundle_schema" = "unknown" ]; then
    echo "[unpack_bundle] WARNING: manifest has no schema_version. Assuming legacy schema; proceeding."
  elif [ "$bundle_schema" != "$SUPPORTED_SCHEMA" ]; then
    echo "[unpack_bundle] FATAL: bundle schema_version='$bundle_schema' but this restore supports '$SUPPORTED_SCHEMA'."
    echo "  The bundle was created by a different mac-migration version."
    echo "  Fix: use a matching skill version, OR re-capture on the old Mac with this version."
    audit_log "unpack" "schema_mismatch" "$bundle_schema" 1
    exit 6
  else
    echo "[unpack_bundle] schema_version $bundle_schema OK."
  fi
else
  echo "[unpack_bundle] WARNING: jq not found; skipping schema_version check."
fi

# Step 3: verify per-file SHA256 against manifest.sha256
echo "[unpack_bundle] Verifying file integrity against manifest.sha256 ..."
cd "$BUNDLE"
MISMATCH=0
TOTAL=0
while IFS= read -r line; do
  TOTAL=$((TOTAL + 1))
  expected=$(echo "$line" | awk '{print $1}')
  relpath=$(echo "$line" | awk '{$1=""; sub(/^  /, ""); print}')

  # Skip the manifest.sha256 file itself (chicken-and-egg)
  [ "$relpath" = "manifest.sha256" ] && continue
  # Skip non-existent files (may be opt-outs)
  [ -f "$relpath" ] || continue

  actual=$(shasum -a 256 "$relpath" | awk '{print $1}')
  if [ "$expected" != "$actual" ]; then
    echo "[unpack_bundle] MISMATCH: $relpath"
    echo "  Expected: $expected"
    echo "  Actual:   $actual"
    MISMATCH=$((MISMATCH + 1))
  fi
done < "$BUNDLE/manifest.sha256"

if [ "$MISMATCH" -gt 0 ]; then
  echo "[unpack_bundle] FATAL: $MISMATCH file(s) failed SHA256 verification."
  echo "  User fix: re-transfer bundle from old Mac (USB / AirDrop / iCloud may have corrupted bytes)."
  audit_log "unpack" "verify_sha256" "$BUNDLE" 1
  exit 5
fi

echo "[unpack_bundle] All $TOTAL files verified OK."
audit_log "unpack" "verify_sha256" "$BUNDLE" 0

# Step 4: prerequisite checks
PREREQ_MISSING=()
if ! xcode-select -p > /dev/null 2>&1; then
  PREREQ_MISSING+=("Xcode Command Line Tools -- run: xcode-select --install")
fi

if [ ${#PREREQ_MISSING[@]} -gt 0 ]; then
  PREREQ_FILE="$BUNDLE/MANUAL-STEPS-prerequisites.md"
  {
    echo "# Prerequisites missing on new Mac"
    echo
    echo "Resolve these before re-running restore."
    echo
    for item in "${PREREQ_MISSING[@]}"; do
      echo "- $item"
    done
  } > "$PREREQ_FILE"
  echo "[unpack_bundle] FATAL: prerequisites missing. See $PREREQ_FILE"
  audit_log "unpack" "prereq_check" "$BUNDLE" 1
  exit 6
fi

# Step 5: make .done dir if not present
mkdir -p "$BUNDLE/.done"

echo "[unpack_bundle] OK. Bundle ready at $BUNDLE"
echo "[unpack_bundle] Next: run restore_lane_a_apps.sh"
audit_log "unpack" "ready" "$BUNDLE" 0
exit 0
