#!/usr/bin/env bash
# restore_lane_d_gui_configs.sh -- Lane D: defaults plists + AppSupport + fonts + Stickies/Notes/Mail.
# Surfaces TCC deep links after completion.

set -euo pipefail

PARENT="$(cd "$(dirname "$0")/../.." && pwd)"
BUNDLE="${BUNDLE:-$HOME/migration-bundle}"
LANE="lane-d-gui-configs"

audit_log() {
  printf '{"ts":"%s","lane":"D","action":"%s","target":"%s","rc":%d}\n' \
    "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$1" "$2" "$3" >> "$BUNDLE/migration.log.jsonl"
}

if [ -f "$BUNDLE/.done/$LANE" ] && [ "${1:-}" != "--force" ]; then
  echo "[lane-d] Already complete. Pass --force to re-run."
  exit 0
fi

if [ -f "$BUNDLE/manifest.json" ] && command -v jq > /dev/null; then
  if [ "$(jq -r '.lane_d.skip // false' "$BUNDLE/manifest.json")" = "true" ]; then
    echo "[lane-d] Skipped per manifest.json opt-out."
    echo "skipped=true" > "$BUNDLE/.done/$LANE"
    audit_log "skip" "manifest_opt_out" 0
    exit 0
  fi
fi

mkdir -p "$BUNDLE/.done"

# D1. defaults plists -- batch import then flush cfprefsd
if [ -d "$BUNDLE/defaults" ]; then
  echo "[lane-d] Importing defaults plists..."
  COUNT=0
  FAIL=0
  for plist in "$BUNDLE/defaults/"*.plist; do
    [ -f "$plist" ] || continue
    domain=$(basename "$plist" .plist)
    if defaults import "$domain" "$plist" 2>/dev/null; then
      COUNT=$((COUNT + 1))
    else
      FAIL=$((FAIL + 1))
      audit_log "defaults_import_fail" "$domain" 1
    fi
  done
  echo "[lane-d]   Imported: $COUNT  Failed: $FAIL"
  echo "[lane-d] Flushing cfprefsd cache..."
  killall cfprefsd 2>/dev/null || true
  audit_log "defaults_batch" "domains=$COUNT" 0
fi

# D2. ~/Library/Application Support (selective)
if [ -d "$BUNDLE/AppSupport" ]; then
  echo "[lane-d] Rsyncing AppSupport/ ..."
  mkdir -p "$HOME/Library/Application Support"
  rsync -av "$BUNDLE/AppSupport/" "$HOME/Library/Application Support/" 2>/dev/null \
    || echo "[lane-d]   AppSupport rsync had warnings (some apps may be running)"
  audit_log "rsync_appsupport" "$HOME/Library/Application Support" 0
fi

# D3. Containers -- DEFAULT OFF (ACL issues)
CONTAINERS_OPT_IN="false"
if [ -f "$BUNDLE/manifest.json" ] && command -v jq > /dev/null; then
  CONTAINERS_OPT_IN=$(jq -r '.lane_d.containers_restore // false' "$BUNDLE/manifest.json")
fi
if [ "$CONTAINERS_OPT_IN" = "true" ] && [ -d "$BUNDLE/Containers" ]; then
  echo "[lane-d] Containers opt-in -- rsyncing..."
  echo "[lane-d]   ADVISORY: expect ACL warnings; apps may re-prompt on first launch."
  rsync -av "$BUNDLE/Containers/" "$HOME/Library/Containers/" 2>/dev/null || true
  audit_log "rsync_containers" "$HOME/Library/Containers" 0
fi

# D4. Fonts
if [ -d "$BUNDLE/fonts" ]; then
  echo "[lane-d] Restoring user fonts..."
  mkdir -p "$HOME/Library/Fonts"
  rsync -av "$BUNDLE/fonts/" "$HOME/Library/Fonts/"
  sudo atsutil databases -remove 2>/dev/null || true
  echo "[lane-d]   ADVISORY: reboot recommended for full font database rebuild."
  audit_log "rsync_fonts" "$HOME/Library/Fonts" 0
fi

# D5. Stickies + Notes (local) + Mail
if [ -d "$BUNDLE/stickies" ]; then
  STK_DIR="$HOME/Library/Containers/com.apple.Stickies/Data/Library/Stickies"
  mkdir -p "$STK_DIR"
  rsync -av "$BUNDLE/stickies/" "$STK_DIR/" 2>/dev/null || true
  audit_log "rsync_stickies" "$STK_DIR" 0
fi

NOTES_LOCAL="false"
if [ -f "$BUNDLE/manifest.json" ] && command -v jq > /dev/null; then
  NOTES_LOCAL=$(jq -r '.lane_d.notes_local // false' "$BUNDLE/manifest.json")
fi
if [ "$NOTES_LOCAL" = "true" ] && [ -d "$BUNDLE/notes-group-container" ]; then
  echo "[lane-d] Restoring local Notes..."
  mkdir -p "$HOME/Library/Group Containers/group.com.apple.notes"
  rsync -av "$BUNDLE/notes-group-container/" "$HOME/Library/Group Containers/group.com.apple.notes/"
  audit_log "rsync_notes" "$HOME/Library/Group Containers/group.com.apple.notes" 0
fi

# Mail -- V-dir version handling
if [ -d "$BUNDLE/mail" ]; then
  OLD_VDIR=$(ls -d "$BUNDLE/mail/V"* 2>/dev/null | head -1)
  NEW_VDIR=$(ls -d "$HOME/Library/Mail/V"* 2>/dev/null | head -1)
  if [ -z "$NEW_VDIR" ]; then
    echo "[lane-d] Mail.app not yet initialized on new Mac."
    echo "[lane-d]   ACTION: launch Mail.app once, then re-run Lane D with --force."
    audit_log "mail_not_initialized" "$HOME/Library/Mail" 1
  elif [ -n "$OLD_VDIR" ]; then
    OLD_V=$(basename "$OLD_VDIR")
    NEW_V=$(basename "$NEW_VDIR")
    if [ "$OLD_V" != "$NEW_V" ]; then
      echo "[lane-d] WARNING: Mail V-dir version mismatch (old: $OLD_V, new: $NEW_V)."
      echo "[lane-d]   Rules + signatures + smart mailboxes may not load. Rsync proceeding anyway."
    fi
    [ -d "$OLD_VDIR/MailData" ] && rsync -av "$OLD_VDIR/MailData/" "$NEW_VDIR/MailData/" 2>/dev/null || true
    [ -d "$OLD_VDIR/Signatures" ] && rsync -av "$OLD_VDIR/Signatures/" "$NEW_VDIR/Signatures/" 2>/dev/null || true
    audit_log "rsync_mail" "$NEW_VDIR" 0
  fi
fi

# Post-Lane-D TCC advisory
echo
echo "[lane-d] TCC re-grant deep links -- apps that had Full Disk Access on the old Mac"
echo "[lane-d]   may need re-granting via System Settings > Privacy & Security."
echo "[lane-d]   Run: $PARENT/scripts/tcc_deep_link.sh full-disk-access"
echo

echo "$(date -u +%Y-%m-%dT%H:%M:%SZ)" > "$BUNDLE/.done/$LANE"
audit_log "complete" "$LANE" 0
echo "[lane-d] DONE."
exit 0
