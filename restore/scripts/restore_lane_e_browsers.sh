#!/usr/bin/env bash
# restore_lane_e_browsers.sh -- Lane E: Chrome/Brave/Edge sign-in reminders + Firefox/Safari/Arc copy.

set -euo pipefail

PARENT="$(cd "$(dirname "$0")/../.." && pwd)"
BUNDLE="${BUNDLE:-$HOME/migration-bundle}"
LANE="lane-e-browsers"

audit_log() {
  printf '{"ts":"%s","lane":"E","action":"%s","target":"%s","rc":%d}\n' \
    "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$1" "$2" "$3" >> "$BUNDLE/migration.log.jsonl"
}

if [ -f "$BUNDLE/.done/$LANE" ] && [ "${1:-}" != "--force" ]; then
  echo "[lane-e] Already complete. Pass --force to re-run."
  exit 0
fi

if [ -f "$BUNDLE/manifest.json" ] && command -v jq > /dev/null; then
  if [ "$(jq -r '.lane_e.skip // false' "$BUNDLE/manifest.json")" = "true" ]; then
    echo "[lane-e] Skipped per manifest.json opt-out."
    echo "skipped=true" > "$BUNDLE/.done/$LANE"
    audit_log "skip" "manifest_opt_out" 0
    exit 0
  fi
fi

mkdir -p "$BUNDLE/.done"

CHECKLIST="$BUNDLE/MANUAL-STEPS-browsers.md"
{
  echo "# Browser restore checklist"
  echo
  echo "Most browsers rely on account sync (Chrome, Brave, Safari, Edge). Sign in and wait."
  echo
} > "$CHECKLIST"

# E1. Chrome
if [ -f "$BUNDLE/browsers/chrome-extensions.txt" ]; then
  echo "[lane-e] Chrome -- sign-in only (sync handles bookmarks/extensions/passwords)."
  {
    echo "## Chrome"
    echo
    echo "1. Open Chrome and sign in to your Google account."
    echo "2. Sync handles bookmarks, extensions, saved passwords, history."
    echo "3. Extensions not auto-synced (sideloaded, dev-mode) -- install manually:"
    echo
    awk '{print "   - https://chrome.google.com/webstore/detail/" $1}' "$BUNDLE/browsers/chrome-extensions.txt" 2>/dev/null \
      || echo "   - (extension ID list missing or empty)"
  } >> "$CHECKLIST"
fi

# E2. Brave
[ -d "$BUNDLE/browsers/brave-extensions.txt" ] && \
  echo "[lane-e] Brave -- enable Brave Sync via Settings > Sync."
{
  echo
  echo "## Brave"
  echo
  echo "Open Brave. Settings > Sync > Start a new sync chain (or join the existing chain from your old Mac)."
} >> "$CHECKLIST"

# E3. Firefox -- REQUIRES QUIT
if [ -d "$BUNDLE/browsers/firefox-profiles" ]; then
  if pgrep -x "firefox" > /dev/null; then
    echo "[lane-e] WARNING: Firefox running. Skipping profile restore -- quit Firefox and re-run."
    audit_log "firefox_running_skip" "firefox-profiles" 1
  else
    echo "[lane-e] Restoring Firefox profiles..."
    mkdir -p "$HOME/Library/Application Support/Firefox/Profiles"
    rsync -av "$BUNDLE/browsers/firefox-profiles/" "$HOME/Library/Application Support/Firefox/Profiles/"
    [ -f "$BUNDLE/browsers/firefox-profiles.ini" ] && \
      cp "$BUNDLE/browsers/firefox-profiles.ini" "$HOME/Library/Application Support/Firefox/profiles.ini"
    audit_log "rsync_firefox" "$HOME/Library/Application Support/Firefox" 0
  fi
fi

# E4. Safari -- BEFORE FIRST LAUNCH
if [ -f "$BUNDLE/browsers/safari-bookmarks.plist" ]; then
  echo "[lane-e] Restoring Safari bookmarks (BEFORE first Safari launch)..."
  mkdir -p "$HOME/Library/Safari"
  if [ -f "$HOME/Library/Safari/Bookmarks.plist" ]; then
    echo "[lane-e]   Existing Bookmarks.plist found. Backing up first."
    cp "$HOME/Library/Safari/Bookmarks.plist" "$HOME/Library/Safari/Bookmarks.plist.pre-restore-$(date +%Y%m%d-%H%M%S)"
  fi
  cp "$BUNDLE/browsers/safari-bookmarks.plist" "$HOME/Library/Safari/Bookmarks.plist"
  audit_log "cp_safari_bookmarks" "$HOME/Library/Safari/Bookmarks.plist" 0
  {
    echo
    echo "## Safari"
    echo
    echo "- Bookmarks restored. If Safari was already launched before this step,"
    echo "  the restored Bookmarks.plist may be overwritten on next quit."
    echo "- Cleanest path: sign in to iCloud and let iCloud Sync handle bookmarks instead."
  } >> "$CHECKLIST"
fi

# E5. Arc
{
  echo
  echo "## Arc"
  echo
  echo "Open Arc. Use built-in 'Import from Another Browser' menu (Arc's profile format is not stable for raw copy)."
} >> "$CHECKLIST"

# E6. Edge
{
  echo
  echo "## Edge"
  echo
  echo "Open Edge, sign in to Microsoft account, sync handles bookmarks/extensions/passwords."
} >> "$CHECKLIST"

echo "[lane-e] Browser checklist written: $CHECKLIST"

echo "$(date -u +%Y-%m-%dT%H:%M:%SZ)" > "$BUNDLE/.done/$LANE"
audit_log "complete" "$LANE" 0
echo "[lane-e] DONE."
exit 0
