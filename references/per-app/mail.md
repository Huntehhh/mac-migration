# Per-App Playbook — Mail.app

**Lane:** D3 (sandboxed app data) + D5 (rules + signatures + smart mailboxes)
**Risk level:** Medium (V-number path mismatch is the common gotcha)
**Recovery difficulty:** Low for IMAP (re-syncs); Medium for local-only POP3 / on-my-Mac

---

## Overview

Mail.app stores its state at `~/Library/Mail/V<n>/`, where `<n>` is a major-version number that Apple bumps with each macOS release.

Historical version table:
- macOS 11 Big Sur → `V8`
- macOS 12 Monterey → `V9`
- macOS 13 Ventura → `V10`
- macOS 14 Sonoma → `V10` (no bump — kept the Ventura format)
- macOS 15 Sequoia → `V11`
- macOS 26 Tahoe → `V12` (assumed based on Apple's pattern; verify on actual install)

The version bump is when Apple changes the on-disk format. Mail does NOT auto-migrate old `V<n>/` directories — it ignores them and starts fresh in the new `V<n+1>/`. If you put captured `V10/` files into a Tahoe Mac that expects `V12/`, Mail won't find them.

The fix: detect the target Mac's Mail version directory, and DROP the captured files into THAT directory, not the original one.

---

## What's actually inside `V<n>/`

```
~/Library/Mail/V11/
    [UUID]/                              <- per-account folder (one per email account)
        INBOX.mbox/
        Sent.mbox/
        ...
    MailData/
        Signatures/                       <- portable, version-agnostic
            AllSignatures.plist
            <UUID>.mailsignature          <- one per signature
        SyncedRules.plist                 <- mail rules (auto-synced via iCloud if enabled)
        SmartMailboxes.plist              <- smart mailbox definitions
        Stationery/                       <- custom email templates
        Endurance/                        <- internal state (do NOT copy)
        BackupTOC.plist                   <- internal index (do NOT copy)
        Envelope Index*                   <- internal SQLite (do NOT copy; rebuilds)
    Mailboxes/                            <- "On My Mac" local mailboxes (NOT IMAP)
```

**The capture-worthy items:**
- `MailData/Signatures/` — email signatures (HTML + plain text)
- `MailData/SyncedRules.plist` — server-side mail rules (also synced via iCloud Mail)
- `MailData/SmartMailboxes.plist` — smart mailbox criteria
- `MailData/Stationery/` — custom stationery (rare; skip unless detected)
- `Mailboxes/` — "On My Mac" local mailboxes (NOT IMAP, NOT server-synced)

**The skip-it items:**
- `[UUID]/INBOX.mbox/`, `Sent.mbox/`, etc. — IMAP messages re-sync from the server. Don't bother carrying them.
- `MailData/Envelope Index*` — internal SQLite that Mail rebuilds from `.emlx` files.
- `MailData/Endurance/`, `BackupTOC.plist` — internal state that breaks if copied.

---

## Detect installed state

```bash
# What's the current Mail V-directory?
ls -d ~/Library/Mail/V* 2>/dev/null
# Output: /Users/hunter/Library/Mail/V11

# Stash this for the restore step.
CURRENT_V=$(ls -d ~/Library/Mail/V*/ 2>/dev/null | sed -E 's|.*Mail/||;s|/$||' | tail -1)
echo "Current Mail version dir: $CURRENT_V"

# How many accounts?
ls ~/Library/Mail/V*/ 2>/dev/null | grep -E '^[0-9A-F]{8}-' | wc -l

# Is there local mailbox data ("On My Mac")?
[ -d ~/Library/Mail/V*/Mailboxes/ ] && du -sh ~/Library/Mail/V*/Mailboxes/

# Mail rules present?
ls -la ~/Library/Mail/V*/MailData/SyncedRules.plist 2>/dev/null

# Signatures count?
ls ~/Library/Mail/V*/MailData/Signatures/*.mailsignature 2>/dev/null | wc -l

# iCloud Mail enabled? (Surface via prefs read.)
defaults read MobileMeAccounts 2>/dev/null | grep -i mail
```

---

## Capture

```bash
# Quit Mail before copying.
osascript -e 'quit app "Mail"' 2>/dev/null
sleep 5

# Resolve current V-directory.
CURRENT_V=$(ls -d ~/Library/Mail/V*/ 2>/dev/null | sed -E 's|.*Mail/||;s|/$||' | tail -1)
[ -z "$CURRENT_V" ] && { echo "No Mail data found, skipping"; exit 0; }

mkdir -p ~/migration-bundle/mail/

# Record the source V-number so restore can map it.
echo "$CURRENT_V" > ~/migration-bundle/mail/source-version.txt

# Capture signatures.
mkdir -p ~/migration-bundle/mail/MailData/Signatures/
cp -R ~/Library/Mail/${CURRENT_V}/MailData/Signatures/ \
    ~/migration-bundle/mail/MailData/Signatures/ 2>/dev/null

# Capture rules.
cp ~/Library/Mail/${CURRENT_V}/MailData/SyncedRules.plist \
   ~/migration-bundle/mail/MailData/SyncedRules.plist 2>/dev/null

# Capture smart mailboxes.
cp ~/Library/Mail/${CURRENT_V}/MailData/SmartMailboxes.plist \
   ~/migration-bundle/mail/MailData/SmartMailboxes.plist 2>/dev/null

# Capture stationery (if present).
[ -d ~/Library/Mail/${CURRENT_V}/MailData/Stationery ] \
    && cp -R ~/Library/Mail/${CURRENT_V}/MailData/Stationery/ \
            ~/migration-bundle/mail/MailData/Stationery/ 2>/dev/null

# Capture "On My Mac" local mailboxes (POP3 archives, manually-filed mail).
[ -d ~/Library/Mail/${CURRENT_V}/Mailboxes ] \
    && rsync -av ~/Library/Mail/${CURRENT_V}/Mailboxes/ \
                 ~/migration-bundle/mail/Mailboxes/

# Capture IMAP messages? Skip by default; surface as opt-in flag.
# (Most users want IMAP re-sync, which is faster and gets pristine state.)
if [ "$CAPTURE_MAIL_IMAP" = "true" ]; then
    rsync -av --exclude='Info.plist' --exclude='*.partial.emlx' \
        ~/Library/Mail/${CURRENT_V}/ \
        ~/migration-bundle/mail/full-V-dir/
fi
```

---

## Restore

```bash
# 1. Quit Mail if running.
osascript -e 'quit app "Mail"' 2>/dev/null
sleep 3

# 2. Detect the NEW Mac's Mail V-directory.
#    Launch Mail once first to create it.
open /Applications/Mail.app
sleep 5
osascript -e 'quit app "Mail"' 2>/dev/null
sleep 3

# Now the new V-directory exists.
TARGET_V=$(ls -d ~/Library/Mail/V*/ 2>/dev/null | sed -E 's|.*Mail/||;s|/$||' | tail -1)
[ -z "$TARGET_V" ] && { echo "ERROR: New Mac has no Mail V-dir yet. Launch Mail and complete account setup, then re-run."; exit 1; }

SOURCE_V=$(cat ~/migration-bundle/mail/source-version.txt)
echo "Mapping: $SOURCE_V (old) -> $TARGET_V (new)"

# 3. Restore signatures.
mkdir -p ~/Library/Mail/${TARGET_V}/MailData/Signatures/
cp -R ~/migration-bundle/mail/MailData/Signatures/ \
      ~/Library/Mail/${TARGET_V}/MailData/Signatures/

# 4. Restore rules.
[ -f ~/migration-bundle/mail/MailData/SyncedRules.plist ] \
    && cp ~/migration-bundle/mail/MailData/SyncedRules.plist \
          ~/Library/Mail/${TARGET_V}/MailData/SyncedRules.plist

# 5. Restore smart mailboxes.
[ -f ~/migration-bundle/mail/MailData/SmartMailboxes.plist ] \
    && cp ~/migration-bundle/mail/MailData/SmartMailboxes.plist \
          ~/Library/Mail/${TARGET_V}/MailData/SmartMailboxes.plist

# 6. Restore stationery (if captured).
[ -d ~/migration-bundle/mail/MailData/Stationery ] \
    && cp -R ~/migration-bundle/mail/MailData/Stationery/ \
            ~/Library/Mail/${TARGET_V}/MailData/Stationery/

# 7. Restore "On My Mac" local mailboxes.
[ -d ~/migration-bundle/mail/Mailboxes ] \
    && rsync -av ~/migration-bundle/mail/Mailboxes/ \
                 ~/Library/Mail/${TARGET_V}/Mailboxes/

# 8. Re-add email accounts (via System Settings, since they live in
#    Internet Accounts, not in V-dir).
#    System Settings -> Internet Accounts -> Add Account...

# 9. Launch Mail. It rebuilds Envelope Index from .emlx files on first launch
#    (5-30 minutes depending on volume).
open /Applications/Mail.app
```

---

## Gotchas

- **The V-directory mismatch is the #1 trap.** Capturing on Sonoma (V10) and restoring to Tahoe (assumed V12) means the captured files go into the WRONG directory if you blindly preserve the path. The restore script MUST resolve the new V-number and re-target. Always.

- **Email accounts are NOT in `~/Library/Mail/`.** They live in `~/Library/Accounts/Accounts4.sqlite` (and the system Internet Accounts panel). Migrating accounts means re-adding them via System Settings -> Internet Accounts on the new Mac. Apple ID + iCloud accounts auto-attach when the user signs in.

- **IMAP messages re-sync from the server.** Don't bother carrying the `.mbox/` directories for IMAP accounts — Mail re-fetches them from the IMAP server when the account is re-added. POP3 accounts are different — those messages are deleted from the server after download, so they ONLY exist locally. Capture `Mailboxes/` for POP3 users.

- **Envelope Index rebuild.** On first launch after restore, Mail rebuilds its search index from the `.emlx` files. This is slow (5-30 minutes for a moderate mailbox; longer for power users). The user sees a spinning beachball-adjacent indicator in the lower-left. Don't restart Mail during this — let it finish.

- **Rules with absolute paths break.** Mail rules can reference paths (e.g., "Move to mailbox /Users/oldname/..."). Rules that reference user paths need manual edit after restore. Surface a warning if any rule's action references `/Users/<username>/` and the username differs from the new Mac's whoami.

- **Signatures path inside signature files.** Each `.mailsignature` is HTML, and may embed image references to `cid:` URIs that resolve via internal Mail logic. As long as the signature is restored as a unit (HTML file + bundled images), it works. Don't try to extract / repack signatures — copy the whole `Signatures/` directory.

- **iCloud Mail rules sync.** If the user is on iCloud Mail, server-side rules (the ones that run before mail hits the Mac) live on iCloud's servers and sync automatically. Local Mail rules (the ones in `SyncedRules.plist`) are separate and need explicit migration.

- **Mail extensions / plug-ins.** Third-party extensions (SaneBox, MailButler, MailMate compatibility shims) are installed separately. Re-install via their respective installers; settings usually re-sync via account login.

- **Smart Mailbox rebuild.** Smart Mailboxes are saved as criteria, not as cached results. They recompute their contents from the (newly-restored or re-synced) mail data. As long as the `SmartMailboxes.plist` is restored, they work — but the contents only populate after the IMAP sync + Envelope Index rebuild is complete.

---

## Recovery

```bash
# Symptom: Mail launches but shows empty mailboxes for IMAP accounts.
# Cause:   IMAP sync hasn't completed yet, OR account auth is broken.

# Wait. Mail's first sync can take 30+ minutes on large mailboxes.

# If after an hour it's still empty:
# Mail -> Window -> Connection Doctor (Cmd+Opt+0)
# Shows each account's IMAP/SMTP status. Re-auth any that show errors.

# Symptom: signatures not appearing in compose window.
# Cause:   files copied to wrong V-dir.
# Fix:     verify TARGET_V is current.
ls ~/Library/Mail/V*/MailData/Signatures/
# If the .mailsignature files are in an older V-dir, move them:
TARGET_V=$(ls -d ~/Library/Mail/V*/ | tail -1 | sed -E 's|.*Mail/||;s|/$||')
# (then re-run step 3 of restore)

# Symptom: search returns nothing.
# Cause:   Envelope Index needs rebuild.
# Fix:     Mail -> Mailbox -> Rebuild  (per mailbox; slow)
#     OR:  delete the Envelope Index files and let Mail rebuild on next launch:
osascript -e 'quit app "Mail"'
sleep 3
rm ~/Library/Mail/V*/MailData/Envelope\ Index* 2>/dev/null
open /Applications/Mail.app
# Mail rebuilds. Takes a while.
```

---

## Verify

```bash
# Mailbox count looks reasonable:
ls ~/Library/Mail/V*/MailData/Signatures/*.mailsignature | wc -l   # signature count

# IMAP accounts re-synced:
# Mail -> Window -> Connection Doctor  (all green)

# Rules active:
# Mail -> Settings -> Rules  (rules list is populated)

# Smart Mailboxes populated:
# Mail -> Mailbox -> sidebar shows smart mailboxes with counts

# Local "On My Mac" mailboxes intact (POP3 users):
# Mail -> sidebar -> "On My Mac" section shows expected folders + messages

# Send a test email to yourself; confirm signature applied + sent + received.
```

---

## Sources

- [Apple Support — Move from Mail in a previous version of macOS](https://support.apple.com/guide/mail/move-from-mail-in-an-older-version-mlhlp1003/mac)
- [Apple Support — Mail keyboard shortcuts and gestures](https://support.apple.com/guide/mail/keyboard-shortcuts-and-gestures-mlhl0caefebd/mac)
- [Howard Oakley — How Mail stores your messages](https://eclecticlight.co/2020/02/27/last-week-on-my-mac-tracking-down-the-Mail-V-folder/) — independent reference on V-number directory evolution
- [Mail Archiver X documentation](https://www.moonsoftware.com/mail-archiver-x.asp) — third-party utility that exports Mail to portable formats (mbox, PDF) — useful as a safety net if V-directory migration fails
- Empirical: Apple's V-directory bump cadence has been roughly one per major macOS release with occasional skips (Sonoma kept Ventura's V10)
