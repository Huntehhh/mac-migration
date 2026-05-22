#!/usr/bin/env bash
# cleanup_old_mac_advisory.sh -- Final lane. Emits checklists for:
# - ~/MIGRATION-CLEANUP-OLD-MAC.md (what's safe to wipe on the old Mac)
# - ~/MIGRATION-MANUAL-STEPS.md (Lane J manual deferred items)
# Cron-rerunnable. Doesn't write a .done marker -- runs every time as a final summary.

set -euo pipefail

PARENT="$(cd "$(dirname "$0")/../.." && pwd)"
BUNDLE="${BUNDLE:-$HOME/migration-bundle}"

audit_log() {
  printf '{"ts":"%s","lane":"cleanup","action":"%s","target":"%s","rc":%d}\n' \
    "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$1" "$2" "$3" >> "$BUNDLE/migration.log.jsonl"
}

CLEANUP_FILE="$HOME/MIGRATION-CLEANUP-OLD-MAC.md"
MANUAL_FILE="$HOME/MIGRATION-MANUAL-STEPS.md"

# Detect what licenses + iCloud-tied services may need deactivating
{
  echo "# Cleanup Old Mac -- Safe-to-Wipe Checklist"
  echo
  echo "Generated: $(date -u +%Y-%m-%dT%H:%M:%SZ)"
  echo "Bundle:    $BUNDLE"
  echo
  echo "## BEFORE wiping the old Mac"
  echo
  echo "### App licenses -- deactivate on old Mac first"
  echo
  echo "These apps have offline machine licenses. Deactivate on the OLD Mac to free the seat."
  echo

  # Scan Brewfile for known license-bound apps
  if [ -f "$BUNDLE/Brewfile" ]; then
    grep -iE "(adobe|backblaze|jetbrains|setapp|plex|microsoft-office|microsoft-365|parallels|vmware|1password|tableau|sketch|figma-desktop|cleanmymac|carbon-copy-cloner|chronosync|toolbox|paw|proxyman|charles|reflector|loopback|audio-hijack)" "$BUNDLE/Brewfile" \
      | sed -E 's/^/- [ ] /' \
      || echo "- (no license-bound apps detected in Brewfile)"
  fi
  echo
  echo "Other apps to check (only you know if you have offline seats):"
  echo "- [ ] Backblaze (sign out + remove computer from account)"
  echo "- [ ] Adobe Creative Cloud (Help > Sign Out, then File > Manage Account)"
  echo "- [ ] JetBrains Toolbox + IDEs (Help > Register > Deactivate)"
  echo "- [ ] Setapp (sign out)"
  echo "- [ ] Plex Media Server (account.plex.tv > Manage Devices > Remove)"
  echo "- [ ] Sketch / Figma desktop (sign out if license-bound)"
  echo
  echo "### iCloud-tied services -- sign out"
  echo
  echo "- [ ] System Settings > Apple ID > Sign Out (this signs out iCloud, iMessage, FaceTime, App Store)"
  echo "- [ ] Find My -- verify the Mac is unlocked in iCloud (account.apple.com > Find Devices > Remove)"
  echo "- [ ] iMessage / FaceTime -- sign out separately if not already cleared"
  echo "- [ ] Activation Lock -- disable before wipe (System Settings > General > About > Activation Lock toggle)"
  echo
  echo "### Cloud sync -- verify it actually synced"
  echo
  echo "- [ ] iCloud Drive -- confirm Documents + Desktop synced; check status in Files app"
  echo "- [ ] Dropbox / Google Drive / OneDrive -- wait for green checkmark on all files"
  echo "- [ ] 1Password -- confirm Watchtower shows recent sync"
  echo
  echo "### Subscriptions tied to machine"
  echo
  echo "- [ ] Apple Music / Apple TV+ / Apple Arcade -- fine to leave; transfers via Apple ID"
  echo "- [ ] Hardware-bound: Logic Pro, Final Cut Pro (App Store-bound to Apple ID, no manual action)"
  echo
  echo "## DURING wipe"
  echo
  echo "### Secure-erase guidance"
  echo
  echo "macOS 13+ (Apple Silicon and T2 Macs):"
  echo
  echo "- The Mac has hardware-encrypted storage; \"Erase All Content and Settings\" is cryptographically secure."
  echo "- System Settings > General > Transfer or Reset > Erase All Content and Settings"
  echo "- DO NOT use \`diskutil secureErase\` -- modern SSDs require hardware erase to be truly secure"
  echo
  echo "Older Intel Macs without T2:"
  echo
  echo "- Boot Recovery Mode (Cmd+R) > Disk Utility > Erase > Security Options > 7-pass (slow but thorough)"
  echo "- Or hardware-encrypt first via FileVault, then quick erase (the key destruction makes data unrecoverable)"
  echo
  echo "## AFTER wipe (if selling or gifting)"
  echo
  echo "- [ ] Reinstall macOS via Recovery (Cmd+Shift+Opt+R for the version that shipped with the Mac)"
  echo "- [ ] DO NOT sign in to Apple ID -- leave it for the buyer"
  echo "- [ ] Test that Setup Assistant runs cleanly to the welcome screen"
  echo
  echo "---"
  echo "_Source bundle: $BUNDLE_"
} > "$CLEANUP_FILE"

# Manual steps for the new Mac
{
  echo "# Manual Steps -- New Mac (Lane J)"
  echo
  echo "Generated: $(date -u +%Y-%m-%dT%H:%M:%SZ)"
  echo
  echo "These items cannot migrate programmatically. Walk through each at your pace."
  echo
  echo "## iCloud Keychain + WiFi"
  echo
  echo "- [ ] System Settings > Apple ID > iCloud > Keychain -- enable"
  echo "- [ ] Verify WiFi auto-joins after Keychain sync (~1-2 min)"
  echo
  echo "## TCC Permissions (Privacy & Security)"
  echo
  echo "TCC database is per-machine. Apps re-prompt on first launch -- but some need explicit grants."
  echo "Open System Settings > Privacy & Security and re-grant each app that needs access."
  echo
  echo "Quick deep-links (paste into Terminal):"
  echo
  echo '```bash'
  echo "$PARENT/scripts/tcc_deep_link.sh full-disk-access"
  echo "$PARENT/scripts/tcc_deep_link.sh accessibility"
  echo "$PARENT/scripts/tcc_deep_link.sh screen-recording"
  echo "$PARENT/scripts/tcc_deep_link.sh input-monitoring"
  echo "$PARENT/scripts/tcc_deep_link.sh camera"
  echo "$PARENT/scripts/tcc_deep_link.sh microphone"
  echo "$PARENT/scripts/tcc_deep_link.sh automation"
  echo '```'
  echo
  echo "Common apps needing FDA:"
  echo "- Terminal / iTerm2 / Warp / Ghostty (for scripts touching protected dirs)"
  echo "- Backup tools (Time Machine alternates, Backblaze, Arq, Carbon Copy Cloner)"
  echo "- AltTab, Rectangle, Hammerspoon (Accessibility)"
  echo "- Loom, OBS, CleanShot X (Screen Recording)"
  echo "- Karabiner-Elements (Input Monitoring)"
  echo
  echo "## App Licenses (sign-in only)"
  echo
  echo "- [ ] 1Password -- sign in (don't restore container, it re-builds)"
  echo "- [ ] Slack -- sign in to workspaces"
  echo "- [ ] Notion -- sign in"
  echo "- [ ] Linear -- sign in"
  echo "- [ ] Discord -- sign in"
  echo "- [ ] Zoom -- sign in"
  echo "- [ ] VS Code Settings Sync (if used) -- GitHub sign-in"
  echo "- [ ] Cursor -- sign in"
  echo
  echo "## Time Machine + Spotlight"
  echo
  echo "- [ ] Time Machine -- re-add destination(s) in System Settings > General > Time Machine"
  echo "- [ ] Time Machine exclusions -- re-add via the +/- buttons; old Mac \`tmutil listexclusions\` output is in \`$BUNDLE/manifests/tm-exclusions.txt\` if captured"
  echo "- [ ] Spotlight Privacy -- System Settings > Siri & Spotlight > Spotlight Privacy -- add dirs to exclude"
  echo
  echo "## Rosetta state check"
  echo
  echo "Run this in Terminal:"
  echo
  echo '```bash'
  echo 'arch'
  echo '```'
  echo
  echo "- If output is \`arm64\` (Apple Silicon) or \`i386\` is NOT shown: you're native, no action."
  echo "- If output is \`i386\`: your shell is running emulated. Relaunch Terminal natively."
  echo
  echo "## iCloud Photos / Music / Messages"
  echo
  echo "These re-sync from iCloud. Just sign in and wait."
  echo
  echo "- [ ] Photos -- open Photos.app, sign in to iCloud Photos, wait for sync (can take hours for large libraries)"
  echo "- [ ] Music -- open Music.app, enable Sync Library in Preferences"
  echo "- [ ] Messages -- open Messages.app, enable Messages in iCloud (Preferences > iMessage > Settings)"
  echo
  echo "---"
  echo "_Source bundle: $BUNDLE_"
} > "$MANUAL_FILE"

echo "[cleanup] Cleanup checklist written: $CLEANUP_FILE"
echo "[cleanup] Manual-steps checklist written: $MANUAL_FILE"
audit_log "write_checklists" "MIGRATION-CLEANUP + MIGRATION-MANUAL-STEPS" 0

# Final summary
echo
echo "============================================================"
echo "RESTORE COMPLETE."
echo "============================================================"
echo "Bundle:       $BUNDLE"
echo "Audit log:    $BUNDLE/migration.log.jsonl"
echo "Lanes done:   $(ls "$BUNDLE/.done/" 2>/dev/null | wc -l | tr -d ' ')"
echo
echo "Next:         Route to mac-migration diff to verify the new Mac matches the old."
echo "              mac-migration diff --baseline $BUNDLE/manifest.json"
echo
echo "Manual steps: $MANUAL_FILE"
echo "Old-Mac cleanup: $CLEANUP_FILE"
echo "============================================================"

exit 0
