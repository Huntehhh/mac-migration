# Restore -- Per-Lane Command Reference

The inverse of `../../capture/references/lane-capture.md`. For each lane: prerequisites, exact restore commands, gotchas, and idempotency notes. The lane scripts in `../scripts/` implement these; this doc is the human-readable spec they follow.

**Universal rules every lane script honors:**

- Read `$BUNDLE/manifest.json` first. If lane is `"skip": true`, write `.done/<lane>` with `skipped=true` and exit 0.
- Check `.done/<lane>` marker. If present and `--force` not passed, exit 0.
- Every action appends to `$BUNDLE/migration.log.jsonl`.
- Re-run safety: every action is idempotent on its own (brew install no-ops on already-installed, `cp -n` won't clobber, `rsync` without `--delete` merges).
- Forward slashes everywhere. BSD-flavored tools only.

---

## LANE A -- Applications

### A1. Brewfile

**Prerequisites:**
- Xcode Command Line Tools (`xcode-select -p` returns a path)
- Internet connection

**If Homebrew not installed, run the official one-liner:**
```bash
NONINTERACTIVE=1 /bin/bash -c "$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)"
eval "$(/opt/homebrew/bin/brew shellenv)"  # Apple Silicon path
```

**Restore Brewfile:**
```bash
brew bundle --file="$BUNDLE/Brewfile" --no-lock
```

`brew bundle` is idempotent -- already-installed formulae are skipped. `--no-lock` prevents accidentally writing a `Brewfile.lock.json` to the bundle.

**Gotchas:**
- Fresh installs may have outdated taps in Brewfile -- `brew tap` lines fail soft, `brew bundle` continues
- If a cask requires Rosetta (older Intel-only apps), `brew bundle` will prompt; pre-install Rosetta via `softwareupdate --install-rosetta --agree-to-license` if you know you have Intel casks
- Apple Silicon vs Intel path mismatch -- if the bundle came from an Intel Mac and we're on Apple Silicon, some bottles may rebuild from source

### A2. Mac App Store apps (mas)

**Prerequisites:** Apple ID signed in to App Store app on the new Mac. Open App Store > Sign In before running.

**MAS apps are inside the Brewfile** as `mas "AppName", id: 123456` lines. `brew bundle` handles them via `mas install <id>`. But on a fresh Apple ID, `mas install` may fail because the apps weren't "purchased" by this Apple ID yet.

**Fallback for fresh Apple IDs:**
```bash
# If brew bundle reports mas install failures, use mas get instead:
xargs -n1 mas get < "$BUNDLE/manifests/mas-installed.txt"
```

`mas get` handles both purchased and free apps; `mas install` only re-downloads previously purchased.

**Gotchas:**
- Reference: [Homebrew/homebrew-bundle issue #371](https://github.com/Homebrew/homebrew-bundle/issues/371)
- If user is signed into a different Apple ID than the old Mac, some apps simply aren't available; surface a checklist

### A3. Orphan apps (manual)

**Manifest:** `$BUNDLE/manifests/system-apps.json` -- JSON output of `system_profiler SPApplicationsDataType`.

**Restore strategy:**
1. Parse the JSON, extract app names not covered by Brewfile or `mas-installed.txt`.
2. For each orphan, `brew search <name>` and check if a cask exists that we missed.
3. Write a checklist to `$BUNDLE/MANUAL-STEPS-orphan-apps.md` listing each orphan with:
   - Original install path
   - Suggested `brew install --cask <name>` if a match exists
   - Otherwise: "Install manually from <publisher URL>" placeholder

The script does NOT auto-install orphans -- that's a user decision (e.g., they may have deleted some apps and don't want them back).

---

## LANE B -- Shell + PATH + Custom Scripts

### B1 + B2. Dotfiles

**Two paths depending on capture mode:**

**Path 1 -- chezmoi (preferred):**
```bash
if [ -n "${CHEZMOI_REPO:-}" ]; then
  chezmoi init --apply "$CHEZMOI_REPO"
fi
```

`CHEZMOI_REPO` is set in `manifest.json` if the user used chezmoi during capture. `chezmoi apply` is idempotent.

**Path 2 -- raw rsync fallback (for users not yet on chezmoi):**
```bash
rsync -av "$BUNDLE/dotfiles-refs/" "$HOME/"
```

Surface a reminder: "These dotfiles are NOT version-controlled. Consider initializing chezmoi to track them."

**Gotchas:**
- Mackup is broken on Sonoma+ -- never fall back to it
- `~/.zshenv` PATH manipulation may be reordered by `path_helper` -- use `~/.zshrc` for PATH instead

### B3. /etc/paths + /etc/paths.d/

```bash
sudo cp "$BUNDLE/manifests/etc-paths.txt" /etc/paths
sudo cp -R "$BUNDLE/manifests/etc-paths.d/." /etc/paths.d/
```

The trailing `.` on the source ensures we copy contents into the existing dir, not nest it.

**Gotchas:**
- Order matters in `/etc/paths` -- earlier lines win precedence
- Homebrew install adds `/opt/homebrew/bin` to `/etc/paths.d/` automatically -- don't duplicate

### B4. ~/bin + ~/.local/bin

```bash
[ -d "$BUNDLE/home-bin" ] && rsync -av "$BUNDLE/home-bin/" "$HOME/bin/"
[ -d "$BUNDLE/home-local-bin" ] && rsync -av "$BUNDLE/home-local-bin/" "$HOME/.local/bin/"
chmod -R +x "$HOME/bin" 2>/dev/null || true
chmod -R +x "$HOME/.local/bin" 2>/dev/null || true
```

### B5. /etc/hosts + /etc/sudoers.d/

**Hosts:**
```bash
sudo cp "$BUNDLE/manifests/etc-hosts" /etc/hosts
```

**Sudoers -- VALIDATE BEFORE ACTIVATING:**
```bash
SUDOERS_DIR="$BUNDLE/manifests/sudoers.d"
for f in "$SUDOERS_DIR"/*; do
  [ -f "$f" ] || continue
  if sudo visudo -c -f "$f"; then
    sudo cp "$f" "/etc/sudoers.d/$(basename "$f")"
    sudo chmod 0440 "/etc/sudoers.d/$(basename "$f")"
  else
    echo "SKIP: $(basename "$f") failed visudo syntax check"
  fi
done
```

**Critical:** invalid sudoers files can lock the user out of sudo entirely. The `visudo -c -f` check is non-negotiable.

---

## LANE C -- Language Toolchains + Globals

### C1. mise

**Prerequisites:** Homebrew installed (Lane A).

```bash
brew install mise 2>/dev/null || true
cp "$BUNDLE/manifests/.tool-versions" "$HOME/.tool-versions"
[ -f "$BUNDLE/manifests/mise-config.toml" ] && mkdir -p "$HOME/.config/mise" && cp "$BUNDLE/manifests/mise-config.toml" "$HOME/.config/mise/config.toml"
mise install
```

`mise install` reads `~/.tool-versions` and downloads each runtime. Idempotent -- already-installed versions are skipped.

**Gotcha:** Lane C must run AFTER Lane B because mise needs `eval "$(mise activate)"` in `~/.zshrc` to be sourced by the shell.

### C2. pipx

```bash
brew install pipx 2>/dev/null || true
pipx ensurepath
jq -r '.venvs | keys[]' "$BUNDLE/manifests/pipx.json" | while read pkg; do
  pipx install "$pkg" || echo "FAIL: pipx install $pkg"
done
```

**Gotcha:** pipx envs are Python-version-locked. If mise restored a different Python minor version than the old Mac had, some envs may not install (e.g., a tool that pinned to python 3.12 won't install under 3.13). Surface failures, don't halt.

### C3. npm globals

**Prerequisites:** Lane C1 (mise) installed Node, OR brew installed node.

```bash
jq -r '.dependencies | keys[]' "$BUNDLE/manifests/npm-globals.json" \
  | grep -v '^npm$' \
  | xargs -n1 npm install -g
```

`grep -v '^npm$'` -- skip npm itself (it's bundled with node, installing it globally creates a loop).

### C4. cargo + cargo-binstall

**Prerequisites:** Rust toolchain via mise (or `brew install rust`).

```bash
cargo install cargo-binstall
awk '/^[a-z0-9_-]+ v/ {print $1}' "$BUNDLE/manifests/cargo-installs.txt" \
  | xargs -I{} cargo binstall -y {}
```

`cargo-binstall` pulls pre-built binaries from GitHub releases (~80% faster than `cargo install` source compile). Falls back to source compile if no binary exists.

### C5. gem

```bash
awk '/^[a-z]/ && $1 !~ /^---/ {print $1}' "$BUNDLE/manifests/gem-list.txt" \
  | xargs -n1 gem install
```

**Gotcha:** Multi-version Ruby (mise-managed) -- gems are per-version. Capture file may need per-version sections.

### C6. go bin

Go has no install-from-list. The bundle's `go-bin.txt` lists binary names, not source paths. Surface to user as a checklist:

```bash
echo "Go binaries to reinstall (manual go install needed):" > "$BUNDLE/MANUAL-STEPS-go-bin.md"
cat "$BUNDLE/manifests/go-bin.txt" >> "$BUNDLE/MANUAL-STEPS-go-bin.md"
```

### C7. composer globals

```bash
jq -r '.installed[].name' "$BUNDLE/manifests/composer-globals.json" \
  | xargs -n1 composer global require
```

---

## LANE D -- GUI App Configs

### D1. defaults plists

```bash
for plist in "$BUNDLE/defaults/"*.plist; do
  domain=$(basename "$plist" .plist)
  defaults import "$domain" "$plist" || echo "FAIL: defaults import $domain"
done
killall cfprefsd 2>/dev/null || true
```

**Critical:** `killall cfprefsd` after the batch. Without it, the prefs cache stays in memory and apps may overwrite the imports on next launch.

**Gotcha:** Sandboxed apps' prefs live in `~/Library/Containers/<bundle>/Data/Library/Preferences/` and `defaults import` won't reach those. Those domains are filtered out at capture time.

### D2. ~/Library/Application Support (selective)

```bash
rsync -av "$BUNDLE/AppSupport/" "$HOME/Library/Application Support/"
```

The capture phase already excluded `*Cache*` patterns. Cloud-synced apps (1Password, Notion, Slack) re-sync from server on first launch -- their AppSupport rsync is harmless but redundant.

**Per-app opt-outs respected** -- check `manifest.json.lane_d.appsupport_skip` for app names the user said skip.

### D3. Containers / Group Containers

**Skip by default.** Sandboxed apps' containers are ACL'd to the original code-signature + Team ID; copying creates silent failures or "different app wants to access" warnings.

If user explicitly enabled (`manifest.json.lane_d.containers_restore: true`):
```bash
rsync -av "$BUNDLE/Containers/" "$HOME/Library/Containers/"
# Expected: many apps prompt "Different app wants access" on first launch. User accepts each.
```

Default is `false`. Surface advisory: per-app native export/import is safer.

### D4. Fonts

```bash
rsync -av "$BUNDLE/fonts/" "$HOME/Library/Fonts/"
sudo atsutil databases -remove
# Advisory: reboot for full font database rebuild
echo "Fonts rsynced. Reboot recommended for full database rebuild."
```

### D5. Stickies + Notes + Mail

**Stickies:** Restore the Catalina+ RTF files:
```bash
mkdir -p "$HOME/Library/Containers/com.apple.Stickies/Data/Library/Stickies/"
rsync -av "$BUNDLE/stickies/" "$HOME/Library/Containers/com.apple.Stickies/Data/Library/Stickies/"
```

**Notes (local):** Skip if iCloud is signed in (sync handles it). If `manifest.json.lane_d.notes_local: true`:
```bash
rsync -av "$BUNDLE/notes-group-container/" "$HOME/Library/Group Containers/group.com.apple.notes/"
```

**Mail:** V-dir version may differ on the new Mac. Capture stored as `mail/V<n>/`. On restore:
```bash
NEW_VDIR=$(ls -d "$HOME/Library/Mail/V"* 2>/dev/null | head -1)
OLD_VDIR=$(ls -d "$BUNDLE/mail/V"* | head -1)
if [ -z "$NEW_VDIR" ]; then
  echo "Mail not yet initialized on new Mac. Launch Mail.app once, then re-run Lane D."
elif [ "$(basename "$OLD_VDIR")" != "$(basename "$NEW_VDIR")" ]; then
  echo "WARNING: Mail V-dir version mismatch (old: $(basename "$OLD_VDIR"), new: $(basename "$NEW_VDIR"))."
  echo "Rules + signatures + smart mailboxes may not load. rsync proceeding anyway."
fi
rsync -av "$OLD_VDIR/MailData/" "$NEW_VDIR/MailData/" || true
rsync -av "$OLD_VDIR/Signatures/" "$NEW_VDIR/Signatures/" || true
```

### Post-Lane-D TCC deep links

After Lane D completes, surface TCC re-grant deep links for any app that had FDA on the old Mac (Mail, Terminal, iTerm2, etc.):

```bash
echo "Apps that had Full Disk Access on the old Mac may need re-granting:"
"$PARENT/scripts/tcc_deep_link.sh" full-disk-access
```

---

## LANE E -- Browsers

### E1. Chrome

```bash
echo "Chrome: Open Chrome, sign in to your Google account, and sync handles bookmarks/extensions/passwords."
echo "For orphan extensions not auto-synced, see: $BUNDLE/browsers/chrome-extensions.txt"
```

No file copy -- Chrome's profile is account-synced.

### E2. Brave

```bash
echo "Brave: Open Brave, enable Brave Sync in Settings > Sync (more reliable than manual copy)."
```

### E3. Firefox -- REQUIRES QUIT FIRST

```bash
if pgrep -x "firefox" > /dev/null; then
  echo "ERROR: Firefox is running. Quit Firefox before restoring profile."
  exit 1
fi
mkdir -p "$HOME/Library/Application Support/Firefox/Profiles/"
rsync -av "$BUNDLE/browsers/firefox-profiles/" "$HOME/Library/Application Support/Firefox/Profiles/"
[ -f "$BUNDLE/browsers/firefox-profiles.ini" ] && \
  cp "$BUNDLE/browsers/firefox-profiles.ini" "$HOME/Library/Application Support/Firefox/profiles.ini"
```

### E4. Safari -- BEFORE FIRST LAUNCH

```bash
if [ -f "$BUNDLE/browsers/safari-bookmarks.plist" ]; then
  mkdir -p "$HOME/Library/Safari"
  cp "$BUNDLE/browsers/safari-bookmarks.plist" "$HOME/Library/Safari/Bookmarks.plist"
  echo "Safari bookmarks restored. Do NOT launch Safari before this step completes."
fi
```

**Gotcha:** If Safari is already launched on the new Mac, it owns the bookmarks plist and may overwrite the restore on next quit. Sign in to iCloud and let sync handle it, OR restore before first launch.

### E5. Arc

```bash
echo "Arc: Open Arc and use built-in 'Import from Another Browser' menu."
echo "Arc's profile format is not stable for raw copy."
```

### E6. Edge

```bash
echo "Edge: Open Edge, sign in to Microsoft account, sync handles bookmarks/extensions/passwords."
```

---

## LANE F -- IDEs + Terminals

### F1. VS Code + Cursor

```bash
# VS Code
if command -v code > /dev/null; then
  while read ext; do
    code --install-extension "$ext" 2>/dev/null || true
  done < "$BUNDLE/ides/vscode-extensions.txt"
fi
CODE_USER="$HOME/Library/Application Support/Code/User"
mkdir -p "$CODE_USER"
[ -f "$BUNDLE/ides/vscode/settings.json" ] && cp "$BUNDLE/ides/vscode/settings.json" "$CODE_USER/"
[ -f "$BUNDLE/ides/vscode/keybindings.json" ] && cp "$BUNDLE/ides/vscode/keybindings.json" "$CODE_USER/"
[ -d "$BUNDLE/ides/vscode/snippets" ] && rsync -av "$BUNDLE/ides/vscode/snippets/" "$CODE_USER/snippets/"

# Cursor (different dir)
if command -v cursor > /dev/null; then
  while read ext; do
    cursor --install-extension "$ext" 2>/dev/null || true
  done < "$BUNDLE/ides/cursor-extensions.txt" 2>/dev/null
fi
CURSOR_USER="$HOME/Library/Application Support/Cursor/User"
[ -d "$BUNDLE/ides/cursor" ] && mkdir -p "$CURSOR_USER" && rsync -av "$BUNDLE/ides/cursor/" "$CURSOR_USER/"
```

**Gotcha:** Cursor has a different extension marketplace. Some VS Code extensions fail to install. Failures are logged but don't halt the script.

### F2. Zed

```bash
mkdir -p "$HOME/.config/zed"
[ -d "$BUNDLE/ides/zed" ] && rsync -av "$BUNDLE/ides/zed/" "$HOME/.config/zed/"
```

### F3. JetBrains

```bash
JB_DIR="$HOME/Library/Application Support/JetBrains"
[ -d "$BUNDLE/ides/jetbrains" ] && mkdir -p "$JB_DIR" && rsync -av "$BUNDLE/ides/jetbrains/" "$JB_DIR/"
echo "JetBrains configs restored. Advisory: SDK paths embed absolute paths from old Mac."
echo "Open each IDE and update via File > Project Structure > Project SDK."
```

### F4. Neovim / Emacs

Already covered by Lane B (chezmoi/dotfiles) -- `~/.config/nvim/` and `~/.emacs.d/` are version-controlled.

### F5. Terminals

**iTerm2:**
```bash
if [ -f "$BUNDLE/ides/iterm2.plist" ]; then
  cp "$BUNDLE/ides/iterm2.plist" "$HOME/Library/Preferences/com.googlecode.iterm2.plist"
  defaults read com.googlecode.iterm2 > /dev/null 2>&1  # flush cfprefsd
  killall cfprefsd 2>/dev/null || true
fi
```

**Warp:**
```bash
echo "Warp: Open Warp. If old Mac was on iTerm2, use Warp's built-in iTerm2 importer."
WARP_DIR="$HOME/Library/Application Support/dev.warp.Warp-Stable"
[ -d "$BUNDLE/ides/warp" ] && mkdir -p "$WARP_DIR" && rsync -av "$BUNDLE/ides/warp/" "$WARP_DIR/"
```

**Ghostty / Alacritty / Kitty:** Covered by Lane B (`~/.config/ghostty/`, `~/.config/alacritty/`, `~/.config/kitty/`).

---

## LANE G -- Databases + Containers

Per-app playbooks at `../../references/per-app/postgres.md` and `../../references/per-app/docker.md` are authoritative. This section is the call pattern.

### G1. Postgres

**Prerequisites:** `brew install postgresql@<major>` matching the dump's version.

```bash
# Detect Postgres version from dump file header or bundle metadata
PG_MAJOR=$(jq -r '.lane_g.postgres_major // "17"' "$BUNDLE/manifest.json")
brew install "postgresql@$PG_MAJOR" 2>/dev/null || true
brew services start "postgresql@$PG_MAJOR"
sleep 3  # let it bind
psql -U postgres -f "$BUNDLE/databases/postgres-all.sql"
```

**Reinstall extensions** (pgvector, postgis, etc.) per the per-app playbook:
```bash
[ -f "$BUNDLE/manifests/postgres-extensions.txt" ] && \
  awk '{print "brew reinstall " $1}' "$BUNDLE/manifests/postgres-extensions.txt" | bash
```

**Cross-major upgrade** (old Mac was PG 16, new Mac running PG 17): use `pg_upgrade` -- see per-app playbook.

### G2. MySQL

```bash
brew install mysql 2>/dev/null || true
brew services start mysql
sleep 3
mysql -u root < "$BUNDLE/databases/mysql-all.sql"
```

### G3. Redis

```bash
brew install redis 2>/dev/null || true
brew services stop redis 2>/dev/null || true
REDIS_DIR="/opt/homebrew/var/db/redis"
mkdir -p "$REDIS_DIR"
cp "$BUNDLE/databases/redis-dump.rdb" "$REDIS_DIR/dump.rdb"
brew services start redis
```

### G4. MongoDB

```bash
brew tap mongodb/brew
brew install mongodb-community 2>/dev/null || true
brew services start mongodb-community
sleep 3
mongorestore "$BUNDLE/databases/mongodb-dump/"
```

### G5. Docker

**Critical refusal:** Per `../../references/per-app/docker.md`, NEVER restore `~/Library/Group Containers/group.com.docker/` -- it kills the Docker daemon.

```bash
# Install Docker Desktop via cask (idempotent)
brew install --cask docker 2>/dev/null || true

# Restore ONLY ~/.docker/
[ -d "$BUNDLE/docker" ] && rsync -av "$BUNDLE/docker/" "$HOME/.docker/"

# Refuse to copy Group Containers even if present in bundle
if [ -d "$BUNDLE/docker-group-containers" ]; then
  echo "REFUSING to restore docker-group-containers (kills Docker daemon)"
fi

echo "Docker Desktop installed. Launch it manually on first run; daemon recreates state."
```

### G6. Kubernetes

```bash
mkdir -p "$HOME/.kube"
cp "$BUNDLE/manifests/kubeconfig" "$HOME/.kube/config"
chmod 600 "$HOME/.kube/config"

# Install krew and reinstall plugins
if command -v kubectl > /dev/null && ! kubectl krew > /dev/null 2>&1; then
  (
    set -x; cd "$(mktemp -d)"
    OS="$(uname | tr '[:upper:]' '[:lower:]')"
    ARCH="$(uname -m | sed 's/x86_64/amd64/' | sed 's/aarch64/arm64/')"
    KREW="krew-${OS}_${ARCH}"
    curl -fsSLO "https://github.com/kubernetes-sigs/krew/releases/latest/download/${KREW}.tar.gz"
    tar zxvf "${KREW}.tar.gz"
    ./"${KREW}" install krew
  )
fi
if [ -f "$BUNDLE/manifests/krew-plugins.txt" ]; then
  while read plugin; do
    kubectl krew install "$plugin" 2>/dev/null || true
  done < "$BUNDLE/manifests/krew-plugins.txt"
fi
```

### G7. Helm

```bash
brew install helm 2>/dev/null || true
[ -f "$BUNDLE/manifests/helm-repos.txt" ] && \
  awk '{system("helm repo add " $1 " " $2)}' "$BUNDLE/manifests/helm-repos.txt"
helm repo update
```

---

## LANE H -- Background Services

### Tahoe SIP advisory FIRST

```bash
TARGET_OS=$("$PARENT/scripts/detect_macos_version.sh" | awk '{print $1}')
if [ "$TARGET_OS" -ge 26 ]; then
  cat "$PARENT/references/tahoe-sip-advisory.md"
  echo
  echo "Proceeding with user-level LaunchAgents only by default."
  echo "Pass --include-system-daemons to also attempt /Library/LaunchDaemons (may fail on Tahoe)."
fi
```

See `../../references/tahoe-sip-advisory.md`.

### H1. User LaunchAgents

```bash
mkdir -p "$HOME/Library/LaunchAgents"
rsync -av "$BUNDLE/launchd/user-LaunchAgents/" "$HOME/Library/LaunchAgents/"

# Bootstrap each (macOS 13+ form)
for plist in "$HOME/Library/LaunchAgents/"*.plist; do
  [ -f "$plist" ] || continue
  launchctl bootstrap "gui/$(id -u)" "$plist" 2>/dev/null || true
done
```

**Gotcha:** `ProgramArguments` paths in plists must exist on the new Mac. If Lane A (apps) + Lane C (toolchains) haven't completed, agents will fail to start. Lane H runs after both for this reason.

### H2. System LaunchDaemons (opt-in only)

```bash
if [ "${INCLUDE_SYSTEM_DAEMONS:-0}" = "1" ]; then
  sudo rsync -av "$BUNDLE/launchd/system-LaunchDaemons/" "/Library/LaunchDaemons/"
  for plist in "$BUNDLE/launchd/system-LaunchDaemons/"*.plist; do
    sudo launchctl bootstrap system "$plist" 2>/dev/null || true
  done
fi
```

On Tahoe (macOS 26+), this may fail with SIP errors. The advisory above warned the user.

### H3. brew services running state

```bash
awk '$2=="started" {print $1}' "$BUNDLE/manifests/brew-services-running.txt" \
  | xargs -n1 brew services start
```

### H4. PM2

```bash
if command -v pm2 > /dev/null; then
  mkdir -p "$HOME/.pm2"
  cp "$BUNDLE/manifests/pm2-dump.pm2" "$HOME/.pm2/dump.pm2"
  pm2 resurrect
  pm2 startup | tail -1 | sh  # gets the sudo command and runs it
fi
```

### H5. cron

```bash
crontab "$BUNDLE/manifests/user-crontab.txt"
```

### H6. Login Items

No programmatic API for legacy Login Items. Modern apps using `SMAppService` re-register themselves on first launch.

```bash
echo "Legacy Login Items must be re-added manually via System Settings > General > Login Items." >> "$BUNDLE/MANUAL-STEPS-login-items.md"
cat "$BUNDLE/manifests/login-items.txt" >> "$BUNDLE/MANUAL-STEPS-login-items.md"
```

### H7. Launchpad (optional)

```bash
if [ "$(jq -r '.lane_h.launchpad_restore // false' "$BUNDLE/manifest.json")" = "true" ]; then
  if command -v lporg > /dev/null && [ -f "$BUNDLE/manifests/launchpad-layout.yml" ]; then
    lporg load -c "$BUNDLE/manifests/launchpad-layout.yml"
  else
    echo "Launchpad layout not restored (lporg not installed or layout file missing)."
  fi
fi
```

`lporg` is archived (Sept 2025) but functional on macOS 26. Most power users skip Launchpad and use Spotlight/Raycast.

---

## LANE I -- Credentials + Auth

### Prerequisites

- GPG key imported on new Mac (`gpg --list-secret-keys` shows the key)
- OR YubiKey plugged in (if using hardware GPG)

### Decrypt the sealed bundle

```bash
"$PARENT/scripts/encrypt_creds.sh" unseal "$BUNDLE/credentials/credentials.tar.gz.gpg" "$BUNDLE/credentials/_unsealed"
```

This extracts to `$BUNDLE/credentials/_unsealed/` (temp dir). All paths below assume that prefix.

### I1. Git + GitHub CLI

```bash
UNSEAL="$BUNDLE/credentials/_unsealed"
cp "$UNSEAL/gitconfig" "$HOME/.gitconfig"
[ -f "$UNSEAL/gitconfig.local" ] && cp "$UNSEAL/gitconfig.local" "$HOME/.gitconfig.local"
mkdir -p "$HOME/.config/gh"
[ -f "$UNSEAL/gh-hosts.yml" ] && cp "$UNSEAL/gh-hosts.yml" "$HOME/.config/gh/hosts.yml"
command -v gh > /dev/null && gh auth setup-git
```

**Gotcha:** `osxkeychain` credential helper data stays in the old Mac's Keychain -- does NOT migrate. User will need to re-auth git pushes once.

### I2. Cloud CLIs

```bash
# AWS
mkdir -p "$HOME/.aws"
[ -f "$UNSEAL/aws/credentials" ] && cp "$UNSEAL/aws/credentials" "$HOME/.aws/credentials"
[ -f "$UNSEAL/aws/config" ] && cp "$UNSEAL/aws/config" "$HOME/.aws/config"
chmod 600 "$HOME/.aws/credentials" 2>/dev/null || true

# gcloud -- tokens are short-lived, advise re-auth
mkdir -p "$HOME/.config/gcloud"
[ -d "$UNSEAL/gcloud" ] && rsync -av "$UNSEAL/gcloud/" "$HOME/.config/gcloud/"
echo "gcloud: tokens expire (~1h access). Run 'gcloud auth login' and 'gcloud auth application-default login' if needed."

# Azure -- re-auth
mkdir -p "$HOME/.azure"
[ -d "$UNSEAL/azure" ] && rsync -av "$UNSEAL/azure/" "$HOME/.azure/"
echo "Azure: tokens short-lived. Run 'az login' if 'az account show' fails."

# Cloudflare -- long-lived
mkdir -p "$HOME/.cloudflared"
[ -d "$UNSEAL/cloudflared" ] && rsync -av "$UNSEAL/cloudflared/" "$HOME/.cloudflared/"

# DigitalOcean
mkdir -p "$HOME/.config/doctl"
[ -d "$UNSEAL/doctl" ] && rsync -av "$UNSEAL/doctl/" "$HOME/.config/doctl/"
```

### I3. CLI tokens (npm, cargo, gem, etc.)

```bash
[ -f "$UNSEAL/npmrc" ] && cp "$UNSEAL/npmrc" "$HOME/.npmrc"
[ -f "$UNSEAL/cargo-credentials.toml" ] && mkdir -p "$HOME/.cargo" && cp "$UNSEAL/cargo-credentials.toml" "$HOME/.cargo/credentials.toml"
[ -f "$UNSEAL/gem-credentials" ] && mkdir -p "$HOME/.gem" && cp "$UNSEAL/gem-credentials" "$HOME/.gem/credentials" && chmod 600 "$HOME/.gem/credentials"
[ -f "$UNSEAL/composer-auth.json" ] && mkdir -p "$HOME/.config/composer" && cp "$UNSEAL/composer-auth.json" "$HOME/.config/composer/auth.json"
[ -f "$UNSEAL/pypirc" ] && cp "$UNSEAL/pypirc" "$HOME/.pypirc"
[ -f "$UNSEAL/huggingface-token" ] && mkdir -p "$HOME/.huggingface" && cp "$UNSEAL/huggingface-token" "$HOME/.huggingface/token"
[ -f "$UNSEAL/netrc" ] && cp "$UNSEAL/netrc" "$HOME/.netrc" && chmod 600 "$HOME/.netrc"
```

**npm classic token warning:**
```
WARNING: npm classic tokens (legacy _authToken) were revoked Nov-Dec 2025.
If your ~/.npmrc has a classic token, npm publish/install will fail.
Generate a new granular token at https://www.npmjs.com/settings/<user>/tokens
```

### I4. SSH keys -- CRITICAL PERMISSIONS

```bash
mkdir -p "$HOME/.ssh"
rsync -av "$UNSEAL/ssh/" "$HOME/.ssh/"
chmod 700 "$HOME/.ssh"
chmod 600 "$HOME/.ssh/"*
# Public keys are 644, but 600 also works
find "$HOME/.ssh" -name "*.pub" -exec chmod 644 {} \;
```

**SSH silently refuses keys with wrong permissions.** This step is non-negotiable.

### I5. GPG keys + ownertrust

```bash
[ -f "$UNSEAL/gpg-secret.asc" ] && gpg --import "$UNSEAL/gpg-secret.asc"
[ -f "$UNSEAL/gpg-trust.txt" ] && gpg --import-ownertrust "$UNSEAL/gpg-trust.txt"
```

### I6. WireGuard

```bash
# CLI WireGuard
sudo mkdir -p /etc/wireguard
[ -d "$UNSEAL/wireguard-etc" ] && sudo rsync -av "$UNSEAL/wireguard-etc/" "/etc/wireguard/"
sudo chmod 600 /etc/wireguard/*.conf 2>/dev/null || true

# App Store WireGuard -- surface manual import
echo "App Store WireGuard: use 'Import Tunnels From Zip' menu in the GUI to restore tunnels."
echo "Old Mac zip at: $UNSEAL/wireguard-tunnels.zip"
```

### Securely wipe unsealed plaintext

```bash
# After all I-lane copies succeed, shred the temp unsealed dir
find "$BUNDLE/credentials/_unsealed" -type f -exec rm -P {} \; 2>/dev/null || \
  rm -rf "$BUNDLE/credentials/_unsealed"
```

`rm -P` overwrites the file 3x before unlinking (BSD `rm` flag, macOS supported). Fallback to `rm -rf` if `-P` unavailable.

---

## LANE J -- Manual / Deferred

No script -- `cleanup_old_mac_advisory.sh` emits two checklists at the end:

- `~/MIGRATION-MANUAL-STEPS.md` -- TCC re-grants (with deep links), iCloud Keychain, app licenses, Time Machine, Spotlight, Rosetta check
- `~/MIGRATION-CLEANUP-OLD-MAC.md` -- deactivate licenses on old Mac, sign out of iCloud, secure-erase guidance

User walks them at their pace.
