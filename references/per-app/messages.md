# Per-App Playbook — Messages.app

**Lane:** D3 (sandboxed app data)
**Risk level:** Medium (`chat.db` schema is unstable across macOS versions)
**Recovery difficulty:** Hard if chat.db is the only copy

---

## Overview

Messages.app stores conversations in `~/Library/Messages/chat.db` — a SQLite database that Apple modifies silently across macOS releases. Copying `chat.db` from an older macOS to a newer one MIGHT work, or might fail in subtle ways (missing reactions, dropped attachments, broken thread continuity).

The supported migration path is **iCloud Messages**:
- iCloud syncs the entire message history across Macs and iOS devices.
- Sign in on the new Mac, enable Messages in iCloud, history syncs down.
- For active iMessage users, this is the path of least resistance.

For users with **local-only conversations** (iCloud Messages disabled), there's a middle ground:
- `~/Library/Messages/Archive/` — RTF transcripts saved by the "Save history when conversations are closed" setting. Safe to copy.
- `~/Library/Messages/Attachments/` — file attachments referenced by chat.db. Also rsync-safe.
- `chat.db` itself — copy only if source and destination macOS are the same major version.

---

## Detect installed state

```bash
# Does Messages have a database at all? (Some users disable Messages entirely.)
[ -f ~/Library/Messages/chat.db ] && echo "Messages DB present"

# Database size (rough proxy for message volume).
du -h ~/Library/Messages/chat.db 2>/dev/null

# Is iCloud Messages on? (No clean CLI check; surface via defaults read.)
defaults read com.apple.imagent 2>/dev/null | grep -i 'cloud\|iCloud'

# Is "Save history when conversations are closed" on?
defaults read com.apple.MobileSMS SaveConversationsOnClose 2>/dev/null
# 1 = yes, 0 = no

# How many archived transcripts?
ls ~/Library/Messages/Archive/ 2>/dev/null | wc -l

# Attachment volume.
du -sh ~/Library/Messages/Attachments/ 2>/dev/null
```

---

## Capture — iCloud Messages flow

```bash
mkdir -p ~/migration-bundle/messages/
cat > ~/migration-bundle/messages/MIGRATION-METHOD.txt <<'EOF'
Messages.app: iCloud Messages sync mode.

On the new Mac:
  1. Sign in to iCloud with the same Apple ID.
  2. Messages.app -> Settings -> iMessage -> Enable "Messages in iCloud"
  3. Click "Sync Now". Initial download of a few years of history can take
     30 minutes to several hours depending on attachment volume.

History at ~/Library/Messages/chat.db will rebuild from cloud state. No file
copy required unless the user has local-only conversations (separate flow).

Also (post-restore):
  - Re-enable SMS forwarding on the iPhone: Settings -> Messages -> Text
    Message Forwarding -> toggle ON for the new Mac.
EOF
```

## Capture — local-only flow

```bash
# Quit Messages first. chat.db has WAL files that corrupt on live copy.
osascript -e 'quit app "Messages"' 2>/dev/null
sleep 5

# Copy the archive (RTF transcripts — version-safe across macOS).
rsync -av ~/Library/Messages/Archive/ \
    ~/migration-bundle/messages/Archive/ 2>/dev/null

# Copy attachments.
rsync -av ~/Library/Messages/Attachments/ \
    ~/migration-bundle/messages/Attachments/ 2>/dev/null

# Capture chat.db only if user opts in AND source/dest macOS match.
# Surface as a flag in manifest.json.
if [ "$CAPTURE_MESSAGES_DB" = "true" ]; then
    rsync -av ~/Library/Messages/chat.db ~/migration-bundle/messages/chat.db
    rsync -av ~/Library/Messages/chat.db-wal ~/migration-bundle/messages/chat.db-wal 2>/dev/null
    rsync -av ~/Library/Messages/chat.db-shm ~/migration-bundle/messages/chat.db-shm 2>/dev/null
fi
```

---

## Restore — iCloud Messages flow

```bash
# 1. Sign in to iCloud.
#    System Settings -> [Apple ID] -> Sign In

# 2. Launch Messages.
open /Applications/Messages.app

# 3. In Messages: Settings -> iMessage -> "Enable Messages in iCloud" -> ON

# 4. Click "Sync Now". Wait for download.

# 5. Re-enable SMS forwarding on the iPhone (Apple Watch + other Macs sync
#    automatically once signed in).
#    iPhone Settings -> Messages -> Text Message Forwarding -> toggle ON for new Mac.

# 6. Verify iMessage activation:
#    Messages -> Settings -> iMessage -> "You can be reached for messages at"
#    should list the user's phone number + Apple ID email + any other addresses.
```

## Restore — local-only flow

```bash
# 1. Quit Messages.
osascript -e 'quit app "Messages"' 2>/dev/null
sleep 3

# 2. Restore archive + attachments.
mkdir -p ~/Library/Messages/
rsync -av ~/migration-bundle/messages/Archive/ \
    ~/Library/Messages/Archive/
rsync -av ~/migration-bundle/messages/Attachments/ \
    ~/Library/Messages/Attachments/

# 3. Restore chat.db only if source/dest macOS major match.
#    (And only if the bundle has it.)
if [ -f ~/migration-bundle/messages/chat.db ]; then
    rsync -av ~/migration-bundle/messages/chat.db ~/Library/Messages/chat.db
    rm -f ~/Library/Messages/chat.db-wal ~/Library/Messages/chat.db-shm  # let Messages rebuild
fi

# 4. Re-enable history saving.
defaults write com.apple.MobileSMS SaveConversationsOnClose 1

# 5. Launch Messages and verify.
open /Applications/Messages.app
```

---

## Gotchas

- **DO NOT copy `chat.db` across macOS major versions.** Apple changes the schema silently. A `chat.db` from Sonoma opened on Tahoe may either work transparently, or show empty conversations, or crash Messages on launch. The supported migration is iCloud Messages.

- **`chat.db` is encrypted on disk but readable with Full Disk Access.** The migration skill needs FDA on whichever process copies the file. Verify FDA on `/bin/bash` (or whatever shell the script runs under) BEFORE running capture, or the rsync silently produces an empty file.

- **iCloud Messages requires APFS.** All modern Macs (Sierra+ on Apple Silicon) use APFS; this is rarely a constraint. But on an HFS+ volume (legacy Time Machine drives, some external disks), iCloud Messages refuses to enable.

- **The Archive folder is reliable.** RTF transcripts are plain files with a stable format. Copy them anywhere; they open in TextEdit. This is the FAILSAFE if all else fails — at minimum, the user has human-readable conversation history.

- **Attachments without chat.db are orphans.** `~/Library/Messages/Attachments/` is organized by message GUID (e.g., `~/Library/Messages/Attachments/00/00/2B342D8A-.../IMG_1234.HEIC`). Without `chat.db` linking attachments to conversations, the attachments are just a folder of files with cryptic paths. Useful as data, useless as conversation context.

- **SMS forwarding is a per-device setting on the iPhone.** Not migrated automatically. After signing in to the new Mac, the user MUST go to iPhone Settings -> Messages -> Text Message Forwarding and toggle the new Mac on. Without this, SMS (green-bubble) messages from non-iMessage contacts don't appear on the new Mac.

- **Group chat membership.** Group iMessage chats are server-state on Apple's side, so they sync via iCloud. Group SMS chats (with non-iMessage members) only sync if SMS forwarding is enabled.

- **"Messages in iCloud" is different from "iCloud Backup".** The user must enable "Messages in iCloud" specifically — it's not part of the default iCloud sign-in flow. iCloud Backup is for iPhone, not for Mac Messages history.

- **Hide Alerts / Pinned conversations / Custom notification per chat.** These settings live in `chat.db`. They sync via iCloud Messages but are NOT in any export-friendly file. If the user disables iCloud Messages and migrates manually, these settings are lost.

---

## Recovery

```bash
# Symptom: Messages opens but shows no conversations.
# Cause:   chat.db schema mismatch (you copied across macOS versions) or
#          chat.db permissions wrong.

# Check permissions.
ls -la ~/Library/Messages/chat.db
# Should be: -rw-r--r--  hunter  staff  ...

# If wrong:
chown "$(whoami)":staff ~/Library/Messages/chat.db*
chmod 644 ~/Library/Messages/chat.db*

# If still empty: nuke the local DB and let iCloud Messages re-sync.
osascript -e 'quit app "Messages"'
sleep 3
rm ~/Library/Messages/chat.db ~/Library/Messages/chat.db-wal ~/Library/Messages/chat.db-shm 2>/dev/null
open /Applications/Messages.app
# Messages.app -> Settings -> iMessage -> Enable Messages in iCloud -> Sync Now
```

If iCloud Messages is the only history source and it's not syncing:

```bash
# Force a re-sync (will redownload everything).
# Messages -> Settings -> iMessage -> "Disable This Account"
# Then re-enable. Confirm and click "Sync Now".
```

---

## Verify

```bash
# Database has reasonable row count:
sqlite3 ~/Library/Messages/chat.db "SELECT COUNT(*) FROM message;"

# Conversations visible:
sqlite3 ~/Library/Messages/chat.db "SELECT COUNT(DISTINCT chat_id) FROM chat;"

# Attachments resolved:
sqlite3 ~/Library/Messages/chat.db \
    "SELECT COUNT(*) FROM attachment WHERE filename IS NOT NULL;"
ls ~/Library/Messages/Attachments/ | head

# Open Messages, scroll through recent conversations, send a test iMessage,
# verify it goes through (blue bubble) and shows up on iPhone.
```

---

## Sources

- [Apple Support — Use Messages in iCloud](https://support.apple.com/guide/messages/use-messages-in-icloud-icld5fb3eb09/mac)
- [Apple Support — Set up Text Message Forwarding](https://support.apple.com/HT208386)
- [Howard Oakley — How Messages stores its history](https://eclecticlight.co/2024/04/15/explainer-messages-and-its-database/)
- Empirical: `chat.db` schema differs measurably between Sonoma 14.6 and Sequoia 15.0; assume it differs again on Tahoe 26.x
