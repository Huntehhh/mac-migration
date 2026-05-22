#!/usr/bin/env bash
# restore_lane_a_apps.sh -- Lane A: Homebrew + Brewfile + mas apps + orphan-app reminder.
# Idempotent, cron-rerunnable. Honors manifest.json opt-outs.

set -euo pipefail

PARENT="$(cd "$(dirname "$0")/../.." && pwd)"
BUNDLE="${BUNDLE:-$HOME/migration-bundle}"
LANE="lane-a-apps"

audit_log() {
  printf '{"ts":"%s","lane":"A","action":"%s","target":"%s","rc":%d}\n' \
    "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$1" "$2" "$3" >> "$BUNDLE/migration.log.jsonl"
}

# Done marker check
if [ -f "$BUNDLE/.done/$LANE" ] && [ "${1:-}" != "--force" ]; then
  echo "[lane-a] Already complete. Pass --force to re-run."
  exit 0
fi

# Opt-out check
if [ -f "$BUNDLE/manifest.json" ] && command -v jq > /dev/null; then
  if [ "$(jq -r '.lane_a.skip // false' "$BUNDLE/manifest.json")" = "true" ]; then
    echo "[lane-a] Skipped per manifest.json opt-out."
    echo "skipped=true" > "$BUNDLE/.done/$LANE"
    audit_log "skip" "manifest_opt_out" 0
    exit 0
  fi
fi

mkdir -p "$BUNDLE/.done"

# A0. Install Homebrew if not present
if ! command -v brew > /dev/null; then
  echo "[lane-a] Homebrew not found. Installing via official one-liner..."
  NONINTERACTIVE=1 /bin/bash -c "$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)"
  audit_log "install" "homebrew" $?

  # Shell env for current script + future shells
  if [ -d "/opt/homebrew" ]; then
    eval "$(/opt/homebrew/bin/brew shellenv)"
  elif [ -d "/usr/local/Homebrew" ]; then
    eval "$(/usr/local/bin/brew shellenv)"
  fi
fi

# Pre-require jq for manifest parsing in later lanes
brew install jq 2>/dev/null || true

# A1. Brewfile
if [ -f "$BUNDLE/Brewfile" ]; then
  echo "[lane-a] Running brew bundle ..."
  brew bundle --file="$BUNDLE/Brewfile" --no-lock || {
    echo "[lane-a] brew bundle had failures; continuing."
    audit_log "brew_bundle" "$BUNDLE/Brewfile" 1
  }
  audit_log "brew_bundle" "$BUNDLE/Brewfile" 0
else
  echo "[lane-a] No Brewfile in bundle; skipping brew bundle step."
fi

# A2. mas apps -- fallback for fresh Apple ID via mas get
if command -v mas > /dev/null && [ -f "$BUNDLE/manifests/mas-installed.txt" ]; then
  echo "[lane-a] Checking MAS apps coverage ..."
  # mas list shows what's already installed; diff against captured list
  ALREADY_INSTALLED=$(mas list 2>/dev/null | awk '{print $1}' || echo "")
  while IFS= read -r line; do
    [ -z "$line" ] && continue
    APP_ID=$(echo "$line" | awk '{print $1}')
    [ -z "$APP_ID" ] && continue
    if ! echo "$ALREADY_INSTALLED" | grep -q "^$APP_ID$"; then
      echo "[lane-a] mas get $APP_ID (fallback for fresh Apple ID)"
      mas get "$APP_ID" 2>/dev/null || echo "  FAIL: mas get $APP_ID (not in account?)"
      audit_log "mas_get" "$APP_ID" $?
    fi
  done < "$BUNDLE/manifests/mas-installed.txt"
fi

# A3. Orphan app checklist
if [ -f "$BUNDLE/manifests/system-apps.json" ] && command -v jq > /dev/null; then
  ORPHAN_FILE="$BUNDLE/MANUAL-STEPS-orphan-apps.md"
  {
    echo "# Orphan apps detected on old Mac"
    echo
    echo "These apps appeared in system_profiler on the old Mac but are NOT in your Brewfile or MAS list."
    echo "Decide for each: install manually, add to Brewfile (run \`brew search <name>\` to check), or skip."
    echo
    # Get app names from system-apps.json
    jq -r '.SPApplicationsDataType[]?._name // empty' "$BUNDLE/manifests/system-apps.json" 2>/dev/null \
      | sort -u \
      | while read app; do
        # Skip Apple-bundled apps and known brew casks
        case "$app" in
          "Safari"|"Mail"|"Calendar"|"Notes"|"Reminders"|"Maps"|"Contacts"|"FaceTime"|"Messages"|"Photos"|"Music"|"Podcasts"|"TV"|"News"|"App Store"|"System Settings"|"System Preferences"|"Stocks"|"Voice Memos"|"Books"|"Home"|"Find My"|"Shortcuts"|"Time Machine"|"Migration Assistant"|"Disk Utility"|"Terminal"|"TextEdit"|"Preview"|"QuickTime Player"|"Calculator"|"Dictionary"|"Stickies"|"Activity Monitor")
            continue ;;
        esac
        echo "- **$app**"
        echo "  - Try: \`brew search ${app// /}\` then \`brew install --cask <match>\`"
        echo "  - Or install manually from publisher"
      done
  } > "$ORPHAN_FILE"
  echo "[lane-a] Orphan-app checklist written: $ORPHAN_FILE"
fi

# Mark done
echo "$(date -u +%Y-%m-%dT%H:%M:%SZ)" > "$BUNDLE/.done/$LANE"
audit_log "complete" "$LANE" 0
echo "[lane-a] DONE."
exit 0
