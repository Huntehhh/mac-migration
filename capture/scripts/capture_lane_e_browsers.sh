#!/usr/bin/env bash
# capture_lane_e_browsers.sh
# Lane E -- Browsers
#
# Sub-modules:
#   E1  Chrome - extension list only (account sync handles rest)
#   E2  Brave/Edge - extension lists only
#   E3  Firefox - full Profiles/ copy (warn if Firefox running)
#   E4  Safari - Bookmarks.plist (FDA required to read)
#   E5  Arc - state file listing (account sync handles rest)
#
# Opt-out keys:
#   opt_outs.lane_e
#   opt_outs.lane_e.{chrome,brave,edge,firefox,safari,arc}

set -euo pipefail

BUNDLE="${BUNDLE:-$HOME/migration-bundle}"
DRY_RUN="${DRY_RUN:-0}"
FORCE="${FORCE:-0}"

for arg in "$@"; do
  case "$arg" in
    --force)   FORCE=1 ;;
    --dry-run) DRY_RUN=1 ;;
    *) echo "capture_lane_e_browsers.sh: unknown arg: $arg" >&2; exit 2 ;;
  esac
done

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SUB_SKILL_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
SKILL_DIR="$(cd "$SUB_SKILL_DIR/.." && pwd)"
AUDIT="$SCRIPT_DIR/audit_log.sh"
DONE_HELPER="$SKILL_DIR/scripts/lane_done_marker.sh"
LANE_ID="lane-e-browsers"
MANIFEST="$BUNDLE/manifest.json"

if [ ! -f "$MANIFEST" ]; then
  echo "capture_lane_e_browsers.sh: $MANIFEST not found -- run inventory first." >&2
  exit 3
fi

mkdir -p "$BUNDLE/browsers" "$BUNDLE/.done" "$BUNDLE/dry-run-report"

opt_out_lane() { jq -e ".opt_outs.lane_e == true" "$MANIFEST" >/dev/null 2>&1; }
opt_out_sub()  { jq -e ".opt_outs.lane_e.$1 == true" "$MANIFEST" >/dev/null 2>&1; }

if opt_out_lane; then
  "$AUDIT" "$LANE_ID" lane skip "manifest.json opts out of entire Lane E"
  [ "$DRY_RUN" != "1" ] && bash "$DONE_HELPER" set "$LANE_ID"
  exit 0
fi

if [ "$FORCE" != "1" ] && bash "$DONE_HELPER" check "$LANE_ID" >/dev/null 2>&1; then
  "$AUDIT" "$LANE_ID" lane skip "Already done -- use --force to re-capture"
  exit 0
fi

"$AUDIT" "$LANE_ID" lane start "Lane E -- Browsers (dry_run=$DRY_RUN, force=$FORCE)"

# --- E1. Chrome ---------------------------------------------------------

if ! opt_out_sub chrome; then
  chrome_ext="$HOME/Library/Application Support/Google/Chrome/Default/Extensions"
  if [ -d "$chrome_ext" ]; then
    if [ "$DRY_RUN" = "1" ]; then
      ext_count="$(ls -1 "$chrome_ext" 2>/dev/null | wc -l | tr -d ' ' || echo 0)"
      "$AUDIT" "$LANE_ID" chrome info "Would record $ext_count Chrome extensions"
    else
      ls -1 "$chrome_ext" > "$BUNDLE/browsers/chrome-extensions.txt" 2>/dev/null
      "$AUDIT" "$LANE_ID" chrome ok "Wrote browsers/chrome-extensions.txt (account sync handles bookmarks + passwords)"
    fi
  else
    "$AUDIT" "$LANE_ID" chrome skip "No Chrome profile found"
  fi
else
  "$AUDIT" "$LANE_ID" chrome skip "Opted out via manifest"
fi

# --- E2. Brave ----------------------------------------------------------

if ! opt_out_sub brave; then
  brave_ext="$HOME/Library/Application Support/BraveSoftware/Brave-Browser/Default/Extensions"
  if [ -d "$brave_ext" ]; then
    if [ "$DRY_RUN" = "1" ]; then
      ext_count="$(ls -1 "$brave_ext" 2>/dev/null | wc -l | tr -d ' ' || echo 0)"
      "$AUDIT" "$LANE_ID" brave info "Would record $ext_count Brave extensions"
    else
      ls -1 "$brave_ext" > "$BUNDLE/browsers/brave-extensions.txt" 2>/dev/null
      "$AUDIT" "$LANE_ID" brave ok "Wrote browsers/brave-extensions.txt (Brave Sync recommended for full migration)"
    fi
  else
    "$AUDIT" "$LANE_ID" brave skip "No Brave profile found"
  fi
else
  "$AUDIT" "$LANE_ID" brave skip "Opted out via manifest"
fi

# --- E2b. Edge ----------------------------------------------------------

if ! opt_out_sub edge; then
  edge_ext="$HOME/Library/Application Support/Microsoft Edge/Default/Extensions"
  if [ -d "$edge_ext" ]; then
    if [ "$DRY_RUN" = "1" ]; then
      ext_count="$(ls -1 "$edge_ext" 2>/dev/null | wc -l | tr -d ' ' || echo 0)"
      "$AUDIT" "$LANE_ID" edge info "Would record $ext_count Edge extensions"
    else
      ls -1 "$edge_ext" > "$BUNDLE/browsers/edge-extensions.txt" 2>/dev/null
      "$AUDIT" "$LANE_ID" edge ok "Wrote browsers/edge-extensions.txt (Microsoft account sync recommended)"
    fi
  else
    "$AUDIT" "$LANE_ID" edge skip "No Edge profile found"
  fi
else
  "$AUDIT" "$LANE_ID" edge skip "Opted out via manifest"
fi

# --- E3. Firefox --------------------------------------------------------

if ! opt_out_sub firefox; then
  ff_profiles="$HOME/Library/Application Support/Firefox/Profiles"
  if [ -d "$ff_profiles" ]; then
    if pgrep -x firefox >/dev/null 2>&1; then
      "$AUDIT" "$LANE_ID" firefox warn "Firefox is RUNNING -- profile copy may be inconsistent. Quit Firefox and re-run with --force."
    fi
    if [ "$DRY_RUN" = "1" ]; then
      size_mb="$(du -sm "$ff_profiles" 2>/dev/null | awk '{print $1}' || echo 0)"
      "$AUDIT" "$LANE_ID" firefox info "Would copy Firefox Profiles (~${size_mb} MB)"
    else
      "$AUDIT" "$LANE_ID" firefox start "Rsync Firefox Profiles"
      mkdir -p "$BUNDLE/browsers/firefox-profiles"
      if rsync -a "$ff_profiles/" "$BUNDLE/browsers/firefox-profiles/" 2>/dev/null; then
        "$AUDIT" "$LANE_ID" firefox ok "Wrote browsers/firefox-profiles/"
      else
        "$AUDIT" "$LANE_ID" firefox warn "Firefox profile rsync returned non-zero"
      fi
    fi
  else
    "$AUDIT" "$LANE_ID" firefox skip "No Firefox profiles found"
  fi
else
  "$AUDIT" "$LANE_ID" firefox skip "Opted out via manifest"
fi

# --- E4. Safari ---------------------------------------------------------

if ! opt_out_sub safari; then
  bookmarks="$HOME/Library/Safari/Bookmarks.plist"
  if [ -f "$bookmarks" ]; then
    if [ "$DRY_RUN" = "1" ]; then
      "$AUDIT" "$LANE_ID" safari info "Would copy Safari Bookmarks.plist (FDA required)"
    else
      "$AUDIT" "$LANE_ID" safari start "Copying Safari Bookmarks.plist"
      if cp -p "$bookmarks" "$BUNDLE/browsers/safari-bookmarks.plist" 2>/dev/null; then
        "$AUDIT" "$LANE_ID" safari ok "Wrote browsers/safari-bookmarks.plist"
        "$AUDIT" "$LANE_ID" safari info "Restore: land BEFORE first Safari launch"
      else
        "$AUDIT" "$LANE_ID" safari warn "Safari bookmarks copy failed -- needs Full Disk Access on the running shell"
      fi
    fi
  else
    "$AUDIT" "$LANE_ID" safari skip "No Safari bookmarks file (FDA may also be missing)"
  fi
else
  "$AUDIT" "$LANE_ID" safari skip "Opted out via manifest"
fi

# --- E5. Arc ------------------------------------------------------------

if ! opt_out_sub arc; then
  arc_dir="$HOME/Library/Application Support/Arc"
  if [ -d "$arc_dir" ]; then
    if [ "$DRY_RUN" = "1" ]; then
      "$AUDIT" "$LANE_ID" arc info "Would record Arc state files"
    else
      ls -1 "$arc_dir" > "$BUNDLE/browsers/arc-state.txt" 2>/dev/null
      "$AUDIT" "$LANE_ID" arc ok "Wrote browsers/arc-state.txt (Arc account sync handles full migration)"
    fi
  else
    "$AUDIT" "$LANE_ID" arc skip "No Arc profile found"
  fi
else
  "$AUDIT" "$LANE_ID" arc skip "Opted out via manifest"
fi

# --- done marker --------------------------------------------------------

if [ "$DRY_RUN" = "1" ]; then
  "$AUDIT" "$LANE_ID" lane info "Dry-run complete; no .done marker written"
else
  bash "$DONE_HELPER" set "$LANE_ID"
  "$AUDIT" "$LANE_ID" lane ok "Lane E capture complete"
fi
