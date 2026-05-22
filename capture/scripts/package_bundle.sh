#!/usr/bin/env bash
# package_bundle.sh
# Final packaging step for capture phase.
#
# Responsibilities:
#   1. Verify every non-opted-out lane has its .done marker
#   2. Compute SHA256 of every file under $BUNDLE -> manifest.sha256
#   3. If --tarball: roll $BUNDLE/ into migration-bundle.tar.zst (zstd compression)
#   4. Print final summary
#
# Flags:
#   --tarball       produce migration-bundle.tar.zst above $BUNDLE
#   --skip-verify   skip .done marker verification (force-produce even if lanes incomplete)
#
# Exit codes:
#   0  success
#   50 one or more opted-in lanes are missing .done markers
#   51 SHA256 manifest write failed
#   52 tarball creation failed

set -euo pipefail

BUNDLE="${BUNDLE:-$HOME/migration-bundle}"
DO_TARBALL=0
SKIP_VERIFY=0

for arg in "$@"; do
  case "$arg" in
    --tarball)     DO_TARBALL=1 ;;
    --skip-verify) SKIP_VERIFY=1 ;;
    *) echo "package_bundle.sh: unknown arg: $arg" >&2; exit 2 ;;
  esac
done

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SUB_SKILL_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
SKILL_DIR="$(cd "$SUB_SKILL_DIR/.." && pwd)"
AUDIT="$SCRIPT_DIR/audit_log.sh"
DONE_HELPER="$SKILL_DIR/scripts/lane_done_marker.sh"
MAC_VERSION_HELPER="$SKILL_DIR/scripts/detect_macos_version.sh"
MANIFEST="$BUNDLE/manifest.json"

if [ ! -f "$MANIFEST" ]; then
  echo "package_bundle.sh: $MANIFEST not found — run inventory + capture first." >&2
  exit 3
fi

"$AUDIT" package start "Packaging bundle at $BUNDLE (tarball=$DO_TARBALL, skip_verify=$SKIP_VERIFY)"

# --- 1. Verify done markers ---------------------------------------------

# Map of lane id -> opt-out manifest key
lanes=(
  "lane-a-apps:lane_a"
  "lane-b-shell:lane_b"
  "lane-c-toolchains:lane_c"
  "lane-d-gui-configs:lane_d"
  "lane-e-browsers:lane_e"
  "lane-f-ides:lane_f"
  "lane-g-databases:lane_g"
  "lane-h-services:lane_h"
  "lane-i-creds:lane_i"
)

if [ "$SKIP_VERIFY" != "1" ]; then
  missing_lanes=()
  skipped_lanes=()
  done_lanes=()
  for pair in "${lanes[@]}"; do
    lane_id="${pair%%:*}"
    opt_key="${pair##*:}"
    if jq -e ".opt_outs.${opt_key} == true" "$MANIFEST" >/dev/null 2>&1; then
      skipped_lanes+=("$lane_id")
      continue
    fi
    if bash "$DONE_HELPER" check "$lane_id" >/dev/null 2>&1; then
      done_lanes+=("$lane_id")
    else
      missing_lanes+=("$lane_id")
    fi
  done

  if [ "${#missing_lanes[@]}" -gt 0 ]; then
    "$AUDIT" package fail "Missing .done markers: ${missing_lanes[*]}"
    echo ""
    echo "ERROR: the following opted-in lanes have not completed:"
    for m in "${missing_lanes[@]}"; do
      echo "  - $m"
    done
    echo ""
    echo "Run the corresponding capture script(s), then re-run package_bundle.sh."
    echo "Or pass --skip-verify to force-package an incomplete bundle (not recommended)."
    exit 50
  fi

  "$AUDIT" package ok "All opted-in lanes complete (${#done_lanes[@]} done, ${#skipped_lanes[@]} skipped)"
fi

# --- 2. Compute SHA256 manifest -----------------------------------------

"$AUDIT" package start "Computing SHA256 across bundle (this can take a few minutes for large bundles)"

# Walk $BUNDLE, hash everything except manifest.sha256 itself and migration.log.jsonl (which we append to during this run)
cd "$BUNDLE"
if find . -type f \
     ! -name 'manifest.sha256' \
     ! -name 'migration.log.jsonl' \
     -print0 \
   | xargs -0 shasum -a 256 > manifest.sha256.tmp 2>/dev/null; then
  mv manifest.sha256.tmp manifest.sha256
  hash_count="$(wc -l < manifest.sha256 | tr -d ' ')"
  "$AUDIT" package ok "Wrote manifest.sha256 ($hash_count file hashes)"
else
  rm -f manifest.sha256.tmp
  "$AUDIT" package fail "shasum walk failed"
  exit 51
fi
cd - >/dev/null

# --- 3. Optional tarball ------------------------------------------------

bundle_size_mb="$(du -sm "$BUNDLE" 2>/dev/null | awk '{print $1}' || echo 0)"

if [ "$DO_TARBALL" = "1" ]; then
  if ! command -v zstd >/dev/null 2>&1 && ! tar --help 2>/dev/null | grep -q -- '--zstd'; then
    "$AUDIT" package warn "zstd not available — falling back to gzip"
    tarball_path="${BUNDLE%/}.tar.gz"
    "$AUDIT" package start "Creating $tarball_path"
    if tar -czf "$tarball_path" -C "$(dirname "$BUNDLE")" "$(basename "$BUNDLE")" 2>/dev/null; then
      "$AUDIT" package ok "Wrote $tarball_path"
    else
      "$AUDIT" package fail "tar gzip creation failed"
      exit 52
    fi
  else
    tarball_path="${BUNDLE%/}.tar.zst"
    "$AUDIT" package start "Creating $tarball_path (zstd compression)"
    if tar --zstd -cf "$tarball_path" -C "$(dirname "$BUNDLE")" "$(basename "$BUNDLE")" 2>/dev/null; then
      "$AUDIT" package ok "Wrote $tarball_path"
    else
      "$AUDIT" package fail "tar zstd creation failed"
      exit 52
    fi
  fi
  tarball_size_mb="$(du -sm "$tarball_path" 2>/dev/null | awk '{print $1}' || echo 0)"
fi

# --- 4. macOS version advisory ------------------------------------------

mac_version=""
if [ -x "$MAC_VERSION_HELPER" ] || [ -f "$MAC_VERSION_HELPER" ]; then
  mac_version="$(bash "$MAC_VERSION_HELPER" 2>/dev/null || true)"
fi

# --- 5. Final summary ---------------------------------------------------

echo ""
echo "=================================================================="
echo "  Mac Migration — Capture Complete"
echo "=================================================================="
echo "  Source Mac:   ${mac_version:-unknown macOS version}"
echo "  Bundle:       $BUNDLE"
echo "  Bundle size:  ${bundle_size_mb} MB"
if [ "$DO_TARBALL" = "1" ]; then
  echo "  Tarball:      $tarball_path"
  echo "  Tar size:     ${tarball_size_mb} MB"
fi
echo "  Hashes:       $BUNDLE/manifest.sha256"
echo "  Audit log:    $BUNDLE/migration.log.jsonl"
echo ""
echo "  Lanes completed:"
if [ "$SKIP_VERIFY" != "1" ]; then
  for d in "${done_lanes[@]}"; do
    echo "    OK   $d"
  done
  for s in "${skipped_lanes[@]}"; do
    echo "    SKIP $s (opt-out)"
  done
fi
echo ""
echo "  Next steps:"
echo "    1. Transfer the bundle to the new Mac (rsync over LAN, external SSD, or AirDrop the tarball)"
if [ "$DO_TARBALL" = "1" ]; then
  echo "       Recommended: copy '$tarball_path' (single file)"
else
  echo "       Recommended: 'rsync -av $BUNDLE/ new-mac:~/migration-bundle/'"
fi
echo "    2. On the new Mac, route to the 'restore' sub-skill (skill: mac-migration > restore)"
echo "    3. After restore completes, run 'diff' sub-skill to verify and surface any gaps"
echo ""
echo "=================================================================="

"$AUDIT" package ok "Package step complete"
