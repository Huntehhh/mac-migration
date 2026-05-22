---
name: restore
description: >
  Phase 3 of mac-migration. Consume the migration-bundle on the new Mac and rehydrate every opted-in
  lane idempotently. Verify SHA256 integrity, decrypt Lane I credentials, restore lanes A through I
  in dependency order (apps first, then shell, toolchains, GUI configs, browsers, IDEs, databases,
  services, then credentials last), detect target macOS version for Tahoe SIP advisory, surface TCC
  deep links for permission re-grants, and emit a cleanup checklist for the old Mac. Each lane is
  cron-rerunnable; .done markers skip completed work. Use when the user says "restore from the
  migration bundle", "I'm on the new Mac", "rehydrate this machine", "unpack migration-bundle", or
  has finished capture on the old Mac and is ready to consume on the target.
metadata:
  compatibility: macos
---

# Restore

Phase 3. Take `~/migration-bundle/` (or `migration-bundle.tar.zst`) on a freshly-installed Mac and rehydrate every lane the user opted into during inventory. Idempotent, resumable, integrity-verified, and surfaces the unmigrate-able stuff (TCC, app licenses, old-Mac cleanup) at the end.

## When to route here

The user is sitting at a new Mac with the bundle present (USB, AirDrop drop, iCloud Drive copy, or already-decompressed in `~/migration-bundle/`). Inventory + capture happened on the OLD Mac; restore happens here. Triggers:

- "restore from the bundle"
- "I'm on the new Mac"
- "unpack migration-bundle"
- "rehydrate this machine"
- "run mac-migration restore"

If the user is still on the old Mac, route to **[capture](../capture/SKILL.md)** instead. If they finished restore and want to verify, route to **[diff](../diff/SKILL.md)**.

## Decision tree -- first question

Look at what the user has:

```
Bundle is a .tar.zst file?
  -> Yes -> Run scripts/unpack_bundle.sh first (verify SHA256, extract, validate manifest)
         -> Then proceed lane-by-lane
  -> No, bundle is already a directory at ~/migration-bundle/
         -> Run scripts/unpack_bundle.sh in verify-only mode (manifest.sha256 check)
         -> Then proceed lane-by-lane

Bundle is missing or corrupt?
  -> Halt. User needs to re-transfer from old Mac.
```

Then check `~/migration-bundle/manifest.json` -- that's the opt-in/opt-out manifest written by inventory. Every lane script respects it. If a lane is `"skip": true`, the script no-ops and writes a `.done/<lane>` marker with `skipped=true` so reruns don't retry.

## Execution model -- lane-by-lane

Restore runs lanes A through I sequentially. The order is deliberate -- later lanes depend on earlier ones:

```
A (apps)         -> Homebrew + MAS apps exist before anything else needs them
B (shell)        -> dotfiles + PATH + ~/bin + sudoers in place before toolchain commands run
C (toolchains)   -> mise + pipx + npm + cargo + gem rely on Homebrew (A) and shell PATH (B)
D (GUI configs)  -> defaults plists + AppSupport + fonts after apps installed
E (browsers)     -> Browser profiles after browsers installed via brew cask (A)
F (IDEs)         -> VS Code/Cursor/Zed/JetBrains/Nvim configs after IDEs installed (A)
G (databases)    -> Postgres/MySQL/Redis/Mongo/Docker/k8s after brew installs servers (A)
H (services)     -> LaunchAgents/brew services/PM2/cron AFTER toolchains (C) + apps (A) exist
I (creds)        -> SSH/GPG/cloud CLI tokens last -- gated behind GPG decrypt
```

Lane J (manual deferred items) is not auto-handled -- it surfaces as a checklist at the end.

Each lane is a single `.sh` file in `scripts/`. Each is cron-rerunnable in isolation. Each writes a `.done/lane-X-<theme>` marker on success. Re-running restore skips completed lanes unless `--force <lane>` is passed.

See [references/lane-restore.md](references/lane-restore.md) for the per-lane command details, prerequisites, and gotchas.

## Idempotency -- .done markers

Every lane script starts with a check via the shared helper [`../scripts/lane_done_marker.sh`](../scripts/lane_done_marker.sh):

```bash
if "$PARENT/scripts/lane_done_marker.sh" check "lane-a-apps"; then
  echo "Lane A already complete; skipping. Use --force to re-run."
  exit 0
fi
```

On success the script writes the marker:

```bash
"$PARENT/scripts/lane_done_marker.sh" write "lane-a-apps"
```

Markers live in `~/migration-bundle/.done/`. Deleting `.done/lane-a-apps` forces lane A to re-run on the next invocation.

Beyond markers, every action inside a lane should be idempotent on its own:
- `brew install x` is a no-op if x is already installed
- `cp -n src dst` won't overwrite an existing dst
- `rsync` (without `--delete`) merges instead of replacing
- `defaults import` overwrites the domain -- already idempotent semantics

When a lane mid-fails (e.g., Postgres dump didn't apply), re-running picks up where it left off because the actions before the failure are already done.

## Integrity verification -- SHA256

`migration-bundle/manifest.sha256` lists the SHA256 hash of every file in the bundle. The capture phase writes it; restore verifies it before touching anything.

`scripts/unpack_bundle.sh` does the verification. If any file's hash doesn't match, it halts with a non-zero exit and prints the offending path. Common causes: USB transfer corruption, iCloud Drive truncating large files, a partial AirDrop. User fix is re-transfer.

## Lane I -- encrypted credentials

Lane I (SSH keys, GPG keys, cloud tokens, git creds, WireGuard) is GPG-sealed during capture. The bundle ships `credentials/credentials.tar.gz.gpg`, NOT plaintext keys.

Restore flow:

1. `scripts/restore_lane_i_creds.sh` invokes `../scripts/encrypt_creds.sh unseal` to decrypt the tarball.
2. The user is prompted for the GPG passphrase (assumes they imported their personal GPG key on the new Mac first -- Lane I is bootstrap-aware).
3. Decrypted contents land in a temp dir, then rsync into final locations (`~/.ssh/`, `~/.gnupg/`, `~/.aws/`, etc.).
4. **SSH permissions are auto-corrected** -- `chmod 700 ~/.ssh && chmod 600 ~/.ssh/*` -- without this SSH silently refuses keys.
5. GPG import: `gpg --import secret-keys.asc && gpg --import-ownertrust ownertrust.txt`.
6. After success, the decrypted plaintext in `$BUNDLE/credentials/` is securely wiped (re-encrypted or shredded with `rm -P`).

See [../references/encryption-flow.md](../references/encryption-flow.md) for the full GPG seal/unseal mechanics.

## Target-Mac OS detection -- Tahoe SIP advisory

`../scripts/detect_macos_version.sh` returns the major version + codename of the new Mac. Stored in `manifest.json.target_macos` for the diff phase.

If the target is macOS 26 (Tahoe) or later, Lane H restore surfaces an advisory:

```
WARNING: macOS Tahoe (26) tightens SIP on /Library/LaunchDaemons.

Custom root-level daemons in your bundle may need rewriting as SMAppService-based
app-bundle helpers. Sandboxed apps can no longer install non-sandboxed daemons
(since macOS 14.2). This restore will install user-level LaunchAgents under
~/Library/LaunchAgents/ normally. System-level daemons require explicit
--include-system-daemons and may not register on Tahoe.

See ../references/tahoe-sip-advisory.md for the SMAppService rewrite pattern.
```

The user can proceed past the advisory or skip system daemons.

See [../references/tahoe-sip-advisory.md](../references/tahoe-sip-advisory.md).

## TCC deep links -- permission re-prompts

TCC (Transparency, Consent, Control) -- Full Disk Access, Accessibility, Camera, Mic, Screen Recording -- does not migrate. The TCC database is per-machine and per-Mac, code-signed against the user data.

Restore surfaces a per-app checklist at the end of Lane D (when defaults import may need FDA for some domains) and at the very end (final summary). Each entry uses `../scripts/tcc_deep_link.sh` which opens the System Settings panel directly:

```bash
"$PARENT/scripts/tcc_deep_link.sh" full-disk-access
"$PARENT/scripts/tcc_deep_link.sh" accessibility
"$PARENT/scripts/tcc_deep_link.sh" screen-recording
```

The deep links use `x-apple.systempreferences:` URLs -- they open the exact privacy panel, not the top-level System Settings.

See [../references/tcc-deep-links.md](../references/tcc-deep-links.md) for the URL scheme reference.

## Audit log

Every action in every lane appends a JSONL line to `migration-bundle/migration.log.jsonl`:

```json
{"ts":"2026-05-22T15:42:01Z","lane":"A","action":"brew install","target":"ripgrep","rc":0}
{"ts":"2026-05-22T15:42:03Z","lane":"A","action":"mas install","target":"497799835","rc":0}
{"ts":"2026-05-22T15:43:12Z","lane":"B","action":"cp /etc/hosts","target":"/etc/hosts","rc":0}
```

The diff phase reads this log to confirm what actually ran vs what the manifest planned. Use shared helper `audit_log.sh` pattern from the capture sibling.

## Order of operations -- full restore run

```
0. unpack_bundle.sh                  -> verify SHA256 + extract if tarball
1. restore_lane_a_apps.sh            -> Homebrew + Brewfile + mas + orphan-app reminder
2. restore_lane_b_shell.sh           -> chezmoi/dotfiles + /etc/paths + ~/bin + /etc/hosts + sudoers
3. restore_lane_c_toolchains.sh      -> mise + pipx + npm + cargo + gem + go + composer globals
4. restore_lane_d_gui_configs.sh     -> defaults import + AppSupport rsync + fonts + Mail/Stickies/Notes
5. restore_lane_e_browsers.sh        -> Firefox profile + Safari bookmarks + Chrome/Arc reminders
6. restore_lane_f_ides.sh            -> VS Code/Cursor extensions + Zed + JetBrains + terminal plists
7. restore_lane_g_databases.sh       -> Postgres dumpall + MySQL + Redis + Mongo + Docker + k8s
8. restore_lane_h_services.sh        -> LaunchAgents + brew services + PM2 + cron + Login Items
9. restore_lane_i_creds.sh           -> GPG decrypt + SSH/GPG/cloud/git/CLI tokens
10. cleanup_old_mac_advisory.sh      -> emit ~/MIGRATION-CLEANUP-OLD-MAC.md checklist
```

Run them in order. If a lane fails, fix the underlying issue and re-run -- the `.done` markers prevent re-doing successful lanes.

After lane 10 finishes, route to **[diff](../diff/SKILL.md)** to verify the new Mac matches the old.

## Cross-cutting features (inherited from parent)

| Feature | How restore implements |
|---------|------------------------|
| **Bundle integrity** | `unpack_bundle.sh` runs SHA256 verify before any lane touches files |
| **Encrypted creds** | Lane I script calls `../scripts/encrypt_creds.sh unseal` first |
| **Idempotency** | Every lane uses `.done/<lane>` markers; in-lane actions are individually idempotent |
| **Audit log** | Every action appends to `migration-bundle/migration.log.jsonl` |
| **Target-Mac OS detection** | `../scripts/detect_macos_version.sh` -> Tahoe advisory surfaces in Lane H |
| **TCC deep links** | `../scripts/tcc_deep_link.sh` invoked post-Lane D and final summary |
| **Cleanup-old-Mac advisory** | `cleanup_old_mac_advisory.sh` emits checklist after Lane I |
| **manifest.json opt-outs** | Every lane script reads `$BUNDLE/manifest.json` first, no-ops opted-out items |

## Prerequisites the user must handle BEFORE restore

These are checked by `unpack_bundle.sh` and refused with a clear error if missing:

- **Xcode Command Line Tools** -- `xcode-select --install` or `xcode-select -p` returns a path
- **Homebrew** -- Lane A installs it via the official curl-pipe-bash one-liner if missing, but the user should confirm internet access
- **Apple ID signed in** -- for MAS apps (Lane A2). Open App Store, sign in.
- **GPG key imported** -- for Lane I creds decrypt. If the user uses a YubiKey, plug it in. If they have the secret key file from the old Mac, `gpg --import` it before running Lane I.
- **Sufficient disk space** -- restore inflates ~2x bundle size during decompression + extraction

If any are missing, the script halts with `MANUAL-STEPS-prerequisites.md` written to the bundle root listing what's needed.

## Common gotchas

| Gotcha | Where it surfaces |
|--------|-------------------|
| Mail V-dir version differs on new Mac | Lane D -- surfaced as warning, rsync proceeds but rules may not load |
| Docker `Group Containers/` copied accidentally | Lane G -- script explicitly refuses to copy that path even if present in bundle |
| sudoers.d files break sudo if syntax-invalid | Lane B -- `visudo -c -f` validates each file BEFORE installing |
| SSH keys with wrong permissions silently fail | Lane I -- auto-chmod after restore |
| classic npm tokens dead post-Dec 2025 | Lane I -- surfaces reminder to regenerate granular tokens |
| Cron `/var/at/tabs/` is wiped on clean install | Lane H -- explicit `crontab <file>` reinstall |
| Launchpad layout requires `lporg` (archived) | Lane H -- optional, only if user opted in and `lporg` is in their PATH |
| Firefox profile copy requires Firefox quit | Lane E -- `pgrep firefox` sanity check |
| JetBrains configs embed absolute paths | Lane F -- surface advisory to update SDK paths via `File > Project Structure` |
| TCC re-prompts unavoidable | Lane J -- surfaced as checklist with deep links |

## Lane J -- manual deferred items

These cannot migrate programmatically. Restore surfaces them as a checklist at the end:

- iCloud Keychain -- re-enable in System Settings, verify WiFi auto-joins
- App-specific offline licenses -- Backblaze, Adobe, JetBrains, Setapp, Plex (deactivate on old Mac BEFORE wiping)
- TCC permissions -- walk System Settings > Privacy & Security and re-grant each app (deep links provided)
- Time Machine + Spotlight exclusions -- re-add via UI
- Rosetta state -- run `arch`; if returns `i386`, relaunch terminal natively
- iCloud Photos / Music / Messages -- re-enable in respective apps and let cloud sync rebuild local copies

Output: `~/MIGRATION-MANUAL-STEPS.md` (Lane J checklist) and `~/MIGRATION-CLEANUP-OLD-MAC.md` (what's safe to wipe on the old Mac).

## Handoff to diff

After lane 10 (cleanup advisory) finishes, the restore phase emits:

```
RESTORE COMPLETE.

Bundle:       ~/migration-bundle/
Bundle ID:    <uuid>
Lanes run:    A B C D E F G H I  (J = manual checklist)
Skipped:      <any opted-out lanes>
Audit log:    ~/migration-bundle/migration.log.jsonl

Next step:    Route to mac-migration diff to verify the new Mac matches the old.
              Run with: mac-migration diff --baseline ~/migration-bundle/manifest.json

Old-Mac cleanup checklist: ~/MIGRATION-CLEANUP-OLD-MAC.md
Manual steps remaining:    ~/MIGRATION-MANUAL-STEPS.md
```

Then the user can route to **[diff](../diff/SKILL.md)** for verification.

## Provenance

Restore is the inverse of capture, lane-for-lane. Built fresh from the parent skill's inventory-lanes.md spec. Idempotency model borrowed from chezmoi (`run_once_*` semantics) and Ansible (handler/notify pattern). SMAppService advisory derived from Apple's macOS 26 release notes + WWDC25 Daemons/Agents session. TCC deep links from Apple's `x-apple.systempreferences:` URL scheme (undocumented but stable since macOS Ventura). Bundle integrity model borrowed from Debian's `dpkg --verify` and Homebrew's bottle SHA256 pinning.
