#!/usr/bin/env bash
# migrate.sh -- one-command orchestrator for the mac-migration skill.
#
# Runs the phases in dependency order so you don't invoke 9 lane scripts by hand.
# Cron-rerunnable + idempotent: re-running skips lanes that already have a .done
# marker (pass --force to redo). Honors manifest.json opt-outs (each lane does).
#
# Usage:
#   migrate.sh inventory                       Phase 1: scan -> manifest.json
#   migrate.sh capture  [--dry-run] [--tarball] [--force]
#                                              Phase 2: preflight -> scan -> all
#                                              capture lanes -> package bundle
#   migrate.sh restore  [BUNDLE_OR_TARBALL] [--force]
#                                              Phase 3: unpack -> all restore lanes
#                                              -> diff -> cleanup advisory
#   migrate.sh status                          Show .done markers (lane / status / ts)
#   migrate.sh diff                            Phase 4: compare current Mac to manifest
#
# Env:
#   BUNDLE   default ~/migration-bundle
#
# macOS only.

set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BUNDLE="${BUNDLE:-$HOME/migration-bundle}"
export BUNDLE

# Lane suffixes in dependency order (apps first, creds last).
LANES=(a_apps b_shell c_toolchains d_gui_configs e_browsers f_ides g_databases h_services i_creds)

progress() { printf '\n========== [%s] %s ==========\n' "$1" "$2"; }

# Split caller flags: lane flags (--dry-run/--force) vs package flags (--tarball).
LANE_FLAGS=()
PKG_FLAGS=()
RESTORE_INPUT=""
parse_flags() {
  for a in "$@"; do
    case "$a" in
      --dry-run) LANE_FLAGS+=("--dry-run"); PKG_FLAGS+=("--dry-run") ;;
      --force)   LANE_FLAGS+=("--force") ;;
      --tarball) PKG_FLAGS+=("--tarball") ;;
      --*)       echo "migrate.sh: unknown flag: $a" >&2; exit 2 ;;
      *)         RESTORE_INPUT="$a" ;;  # positional: a bundle path for restore
    esac
  done
}

cmd_inventory() {
  progress "inventory" "Scanning this Mac (read-only)"
  bash "$HERE/inventory/scripts/scan_inventory.sh"
  echo
  echo "Scan complete. Review $BUNDLE/manifest.json, set opt-outs, then: migrate.sh capture"
}

cmd_capture() {
  progress "preflight" "Checking readiness"
  if ! bash "$HERE/inventory/scripts/preflight_check.sh"; then
    echo
    echo "Pre-flight found blockers (above). Fix them, then re-run: migrate.sh capture"
    exit 1
  fi
  progress "inventory" "Scanning this Mac"
  bash "$HERE/inventory/scripts/scan_inventory.sh"
  local n=${#LANES[@]} i=0
  for lane in "${LANES[@]}"; do
    i=$((i + 1))
    progress "capture $i/$n" "Lane ${lane%%_*} (${lane#*_})"
    if ! bash "$HERE/capture/scripts/capture_lane_${lane}.sh" "${LANE_FLAGS[@]:-}"; then
      echo "  (lane ${lane} reported an issue -- continuing; check the audit log)"
    fi
  done
  progress "package" "Building bundle + integrity manifest"
  bash "$HERE/capture/scripts/package_bundle.sh" "${PKG_FLAGS[@]:-}"
  echo
  echo "Capture complete -> $BUNDLE"
  echo "Next: copy the bundle (and ~/migration-gpg-key-BRING-SEPARATELY.asc, SEPARATELY)"
  echo "      to the new Mac, then run: migrate.sh restore"
}

cmd_restore() {
  progress "unpack" "Verifying + unpacking bundle"
  bash "$HERE/restore/scripts/unpack_bundle.sh" "${RESTORE_INPUT:-$BUNDLE}"
  local n=${#LANES[@]} i=0
  for lane in "${LANES[@]}"; do
    i=$((i + 1))
    progress "restore $i/$n" "Lane ${lane%%_*} (${lane#*_})"
    if ! bash "$HERE/restore/scripts/restore_lane_${lane}.sh" "${LANE_FLAGS[@]:-}"; then
      echo "  (lane ${lane} reported an issue -- continuing; check the audit log)"
    fi
  done
  progress "diff" "Verifying restored state"
  bash "$HERE/diff/scripts/diff_state.sh" || true
  progress "cleanup" "Old-Mac cleanup advisory"
  bash "$HERE/restore/scripts/cleanup_old_mac_advisory.sh" || true
  echo
  echo "Restore complete. Review DIFF-REPORT.md and the manual steps surfaced above."
}

cmd_status() {
  bash "$HERE/scripts/lane_done_marker.sh" list || echo "(no markers yet)"
}

cmd_diff() {
  bash "$HERE/diff/scripts/diff_state.sh"
}

# --- Dispatch -------------------------------------------------------------
sub="${1:-}"; [ $# -gt 0 ] && shift || true
case "$sub" in
  inventory) parse_flags "$@"; cmd_inventory ;;
  capture)   parse_flags "$@"; cmd_capture ;;
  restore)   parse_flags "$@"; cmd_restore ;;
  status)    cmd_status ;;
  diff)      cmd_diff ;;
  -h|--help|"")
    sed -n '2,33p' "$0"
    [ -z "$sub" ] && exit 2
    exit 0
    ;;
  *)
    echo "migrate.sh: unknown subcommand: $sub" >&2
    echo "Try: inventory | capture | restore | status | diff" >&2
    exit 2
    ;;
esac
