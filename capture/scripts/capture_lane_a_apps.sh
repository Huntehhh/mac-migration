#!/usr/bin/env bash
# capture_lane_a_apps.sh
# Lane A -- Applications: Brewfile, mas, orphan apps
#
# Sub-modules:
#   A1  Brewfile (formulae + casks + taps + mas entries via brew bundle dump)
#   A2  brew services running snapshot
#   A3  Mac App Store apps via mas list
#   A4  Orphan apps inventory via system_profiler
#
# Honors manifest.json opt-outs:
#   opt_outs.lane_a (whole-lane skip)
#   opt_outs.lane_a.{brewfile,brew_services,mas,orphan_apps}
#
# Flags:
#   --force        ignore .done/lane-a-apps and re-capture
#   --dry-run      probe + count, write dry-run-report, no bytes copied
#
# Environment:
#   BUNDLE         override bundle dir (default ~/migration-bundle)
#   DRY_RUN=1      same as --dry-run

set -euo pipefail

BUNDLE="${BUNDLE:-$HOME/migration-bundle}"
DRY_RUN="${DRY_RUN:-0}"
FORCE="${FORCE:-0}"

for arg in "$@"; do
  case "$arg" in
    --force)   FORCE=1 ;;
    --dry-run) DRY_RUN=1 ;;
    *) echo "capture_lane_a_apps.sh: unknown arg: $arg" >&2; exit 2 ;;
  esac
done

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SUB_SKILL_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
SKILL_DIR="$(cd "$SUB_SKILL_DIR/.." && pwd)"
AUDIT="$SCRIPT_DIR/audit_log.sh"
DONE_HELPER="$SKILL_DIR/scripts/lane_done_marker.sh"
LANE_ID="lane-a-apps"
MANIFEST="$BUNDLE/manifest.json"

# --- guard rails ---------------------------------------------------------

if [ ! -f "$MANIFEST" ]; then
  echo "capture_lane_a_apps.sh: $MANIFEST not found -- run inventory first." >&2
  exit 3
fi

mkdir -p "$BUNDLE/manifests" "$BUNDLE/.done" "$BUNDLE/dry-run-report"

# --- opt-out check -------------------------------------------------------

opt_out_lane() {
  # returns 0 if opted out, 1 otherwise
  jq -e ".opt_outs.lane_a == true" "$MANIFEST" >/dev/null 2>&1
}

opt_out_sub() {
  local sub="$1"
  jq -e ".opt_outs.lane_a.${sub} == true" "$MANIFEST" >/dev/null 2>&1
}

if opt_out_lane; then
  "$AUDIT" "$LANE_ID" lane skip "manifest.json opts out of entire Lane A"
  # honor opt-out by writing done marker so subsequent runs skip cleanly
  if [ "$DRY_RUN" != "1" ]; then
    bash "$DONE_HELPER" set "$LANE_ID"
  fi
  exit 0
fi

# --- idempotency: skip if already done unless --force --------------------

if [ "$FORCE" != "1" ] && bash "$DONE_HELPER" check "$LANE_ID" >/dev/null 2>&1; then
  "$AUDIT" "$LANE_ID" lane skip "Already done -- use --force to re-capture"
  exit 0
fi

"$AUDIT" "$LANE_ID" lane start "Lane A -- Applications (dry_run=$DRY_RUN, force=$FORCE)"

# --- A1. Brewfile --------------------------------------------------------

if ! opt_out_sub brewfile && command -v brew >/dev/null 2>&1; then
  if [ "$DRY_RUN" = "1" ]; then
    formula_count="$(brew list --formula 2>/dev/null | wc -l | tr -d ' ' || echo 0)"
    cask_count="$(brew list --cask 2>/dev/null | wc -l | tr -d ' ' || echo 0)"
    tap_count="$(brew tap 2>/dev/null | wc -l | tr -d ' ' || echo 0)"
    "$AUDIT" "$LANE_ID" brewfile info "Would dump $formula_count formulae, $cask_count casks, $tap_count taps"
    jq -n \
      --arg lane "a" \
      --arg sub "brewfile" \
      --argjson formulae "$formula_count" \
      --argjson casks "$cask_count" \
      --argjson taps "$tap_count" \
      '{lane:$lane, sub:$sub, formulae:$formulae, casks:$casks, taps:$taps}' \
      > "$BUNDLE/dry-run-report/lane-a-brewfile.json"
  else
    "$AUDIT" "$LANE_ID" brewfile start "Running brew bundle dump"
    if brew bundle dump --force --describe --file="$BUNDLE/Brewfile" 2>>"$BUNDLE/migration.log.jsonl"; then
      "$AUDIT" "$LANE_ID" brewfile ok "Wrote $BUNDLE/Brewfile"
    else
      "$AUDIT" "$LANE_ID" brewfile fail "brew bundle dump failed"
      exit 10
    fi
  fi
else
  if opt_out_sub brewfile; then
    "$AUDIT" "$LANE_ID" brewfile skip "Opted out via manifest"
  else
    "$AUDIT" "$LANE_ID" brewfile skip "brew not installed"
  fi
fi

# --- A2. brew services running snapshot ----------------------------------

if ! opt_out_sub brew_services && command -v brew >/dev/null 2>&1; then
  if [ "$DRY_RUN" = "1" ]; then
    svc_count="$(brew services list 2>/dev/null | tail -n +2 | wc -l | tr -d ' ' || echo 0)"
    "$AUDIT" "$LANE_ID" brew_services info "Would snapshot $svc_count services"
  else
    "$AUDIT" "$LANE_ID" brew_services start "Snapshotting brew services state"
    if brew services list > "$BUNDLE/manifests/brew-services-running.txt" 2>/dev/null; then
      "$AUDIT" "$LANE_ID" brew_services ok "Wrote manifests/brew-services-running.txt"
    else
      "$AUDIT" "$LANE_ID" brew_services warn "brew services list returned non-zero (may be no services running)"
    fi
  fi
else
  if opt_out_sub brew_services; then
    "$AUDIT" "$LANE_ID" brew_services skip "Opted out via manifest"
  else
    "$AUDIT" "$LANE_ID" brew_services skip "brew not installed"
  fi
fi

# --- A3. Mac App Store apps ---------------------------------------------

if ! opt_out_sub mas && command -v mas >/dev/null 2>&1; then
  if [ "$DRY_RUN" = "1" ]; then
    mas_count="$(mas list 2>/dev/null | wc -l | tr -d ' ' || echo 0)"
    "$AUDIT" "$LANE_ID" mas info "Would record $mas_count MAS apps"
  else
    "$AUDIT" "$LANE_ID" mas start "Listing Mac App Store apps"
    if mas list > "$BUNDLE/manifests/mas-installed.txt" 2>/dev/null; then
      "$AUDIT" "$LANE_ID" mas ok "Wrote manifests/mas-installed.txt"
    else
      "$AUDIT" "$LANE_ID" mas warn "mas list returned non-zero (may not be signed in)"
    fi
  fi
else
  if opt_out_sub mas; then
    "$AUDIT" "$LANE_ID" mas skip "Opted out via manifest"
  else
    "$AUDIT" "$LANE_ID" mas skip "mas-cli not installed"
  fi
fi

# --- A4. Orphan apps inventory ------------------------------------------

if ! opt_out_sub orphan_apps; then
  if [ "$DRY_RUN" = "1" ]; then
    "$AUDIT" "$LANE_ID" orphan_apps info "Would run system_profiler SPApplicationsDataType (slow ~10-30s)"
  else
    "$AUDIT" "$LANE_ID" orphan_apps start "Running system_profiler SPApplicationsDataType (slow)"
    if system_profiler SPApplicationsDataType -json > "$BUNDLE/manifests/system-apps.json" 2>/dev/null; then
      app_count="$(jq '.SPApplicationsDataType | length' "$BUNDLE/manifests/system-apps.json" 2>/dev/null || echo 0)"
      "$AUDIT" "$LANE_ID" orphan_apps ok "Captured $app_count system apps"
    else
      "$AUDIT" "$LANE_ID" orphan_apps fail "system_profiler failed"
      exit 11
    fi
  fi
else
  "$AUDIT" "$LANE_ID" orphan_apps skip "Opted out via manifest"
fi

# --- done marker ---------------------------------------------------------

if [ "$DRY_RUN" = "1" ]; then
  "$AUDIT" "$LANE_ID" lane info "Dry-run complete; no .done marker written"
else
  bash "$DONE_HELPER" set "$LANE_ID"
  "$AUDIT" "$LANE_ID" lane ok "Lane A capture complete"
fi
