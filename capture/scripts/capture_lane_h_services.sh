#!/usr/bin/env bash
# capture_lane_h_services.sh
# Lane H -- Background services
#
# Sub-modules:
#   H1  User LaunchAgents (~/Library/LaunchAgents)
#   H2  System LaunchAgents + LaunchDaemons (/Library/...) via sudo
#   H3  launchctl list snapshot (current running state)
#   H4  brew services list snapshot
#   H5  PM2 dump
#   H6  user + root crontabs
#   H7  Login Items via AppleScript
#   H8  Launchpad layout via lporg (optional, archived)
#
# Opt-out keys:
#   opt_outs.lane_h
#   opt_outs.lane_h.{user_agents,system_daemons,launchctl_list,brew_services,pm2,cron,login_items,launchpad}

set -euo pipefail

BUNDLE="${BUNDLE:-$HOME/migration-bundle}"
DRY_RUN="${DRY_RUN:-0}"
FORCE="${FORCE:-0}"

for arg in "$@"; do
  case "$arg" in
    --force)   FORCE=1 ;;
    --dry-run) DRY_RUN=1 ;;
    *) echo "capture_lane_h_services.sh: unknown arg: $arg" >&2; exit 2 ;;
  esac
done

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SUB_SKILL_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
SKILL_DIR="$(cd "$SUB_SKILL_DIR/.." && pwd)"
AUDIT="$SCRIPT_DIR/audit_log.sh"
DONE_HELPER="$SKILL_DIR/scripts/lane_done_marker.sh"
LANE_ID="lane-h-services"
MANIFEST="$BUNDLE/manifest.json"

if [ ! -f "$MANIFEST" ]; then
  echo "capture_lane_h_services.sh: $MANIFEST not found -- run inventory first." >&2
  exit 3
fi

mkdir -p "$BUNDLE/launchd" "$BUNDLE/manifests" "$BUNDLE/.done" "$BUNDLE/dry-run-report"

opt_out_lane() { jq -e ".opt_outs.lane_h == true" "$MANIFEST" >/dev/null 2>&1; }
opt_out_sub()  { jq -e ".opt_outs.lane_h.$1 == true" "$MANIFEST" >/dev/null 2>&1; }

if opt_out_lane; then
  "$AUDIT" "$LANE_ID" lane skip "manifest.json opts out of entire Lane H"
  [ "$DRY_RUN" != "1" ] && bash "$DONE_HELPER" write "$LANE_ID"
  exit 0
fi

if [ "$FORCE" != "1" ] && bash "$DONE_HELPER" check "$LANE_ID" >/dev/null 2>&1; then
  "$AUDIT" "$LANE_ID" lane skip "Already done -- use --force to re-capture"
  exit 0
fi

"$AUDIT" "$LANE_ID" lane start "Lane H -- Background services (dry_run=$DRY_RUN, force=$FORCE)"

# --- H1. User LaunchAgents ----------------------------------------------

if ! opt_out_sub user_agents; then
  ua_dir="$HOME/Library/LaunchAgents"
  if [ -d "$ua_dir" ]; then
    if [ "$DRY_RUN" = "1" ]; then
      count="$(ls -1 "$ua_dir"/*.plist 2>/dev/null | wc -l | tr -d ' ' || echo 0)"
      "$AUDIT" "$LANE_ID" user_agents info "Would copy $count user LaunchAgent plists"
    else
      mkdir -p "$BUNDLE/launchd/user-LaunchAgents"
      if rsync -a "$ua_dir/" "$BUNDLE/launchd/user-LaunchAgents/" 2>/dev/null; then
        "$AUDIT" "$LANE_ID" user_agents ok "Wrote launchd/user-LaunchAgents/"
        "$AUDIT" "$LANE_ID" user_agents info "Restore: launchctl bootstrap gui/\$(id -u) <plist> after verifying ProgramArguments paths"
      else
        "$AUDIT" "$LANE_ID" user_agents warn "User LaunchAgents rsync returned non-zero"
      fi
    fi
  else
    "$AUDIT" "$LANE_ID" user_agents skip "No user LaunchAgents directory"
  fi
else
  "$AUDIT" "$LANE_ID" user_agents skip "Opted out via manifest"
fi

# --- H2. System LaunchAgents + LaunchDaemons ----------------------------

if ! opt_out_sub system_daemons; then
  if [ "$DRY_RUN" = "1" ]; then
    "$AUDIT" "$LANE_ID" system_daemons info "Would sudo-copy /Library/LaunchAgents and /Library/LaunchDaemons"
  else
    "$AUDIT" "$LANE_ID" system_daemons start "Copying system launchd dirs via sudo"
    mkdir -p "$BUNDLE/launchd/system-LaunchAgents" "$BUNDLE/launchd/system-LaunchDaemons"
    if sudo cp -R /Library/LaunchAgents/. "$BUNDLE/launchd/system-LaunchAgents/" 2>/dev/null; then
      "$AUDIT" "$LANE_ID" system_daemons ok "Wrote launchd/system-LaunchAgents/"
    else
      "$AUDIT" "$LANE_ID" system_daemons warn "System LaunchAgents copy returned non-zero"
    fi
    if sudo cp -R /Library/LaunchDaemons/. "$BUNDLE/launchd/system-LaunchDaemons/" 2>/dev/null; then
      "$AUDIT" "$LANE_ID" system_daemons ok "Wrote launchd/system-LaunchDaemons/"
      "$AUDIT" "$LANE_ID" system_daemons info "Tahoe (26) tightens SIP on LaunchDaemons. Custom root daemons may need SMAppService rewrite."
    else
      "$AUDIT" "$LANE_ID" system_daemons warn "System LaunchDaemons copy returned non-zero"
    fi
  fi
else
  "$AUDIT" "$LANE_ID" system_daemons skip "Opted out via manifest"
fi

# --- H3. launchctl list snapshot ----------------------------------------

if ! opt_out_sub launchctl_list; then
  if [ "$DRY_RUN" = "1" ]; then
    "$AUDIT" "$LANE_ID" launchctl_list info "Would snapshot launchctl list"
  else
    if launchctl list > "$BUNDLE/launchd/launchctl-list.txt" 2>/dev/null; then
      "$AUDIT" "$LANE_ID" launchctl_list ok "Wrote launchd/launchctl-list.txt"
    else
      "$AUDIT" "$LANE_ID" launchctl_list warn "launchctl list returned non-zero"
    fi
  fi
else
  "$AUDIT" "$LANE_ID" launchctl_list skip "Opted out via manifest"
fi

# --- H4. brew services state -------------------------------------------

if ! opt_out_sub brew_services; then
  if command -v brew >/dev/null 2>&1; then
    if [ "$DRY_RUN" = "1" ]; then
      "$AUDIT" "$LANE_ID" brew_services info "Would snapshot brew services list"
    else
      if brew services list > "$BUNDLE/manifests/brew-services-running.txt" 2>/dev/null; then
        "$AUDIT" "$LANE_ID" brew_services ok "Wrote manifests/brew-services-running.txt"
      else
        "$AUDIT" "$LANE_ID" brew_services warn "brew services list returned non-zero"
      fi
    fi
  fi
else
  "$AUDIT" "$LANE_ID" brew_services skip "Opted out via manifest"
fi

# --- H5. PM2 ------------------------------------------------------------

if ! opt_out_sub pm2; then
  if command -v pm2 >/dev/null 2>&1; then
    if [ "$DRY_RUN" = "1" ]; then
      "$AUDIT" "$LANE_ID" pm2 info "Would run pm2 save and capture dump.pm2"
    else
      "$AUDIT" "$LANE_ID" pm2 start "Running pm2 save"
      if pm2 save >/dev/null 2>&1; then
        if [ -f ~/.pm2/dump.pm2 ]; then
          cp -p ~/.pm2/dump.pm2 "$BUNDLE/manifests/pm2-dump.pm2"
          "$AUDIT" "$LANE_ID" pm2 ok "Wrote manifests/pm2-dump.pm2"
        else
          "$AUDIT" "$LANE_ID" pm2 warn "pm2 save succeeded but ~/.pm2/dump.pm2 not found"
        fi
      else
        "$AUDIT" "$LANE_ID" pm2 warn "pm2 save returned non-zero"
      fi
    fi
  else
    "$AUDIT" "$LANE_ID" pm2 skip "pm2 not installed"
  fi
else
  "$AUDIT" "$LANE_ID" pm2 skip "Opted out via manifest"
fi

# --- H6. crontab --------------------------------------------------------

if ! opt_out_sub cron; then
  if [ "$DRY_RUN" = "1" ]; then
    "$AUDIT" "$LANE_ID" cron info "Would capture user + root crontabs"
  else
    crontab -l > "$BUNDLE/manifests/user-crontab.txt" 2>/dev/null \
      && "$AUDIT" "$LANE_ID" cron ok "Wrote manifests/user-crontab.txt" \
      || "$AUDIT" "$LANE_ID" cron info "User crontab empty or unset"
    sudo crontab -l > "$BUNDLE/manifests/root-crontab.txt" 2>/dev/null \
      && "$AUDIT" "$LANE_ID" cron ok "Wrote manifests/root-crontab.txt" \
      || "$AUDIT" "$LANE_ID" cron info "Root crontab empty or unset"
    "$AUDIT" "$LANE_ID" cron info "/var/at/tabs is wiped on clean install -- explicit capture is mandatory"
  fi
else
  "$AUDIT" "$LANE_ID" cron skip "Opted out via manifest"
fi

# --- H7. Login Items ----------------------------------------------------

if ! opt_out_sub login_items; then
  if [ "$DRY_RUN" = "1" ]; then
    "$AUDIT" "$LANE_ID" login_items info "Would record Login Items via AppleScript"
  else
    if osascript -e 'tell application "System Events" to get the name of every login item' \
       > "$BUNDLE/manifests/login-items.txt" 2>/dev/null; then
      "$AUDIT" "$LANE_ID" login_items ok "Wrote manifests/login-items.txt"
      "$AUDIT" "$LANE_ID" login_items warn "List is INCOMPLETE -- misses SMAppService-registered apps. Modern apps re-register on first launch."
    else
      "$AUDIT" "$LANE_ID" login_items warn "AppleScript returned non-zero (Accessibility permission may be missing)"
    fi
  fi
else
  "$AUDIT" "$LANE_ID" login_items skip "Opted out via manifest"
fi

# --- H8. Launchpad layout (optional, archived tool) ---------------------

if ! opt_out_sub launchpad; then
  if command -v lporg >/dev/null 2>&1; then
    if [ "$DRY_RUN" = "1" ]; then
      "$AUDIT" "$LANE_ID" launchpad info "Would run lporg save"
    else
      if lporg save -c "$BUNDLE/manifests/launchpad-layout.yml" 2>/dev/null; then
        "$AUDIT" "$LANE_ID" launchpad ok "Wrote manifests/launchpad-layout.yml"
        "$AUDIT" "$LANE_ID" launchpad info "lporg archived 2025-09-19 but functional. Folder recreation has known reliability issues (issue #67)."
      else
        "$AUDIT" "$LANE_ID" launchpad warn "lporg save failed -- common, many users skip Launchpad migration entirely"
      fi
    fi
  else
    "$AUDIT" "$LANE_ID" launchpad skip "lporg not installed (most users skip Launchpad layout)"
  fi
else
  "$AUDIT" "$LANE_ID" launchpad skip "Opted out via manifest"
fi

# --- done marker --------------------------------------------------------

if [ "$DRY_RUN" = "1" ]; then
  "$AUDIT" "$LANE_ID" lane info "Dry-run complete; no .done marker written"
else
  bash "$DONE_HELPER" write "$LANE_ID"
  "$AUDIT" "$LANE_ID" lane ok "Lane H capture complete"
fi
