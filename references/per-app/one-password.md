# Per-App Playbook — 1Password

**Lane:** D3 (sandboxed app data) + I3 (CLI auth)
**Risk level:** Low (account-based, server-of-truth)
**Recovery difficulty:** Easy — sign-in re-syncs everything

---

## Overview

1Password (versions 8 and later) is a server-of-truth product. Vaults live on 1Password's servers (or self-hosted for Teams/Business). The macOS app is a client — it caches an encrypted local copy in its container, but the source of truth is the cloud account.

The migration is simple: install via cask, sign into the same account, vaults re-sync. Do NOT copy the container directory — it's signed against the old Mac's installation and will be rejected on the new Mac.

**The 1Password 7 → 8 era is over** — 1Password 7 stored vaults as `.opvault` files locally, which DID require manual migration. 1Password 8 uses the cloud sync model. If the user is still on 1Password 7, recommend they upgrade to 8 on the old Mac BEFORE migration, since the local-vault model is end-of-life.

---

## Detect installed state

```bash
# Is 1Password 8 installed?
[ -d /Applications/1Password.app ] && echo "1Password 8 installed"

# Check version (1Password 8.x).
defaults read /Applications/1Password.app/Contents/Info.plist CFBundleShortVersionString

# Is the CLI (op) installed?
which op && op --version

# Is the user signed in to the CLI?
op account list 2>/dev/null || echo "Not signed in to CLI"

# What account(s) are on the desktop app?
ls ~/Library/Group\ Containers/2BUA8C4S2C.com.1password/ 2>/dev/null | head

# Is the SSH agent integration enabled?
ls ~/Library/Group\ Containers/2BUA8C4S2C.com.1password/t/agent.sock 2>/dev/null && echo "SSH agent enabled"
```

---

## Capture

```bash
# Capture the LIST of accounts the user is signed into (sanity reference only).
op account list --format=json > ~/migration-bundle/1password-accounts.json 2>/dev/null

# Capture CLI plugin config (these are shell aliases for op-injected commands).
[ -d ~/.config/op/plugins ] \
    && cp -R ~/.config/op/plugins ~/migration-bundle/1password-cli-plugins/

# Note: ~/.config/op/config is generated per-machine and should NOT be carried over.
```

**Explicitly NOT captured:**
- `~/Library/Group Containers/2BUA8C4S2C.com.1password/` — the container has ACL + code-signature constraints that reject cross-machine moves. The new 1Password install will recreate this.
- `~/Library/Application Support/1Password/` — same constraint.
- `~/Library/Containers/com.1password.1password/` — sandbox state, recreate-on-launch.

The sign-in QR code / Secret Key / passphrase trio is what the user needs in hand to re-authenticate. Recommend they have the Emergency Kit PDF accessible BEFORE starting the migration.

---

## Restore

```bash
# 1. Install 1Password via cask.
brew install --cask 1password

# 2. Install the CLI.
brew install --cask 1password-cli
# (or `brew install 1password-cli` depending on tap availability)

# 3. Launch the desktop app.
open /Applications/1Password.app

# 4. Sign in. The app handles this — user enters their account email, Secret Key,
#    and master password. Optional: use the QR code from the old Mac's
#    "1Password Settings -> Accounts -> Set up another device".
#    Vaults will sync from server (typically 30-90 seconds for a few GB).

# 5. Re-enable SSH agent integration.
#    Desktop app -> Settings -> Developer -> Use the SSH agent (toggle ON)
#    Also toggle: "Display key names when authorizing connections" (recommended)
#
# This writes to ~/.ssh/config equivalent at:
#    ~/Library/Group Containers/2BUA8C4S2C.com.1password/t/agent.sock
# And the user should ensure their ~/.ssh/config has:
#    Host *
#        IdentityAgent "~/Library/Group Containers/2BUA8C4S2C.com.1password/t/agent.sock"
#
# (chezmoi-managed dotfiles typically already have this line. Verify.)

# 6. Sign in to the CLI.
op signin
# (CLI reads from the desktop app's keychain — no separate auth needed if
# desktop app is configured.)

# 7. Restore CLI plugins.
[ -d ~/migration-bundle/1password-cli-plugins ] \
    && mkdir -p ~/.config/op \
    && cp -R ~/migration-bundle/1password-cli-plugins ~/.config/op/plugins

# 8. Verify.
op vault list
op item list --limit 1
ssh-add -L   # Should list keys from 1Password if SSH agent is configured
```

---

## Gotchas

- **DO NOT copy the Group Container.** `~/Library/Group Containers/2BUA8C4S2C.com.1password/` has ACL entries that reference the specific install's code-signing inode. Copying it to a new Mac produces "different app wants to access this container" warnings and the app refuses to use it. Sign-in is the documented and supported migration path.

- **The SSH agent integration is NOT file-restorable.** It must be re-enabled in the GUI. The `~/.ssh/config` `IdentityAgent` line is in dotfiles, but the actual agent activation is a setting in the desktop app's Developer panel.

- **CLI plugins (`op plugin init`).** If the user uses `op plugin init github`, `op plugin init aws`, etc. (which inject credentials into shell environment via op), the plugin config in `~/.config/op/plugins/` needs to be copied. The actual credential bindings re-resolve from the user's 1Password vaults on first use.

- **`op signin` without desktop app is harder.** If the user wants CLI-only without the desktop app (uncommon), they need to manually authenticate with their account, Secret Key, and master password — `op account add` then `op signin --account <shorthand>`. With the desktop app, this is automatic.

- **Apple Silicon native vs Intel.** 1Password 8 is universal binary. No Rosetta concerns. Same applies to the CLI.

- **Self-hosted / on-premise 1Password Business (Connect Server).** If the user is using 1Password Connect rather than 1password.com, the migration also needs the Connect token in `~/.config/op/`. Capture `~/.config/op/connect.json` separately if it exists.

- **Watchtower / breached site monitoring.** This is account-level, not local. Re-syncs automatically.

- **Browser extensions.** 1Password browser extensions (Chrome, Firefox, Safari, Brave, Edge) sync via the desktop app over a localhost named pipe. After desktop app restore, install the extension in each browser and authorize via the desktop app's pop-up. This is per-browser, manual.

---

## Recovery

If sign-in fails on the new Mac:

```bash
# Symptom: 1Password Settings -> Accounts shows account but vaults are empty.
# Cause:   Local sync state is corrupted (rare).
# Fix:     Sign out, quit, delete local cache, sign back in.

osascript -e 'quit app "1Password"'

# Remove local cache.
rm -rf ~/Library/Group\ Containers/2BUA8C4S2C.com.1password/Library/Caches
rm -rf ~/Library/Group\ Containers/2BUA8C4S2C.com.1password/Library/Application\ Support/1Password/Data

# Re-launch and sign in fresh.
open /Applications/1Password.app
```

If the user has lost their Secret Key AND master password AND has no Emergency Kit PDF, they are locked out permanently. 1Password's zero-knowledge architecture means even 1Password can't recover the vault. Surface this risk in the preflight check — the skill should ask "Do you have your 1Password Emergency Kit accessible?" before starting migration.

---

## Verify

```bash
# Desktop app is working: open a vault, see items.
# CLI is working:
op vault list                    # lists vaults
op item list --vault Personal    # lists items in a vault
op read "op://Personal/GitHub/password"   # reads a specific field

# SSH agent integration is working:
ssh-add -L                       # lists SSH keys from 1Password
ssh -T git@github.com            # GitHub greeting via 1Password key
```

---

## Sources

- [1Password support — Move from one Mac to another](https://support.1password.com/move-to-new-mac/)
- [1Password developer docs — 1Password CLI](https://developer.1password.com/docs/cli/)
- [1Password developer docs — SSH agent](https://developer.1password.com/docs/ssh/agent)
- [1Password developer docs — Shell plugins](https://developer.1password.com/docs/cli/shell-plugins/)
