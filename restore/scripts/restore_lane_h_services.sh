#!/usr/bin/env bash
# restore_lane_h_services.sh -- Lane H: LaunchAgents + brew services + PM2 + cron + Login Items + Launchpad.
# Surfaces Tahoe SIP advisory on macOS 26+.

set -euo pipefail

PARENT="$(cd "$(dirname "$0")/../.." && pwd)"
BUNDLE="${BUNDLE:-$HOME/migration-bundle}"
LANE="lane-h-services"

audit_log() {
  printf '{"ts":"%s","lane":"H","action":"%s","target":"%s","rc":%d}\n' \
    "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$1" "$2" "$3" >> "$BUNDLE/migration.log.jsonl"
}

if [ -f "$BUNDLE/.done/$LANE" ] && [ "${1:-}" != "--force" ]; then
  echo "[lane-h] Already complete. Pass --force to re-run."
  exit 0
fi

if [ -f "$BUNDLE/manifest.json" ] && command -v jq > /dev/null; then
  if [ "$(jq -r '.lane_h.skip // false' "$BUNDLE/manifest.json")" = "true" ]; then
    echo "[lane-h] Skipped per manifest.json opt-out."
    echo "skipped=true" > "$BUNDLE/.done/$LANE"
    audit_log "skip" "manifest_opt_out" 0
    exit 0
  fi
fi

mkdir -p "$BUNDLE/.done"

# Tahoe SIP advisory -- surface FIRST
TARGET_OS_MAJOR=15
if [ -x "$PARENT/scripts/detect_macos_version.sh" ]; then
  TARGET_OS_MAJOR=$("$PARENT/scripts/detect_macos_version.sh" 2>/dev/null | awk '{print $1}' | head -1)
fi
TARGET_OS_MAJOR=${TARGET_OS_MAJOR:-15}

if [ "$TARGET_OS_MAJOR" -ge 26 ] 2>/dev/null; then
  echo
  echo "================================================================"
  echo "WARNING: macOS Tahoe (26) tightens SIP on /Library/LaunchDaemons."
  echo "================================================================"
  echo
  echo "Custom root-level daemons may need rewriting as SMAppService-based"
  echo "app-bundle helpers. Sandboxed apps can no longer install"
  echo "non-sandboxed daemons (since macOS 14.2)."
  echo
  echo "This restore will install user-level LaunchAgents under"
  echo "~/Library/LaunchAgents/ normally. System-level daemons require"
  echo "explicit --include-system-daemons flag and may not register on Tahoe."
  echo
  echo "See $PARENT/references/tahoe-sip-advisory.md"
  echo "================================================================"
  echo
fi

# H1. User LaunchAgents
if [ -d "$BUNDLE/launchd/user-LaunchAgents" ]; then
  echo "[lane-h] Restoring user LaunchAgents..."
  mkdir -p "$HOME/Library/LaunchAgents"
  rsync -av "$BUNDLE/launchd/user-LaunchAgents/" "$HOME/Library/LaunchAgents/"

  echo "[lane-h] Bootstrapping LaunchAgents..."
  for plist in "$HOME/Library/LaunchAgents/"*.plist; do
    [ -f "$plist" ] || continue
    pname=$(basename "$plist" .plist)
    # Try modern bootstrap; ignore failures (already loaded, etc.)
    launchctl bootstrap "gui/$(id -u)" "$plist" 2>/dev/null || true
    audit_log "launchctl_bootstrap" "$pname" 0
  done
fi

# H2. System LaunchDaemons -- opt-in only
INCLUDE_SYS_DAEMONS="${INCLUDE_SYSTEM_DAEMONS:-0}"
for arg in "$@"; do
  [ "$arg" = "--include-system-daemons" ] && INCLUDE_SYS_DAEMONS=1
done

if [ "$INCLUDE_SYS_DAEMONS" = "1" ] && [ -d "$BUNDLE/launchd/system-LaunchDaemons" ]; then
  echo "[lane-h] Restoring SYSTEM LaunchDaemons (sudo + opt-in)..."
  sudo rsync -av "$BUNDLE/launchd/system-LaunchDaemons/" "/Library/LaunchDaemons/"
  for plist in "$BUNDLE/launchd/system-LaunchDaemons/"*.plist; do
    [ -f "$plist" ] || continue
    sudo launchctl bootstrap system "$plist" 2>/dev/null \
      || echo "[lane-h]   FAIL: $(basename "$plist") (likely Tahoe SIP)"
    audit_log "launchctl_bootstrap_system" "$(basename "$plist")" $?
  done
fi

# H3. brew services running state
if [ -f "$BUNDLE/manifests/brew-services-running.txt" ] && command -v brew > /dev/null; then
  echo "[lane-h] Starting brew services that were running on old Mac..."
  awk '$2=="started" {print $1}' "$BUNDLE/manifests/brew-services-running.txt" \
    | while read svc; do
      [ -z "$svc" ] && continue
      brew services start "$svc" 2>/dev/null || echo "[lane-h]   FAIL: brew services start $svc"
      audit_log "brew_service_start" "$svc" $?
    done
fi

# H4. PM2
if [ -f "$BUNDLE/manifests/pm2-dump.pm2" ] && command -v pm2 > /dev/null; then
  echo "[lane-h] Restoring PM2 services..."
  mkdir -p "$HOME/.pm2"
  cp "$BUNDLE/manifests/pm2-dump.pm2" "$HOME/.pm2/dump.pm2"
  pm2 resurrect 2>/dev/null || echo "[lane-h]   pm2 resurrect had errors."
  echo "[lane-h]   ADVISORY: run \`pm2 startup\` and apply the resulting sudo command for boot persistence."
  audit_log "pm2_resurrect" "$HOME/.pm2/dump.pm2" 0
fi

# H5. cron
if [ -f "$BUNDLE/manifests/user-crontab.txt" ]; then
  echo "[lane-h] Restoring crontab..."
  crontab "$BUNDLE/manifests/user-crontab.txt" 2>/dev/null \
    || echo "[lane-h]   FAIL: crontab install"
  audit_log "crontab" "$BUNDLE/manifests/user-crontab.txt" $?
fi

# H6. Login Items -- no programmatic API for legacy items
if [ -f "$BUNDLE/manifests/login-items.txt" ]; then
  LOGIN_FILE="$BUNDLE/MANUAL-STEPS-login-items.md"
  {
    echo "# Legacy Login Items -- manual re-add"
    echo
    echo "macOS has no programmatic API for legacy Login Items. Modern apps using SMAppService"
    echo "re-register themselves on first launch. Anything older needs manual re-add."
    echo
    echo "Open System Settings > General > Login Items, then add each:"
    echo
    awk '{print "- [ ] " $0}' "$BUNDLE/manifests/login-items.txt"
  } > "$LOGIN_FILE"
  echo "[lane-h] Login Items checklist written: $LOGIN_FILE"
fi

# H7. Launchpad -- optional
LAUNCHPAD_OPT="false"
if [ -f "$BUNDLE/manifest.json" ] && command -v jq > /dev/null; then
  LAUNCHPAD_OPT=$(jq -r '.lane_h.launchpad_restore // false' "$BUNDLE/manifest.json")
fi
if [ "$LAUNCHPAD_OPT" = "true" ] && [ -f "$BUNDLE/manifests/launchpad-layout.yml" ]; then
  if command -v lporg > /dev/null; then
    echo "[lane-h] Restoring Launchpad layout via lporg..."
    lporg load -c "$BUNDLE/manifests/launchpad-layout.yml" 2>/dev/null \
      || echo "[lane-h]   FAIL: lporg load (known issues with folder recreation)."
    audit_log "lporg_load" "$BUNDLE/manifests/launchpad-layout.yml" $?
  else
    echo "[lane-h] Launchpad layout in bundle but lporg not installed. Install with: brew install blacktop/tap/lporg (archived but functional)."
  fi
fi

echo "$(date -u +%Y-%m-%dT%H:%M:%SZ)" > "$BUNDLE/.done/$LANE"
audit_log "complete" "$LANE" 0
echo "[lane-h] DONE."
exit 0
