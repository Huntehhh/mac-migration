#!/usr/bin/env bash
# capture_lane_d_gui_configs.sh
# Lane D -- GUI app configs
#
# Sub-modules:
#   D1  defaults plist export per domain
#   D2  ~/Library/Application Support selective rsync (caches excluded)
#   D3  Stickies (Container -- ACL gotcha flagged)
#   D4  Fonts (~/Library/Fonts)
#   D5  Mail (~/Library/Mail) -- rules + signatures + smart mailboxes
#
# Containers wholesale rsync is INTENTIONALLY NOT performed -- see per-app playbooks.
#
# Opt-out keys:
#   opt_outs.lane_d
#   opt_outs.lane_d.{defaults,app_support,stickies,fonts,mail,system_fonts}

set -euo pipefail

BUNDLE="${BUNDLE:-$HOME/migration-bundle}"
DRY_RUN="${DRY_RUN:-0}"
FORCE="${FORCE:-0}"

for arg in "$@"; do
  case "$arg" in
    --force)   FORCE=1 ;;
    --dry-run) DRY_RUN=1 ;;
    *) echo "capture_lane_d_gui_configs.sh: unknown arg: $arg" >&2; exit 2 ;;
  esac
done

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SUB_SKILL_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
SKILL_DIR="$(cd "$SUB_SKILL_DIR/.." && pwd)"
AUDIT="$SCRIPT_DIR/audit_log.sh"
DONE_HELPER="$SKILL_DIR/scripts/lane_done_marker.sh"
LANE_ID="lane-d-gui-configs"
MANIFEST="$BUNDLE/manifest.json"

if [ ! -f "$MANIFEST" ]; then
  echo "capture_lane_d_gui_configs.sh: $MANIFEST not found -- run inventory first." >&2
  exit 3
fi

mkdir -p "$BUNDLE/defaults" "$BUNDLE/AppSupport" "$BUNDLE/fonts" "$BUNDLE/stickies" "$BUNDLE/mail" "$BUNDLE/.done" "$BUNDLE/dry-run-report"

opt_out_lane() { jq -e ".opt_outs.lane_d == true" "$MANIFEST" >/dev/null 2>&1; }
opt_out_sub()  { jq -e ".opt_outs.lane_d.$1 == true" "$MANIFEST" >/dev/null 2>&1; }

if opt_out_lane; then
  "$AUDIT" "$LANE_ID" lane skip "manifest.json opts out of entire Lane D"
  [ "$DRY_RUN" != "1" ] && bash "$DONE_HELPER" write "$LANE_ID"
  exit 0
fi

if [ "$FORCE" != "1" ] && bash "$DONE_HELPER" check "$LANE_ID" >/dev/null 2>&1; then
  "$AUDIT" "$LANE_ID" lane skip "Already done -- use --force to re-capture"
  exit 0
fi

"$AUDIT" "$LANE_ID" lane start "Lane D -- GUI configs (dry_run=$DRY_RUN, force=$FORCE)"

# --- D1. defaults plists -------------------------------------------------

if ! opt_out_sub defaults; then
  # `defaults domains` returns comma-separated. Convert to newlines, trim whitespace.
  domains_raw="$(defaults domains 2>/dev/null || echo '')"
  if [ -z "$domains_raw" ]; then
    "$AUDIT" "$LANE_ID" defaults warn "defaults domains returned empty"
  else
    domain_count=0
    exported=0
    failed=0
    # tr commas to newlines, trim spaces
    while IFS= read -r domain; do
      domain="$(echo "$domain" | sed 's/^ *//; s/ *$//')"
      [ -z "$domain" ] && continue
      domain_count=$((domain_count + 1))
      if [ "$DRY_RUN" = "1" ]; then
        continue
      fi
      if defaults export "$domain" "$BUNDLE/defaults/${domain}.plist" 2>/dev/null; then
        exported=$((exported + 1))
      else
        failed=$((failed + 1))
      fi
    done < <(printf '%s\n' "$domains_raw" | tr ',' '\n')

    if [ "$DRY_RUN" = "1" ]; then
      "$AUDIT" "$LANE_ID" defaults info "Would export $domain_count defaults domains"
    else
      "$AUDIT" "$LANE_ID" defaults ok "Exported $exported / $domain_count defaults domains ($failed failed)"
      "$AUDIT" "$LANE_ID" defaults info "Restore: killall cfprefsd after import or apps overwrite plists"
    fi
  fi
else
  "$AUDIT" "$LANE_ID" defaults skip "Opted out via manifest"
fi

# --- D2. ~/Library/Application Support (selective rsync) -----------------

if ! opt_out_sub app_support; then
  if [ "$DRY_RUN" = "1" ]; then
    size_mb="$(du -sm ~/Library/Application\ Support 2>/dev/null | awk '{print $1}' || echo 0)"
    "$AUDIT" "$LANE_ID" app_support info "Would rsync AppSupport (raw ~${size_mb} MB; cache-excluded subset smaller)"
  else
    "$AUDIT" "$LANE_ID" app_support start "Rsync ~/Library/Application Support (caches excluded)"
    if rsync -a \
        --exclude='*Cache*' --exclude='*cache*' --exclude='Caches' \
        --exclude='*Logs*' --exclude='Crash Reports' \
        --exclude='CrashReporter' --exclude='DiagnosticReports' \
        ~/Library/Application\ Support/ "$BUNDLE/AppSupport/" 2>/dev/null; then
      "$AUDIT" "$LANE_ID" app_support ok "Wrote AppSupport/"
    else
      "$AUDIT" "$LANE_ID" app_support warn "rsync returned non-zero (partial copy possible)"
    fi
    "$AUDIT" "$LANE_ID" app_support info "Cloud-synced apps (1Password, Notion, Slack) -- reinstall + login is faster than restore"
  fi
else
  "$AUDIT" "$LANE_ID" app_support skip "Opted out via manifest"
fi

# --- D3. Stickies (Container -- ACL gotcha) -------------------------------

if ! opt_out_sub stickies; then
  stickies_dir="$HOME/Library/Containers/com.apple.Stickies"
  if [ -d "$stickies_dir" ]; then
    if [ "$DRY_RUN" = "1" ]; then
      "$AUDIT" "$LANE_ID" stickies info "Would rsync Stickies Container (ACL caveat applies)"
    else
      "$AUDIT" "$LANE_ID" stickies start "Rsync Stickies Container"
      if rsync -a "$stickies_dir/" "$BUNDLE/stickies/" 2>/dev/null; then
        "$AUDIT" "$LANE_ID" stickies ok "Wrote stickies/"
        "$AUDIT" "$LANE_ID" stickies warn "Container ACL is tied to app code-signature + Team ID. Restore may need manual import via Stickies app."
      else
        "$AUDIT" "$LANE_ID" stickies warn "Stickies rsync returned non-zero (may need Full Disk Access)"
      fi
    fi
  else
    "$AUDIT" "$LANE_ID" stickies skip "No Stickies Container found"
  fi
else
  "$AUDIT" "$LANE_ID" stickies skip "Opted out via manifest"
fi

# --- D4. Fonts ----------------------------------------------------------

if ! opt_out_sub fonts; then
  if [ -d "$HOME/Library/Fonts" ]; then
    if [ "$DRY_RUN" = "1" ]; then
      font_count="$(ls -1 "$HOME/Library/Fonts" 2>/dev/null | wc -l | tr -d ' ' || echo 0)"
      "$AUDIT" "$LANE_ID" fonts info "Would copy $font_count user fonts"
    else
      "$AUDIT" "$LANE_ID" fonts start "Rsync ~/Library/Fonts"
      if rsync -a "$HOME/Library/Fonts/" "$BUNDLE/fonts/" 2>/dev/null; then
        "$AUDIT" "$LANE_ID" fonts ok "Wrote fonts/"
        "$AUDIT" "$LANE_ID" fonts info "Restore: 'sudo atsutil databases -remove' then reboot for font cache reset"
      else
        "$AUDIT" "$LANE_ID" fonts warn "Font rsync returned non-zero"
      fi
    fi
  else
    "$AUDIT" "$LANE_ID" fonts skip "No ~/Library/Fonts directory"
  fi
  # System fonts (/Library/Fonts) -- opt-in by default-off
  if jq -e ".opt_outs.lane_d.system_fonts == false" "$MANIFEST" >/dev/null 2>&1; then
    if [ "$DRY_RUN" != "1" ]; then
      mkdir -p "$BUNDLE/fonts-system"
      sudo rsync -a /Library/Fonts/ "$BUNDLE/fonts-system/" 2>/dev/null \
        && "$AUDIT" "$LANE_ID" fonts ok "Wrote fonts-system/ (sudo)" \
        || "$AUDIT" "$LANE_ID" fonts warn "System font copy failed"
    fi
  fi
else
  "$AUDIT" "$LANE_ID" fonts skip "Opted out via manifest"
fi

# --- D5. Mail -----------------------------------------------------------

if ! opt_out_sub mail; then
  if [ -d "$HOME/Library/Mail" ]; then
    if [ "$DRY_RUN" = "1" ]; then
      size_mb="$(du -sm "$HOME/Library/Mail" 2>/dev/null | awk '{print $1}' || echo 0)"
      "$AUDIT" "$LANE_ID" mail info "Would rsync Mail (~${size_mb} MB)"
    else
      "$AUDIT" "$LANE_ID" mail start "Rsync ~/Library/Mail"
      if rsync -a "$HOME/Library/Mail/" "$BUNDLE/mail/" 2>/dev/null; then
        "$AUDIT" "$LANE_ID" mail ok "Wrote mail/"
        "$AUDIT" "$LANE_ID" mail info "V<n> dir version bumps with macOS -- restore may need V8->V10 migration. See per-app/mail.md"
      else
        "$AUDIT" "$LANE_ID" mail warn "Mail rsync returned non-zero (may need Full Disk Access)"
      fi
    fi
  else
    "$AUDIT" "$LANE_ID" mail skip "No ~/Library/Mail directory"
  fi
else
  "$AUDIT" "$LANE_ID" mail skip "Opted out via manifest"
fi

# --- Container wholesale-copy advisory (info, not action) -----------------

"$AUDIT" "$LANE_ID" containers info "Containers NOT bulk-copied. Per-app playbooks at ../references/per-app/ cover Photos, Music, Messages, 1Password individually."

# --- done marker --------------------------------------------------------

if [ "$DRY_RUN" = "1" ]; then
  "$AUDIT" "$LANE_ID" lane info "Dry-run complete; no .done marker written"
else
  bash "$DONE_HELPER" write "$LANE_ID"
  "$AUDIT" "$LANE_ID" lane ok "Lane D capture complete"
fi
