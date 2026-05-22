# Per-Lane Capture Detail

Cross-reference: [../../references/inventory-lanes.md](../../references/inventory-lanes.md) is the canonical lane spec. This file documents the capture half — the exact commands, inputs, outputs, and gotchas executed by each `capture_lane_<x>_<name>.sh` script.

When the user opts out of a lane (or sub-module within a lane) via `manifest.json`, the corresponding capture script logs a skip entry and returns early without writing `.done`. Opt-out keys in manifest.json follow the pattern `opt_outs.lane_<x>.sub_module: true` or `opt_outs.lane_<x>: true` for whole-lane skips.

## Convention — every lane script

Common preamble shared by every script:

```bash
#!/usr/bin/env bash
set -euo pipefail
BUNDLE="${BUNDLE:-$HOME/migration-bundle}"
DRY_RUN="${DRY_RUN:-0}"
FORCE="${FORCE:-0}"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SUB_SKILL_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
SKILL_DIR="$(cd "$SUB_SKILL_DIR/.." && pwd)"
AUDIT="$SCRIPT_DIR/audit_log.sh"
DONE="$SKILL_DIR/scripts/lane_done_marker.sh"
```

Each script:

1. Loads `$BUNDLE/manifest.json` for opt-out keys (via jq)
2. Exits early if its `.done` marker exists and `--force` absent
3. Runs lane work, each sub-module guarded by `command -v <tool>` where applicable
4. Logs every action via `audit_log.sh`
5. Writes `.done/lane-<x>-<name>` only on full success

## LANE A — Applications

### A1. Brewfile

- **Command:** `brew bundle dump --force --describe --file="$BUNDLE/Brewfile"`
- **Output:** `$BUNDLE/Brewfile` (formulae + casks + taps + mas entries with descriptions)
- **Skip key:** `opt_outs.lane_a.brewfile`
- **Gotcha:** Dumps INSTALLED state, not RUNNING state. Pair with A2 brew-services snapshot. The `--describe` flag adds inline comments — load-bearing for restore-time review.

### A2. brew services running

- **Command:** `brew services list > "$BUNDLE/manifests/brew-services-running.txt"`
- **Output:** Plain text with three columns (name, status, plist path)
- **Skip key:** `opt_outs.lane_a.brew_services`
- **Gotcha:** This is the running-state snapshot. Restore extracts `awk '$2=="started" {print $1}'` and `brew services start` each.

### A3. Mac App Store apps

- **Command:** `mas list > "$BUNDLE/manifests/mas-installed.txt"` (gate on `command -v mas`)
- **Output:** Lines of `<id> <name> (<version>)`
- **Skip key:** `opt_outs.lane_a.mas`
- **Gotcha:** Brewfile already contains `mas` entries if mas-cli was installed when `brew bundle dump` ran. Capture the standalone list anyway as a cross-check.

### A4. Orphan apps (system_profiler)

- **Command:** `system_profiler SPApplicationsDataType -json > "$BUNDLE/manifests/system-apps.json"`
- **Output:** Full apps inventory JSON
- **Skip key:** `opt_outs.lane_a.orphan_apps`
- **Gotcha:** Used by restore to surface the diff between system-apps.json and Brewfile + mas list. Slow command (~10-30s on heavy setups); only fires once.

## LANE B — Shell + PATH + Custom Scripts

### B1/B2. Dotfile refs

For users not yet on chezmoi, flat-copy every rc file to a safety-net dir. If they ARE on chezmoi, this still grabs anything not yet committed (the discovery moment).

```bash
mkdir -p "$BUNDLE/dotfiles-refs"
for f in ~/.zshrc ~/.zprofile ~/.zshenv ~/.bashrc ~/.bash_profile ~/.profile ~/.inputrc ~/.tmux.conf ~/.gitignore_global; do
  [ -f "$f" ] && cp -p "$f" "$BUNDLE/dotfiles-refs/$(basename "$f")"
done
```

- **Skip key:** `opt_outs.lane_b.dotfile_refs`
- **Gotcha:** Use `cp -p` to preserve timestamps. `path_helper` (macOS) reorders PATH from /etc/zprofile — note this in audit log so restore reviewer sees it.

### B3. /etc/paths and /etc/paths.d/

- **Commands:** `sudo cp /etc/paths "$BUNDLE/manifests/etc-paths.txt" && sudo cp -R /etc/paths.d "$BUNDLE/manifests/etc-paths.d"`
- **Skip key:** `opt_outs.lane_b.system_paths`
- **Gotcha:** Requires sudo. Some apps (Postgres.app, VS Code) drop entries here on install. Order matters for PATH precedence.

### B4. ~/bin and ~/.local/bin

```bash
[ -d ~/bin ]         && rsync -av ~/bin/         "$BUNDLE/home-bin/"
[ -d ~/.local/bin ] && rsync -av ~/.local/bin/  "$BUNDLE/home-local-bin/"
```

- **Skip key:** `opt_outs.lane_b.home_bin`
- **Gotcha:** Custom hand-rolled scripts NOT tracked by any package manager — the most-overlooked migration item. Surface in audit log so user knows to commit these to chezmoi long-term.

### B5. /etc/hosts + sudoers.d

- **Commands:** `sudo cp /etc/hosts "$BUNDLE/manifests/etc-hosts" && sudo cp -r /etc/sudoers.d "$BUNDLE/manifests/sudoers.d/"`
- **Skip key:** `opt_outs.lane_b.system_files`
- **Gotcha:** macOS major upgrades reset /etc/hosts to default. /etc/sudoers.d files must be validated with `visudo -c -f` BEFORE activating on the new Mac — restore handles this.

## LANE C — Language Toolchains + Globals

Every C-lane command gated on `command -v <tool>` — silently skip with audit log entry if the tool isn't installed.

### C1. mise

```bash
[ -f ~/.tool-versions ] && cp ~/.tool-versions "$BUNDLE/manifests/.tool-versions"
[ -f ~/.config/mise/config.toml ] && cp ~/.config/mise/config.toml "$BUNDLE/manifests/mise-config.toml"
```

- **Skip key:** `opt_outs.lane_c.mise`
- **Gotcha:** Volta EOL'd Nov 2025. If user is still on nvm/pyenv/rbenv, migration is the moment to switch to mise — flag in audit log.

### C2. pipx

- **Command:** `pipx list --json > "$BUNDLE/manifests/pipx.json"` (gate on `command -v pipx`)
- **Skip key:** `opt_outs.lane_c.pipx`
- **Gotcha:** pipx envs are Python-version-locked. If restore lands on a different Python minor, some envs fail re-install.

### C3. npm globals

```bash
if command -v npm >/dev/null; then
  npm list -g --depth=0 --json > "$BUNDLE/manifests/npm-globals.json"
fi
if command -v pnpm >/dev/null; then
  pnpm list -g --depth=0 --json > "$BUNDLE/manifests/pnpm-globals.json"
fi
if command -v yarn >/dev/null; then
  yarn global list --json > "$BUNDLE/manifests/yarn-globals.json"
fi
```

- **Skip key:** `opt_outs.lane_c.node_globals`
- **Gotcha:** No native install-from-manifest in npm — restore parses the JSON and loops `npm install -g <pkg>` per dependency.

### C4. cargo

- **Command:** `cargo install --list > "$BUNDLE/manifests/cargo-installs.txt"` (gate on `command -v cargo`)
- **Skip key:** `opt_outs.lane_c.cargo`
- **Gotcha:** Restore uses `cargo-binstall` for ~80% speed boost via pre-built GitHub release binaries.

### C5. gem

- **Command:** `gem list > "$BUNDLE/manifests/gem-list.txt"` (gate on `command -v gem`)
- **Skip key:** `opt_outs.lane_c.gem`
- **Gotcha:** mise-managed Ruby has per-version gem dirs. If multi-version, capture per-version — but the default `gem list` reflects the active Ruby only.

### C6. go bin

- **Command:** `ls -1 "$(go env GOPATH)/bin" > "$BUNDLE/manifests/go-bin.txt"` (gate on `command -v go`)
- **Skip key:** `opt_outs.lane_c.go`
- **Gotcha:** Go has no install-from-list. The captured filenames are the executable names, not import paths — user re-installs manually with `go install <path>@latest`. Flag in audit log.

### C7. composer

- **Command:** `composer global show --format=json > "$BUNDLE/manifests/composer-globals.json"` (gate on `command -v composer`)
- **Skip key:** `opt_outs.lane_c.composer`
- **Gotcha:** Restore loops `composer global require <pkg>` per entry.

## LANE D — GUI App Configs

### D1. defaults plists

```bash
mkdir -p "$BUNDLE/defaults"
for domain in $(defaults domains | tr ',' '\n' | sed 's/^ *//'); do
  defaults export "$domain" "$BUNDLE/defaults/${domain}.plist" 2>/dev/null || true
done
```

- **Skip key:** `opt_outs.lane_d.defaults`
- **Gotcha:** `cfprefsd` caches in memory — restore needs `killall cfprefsd` AFTER imports or apps overwrite. Sandboxed apps' prefs live in Containers and `defaults export` won't reach those (see D3).

### D2. Application Support (selective rsync)

```bash
rsync -av \
  --exclude='*Cache*' --exclude='*cache*' --exclude='Caches' \
  --exclude='*Logs*' --exclude='Crash Reports' \
  ~/Library/Application\ Support/ "$BUNDLE/AppSupport/"
```

- **Skip key:** `opt_outs.lane_d.app_support`
- **Gotcha:** NEVER bulk-copy wholesale — drags forward gigabytes of stale cache. Cloud-synced apps (1Password, Notion, Slack) don't need this — reinstall + login is faster.

### D3. Containers — DO NOT bulk capture

Lane D explicitly does NOT bulk-rsync `~/Library/Containers/`. macOS ACLs containers to the app's code signature + Team ID; copying to a new Mac with different signing context produces silent failures.

Only specific Container subdirs are captured per per-app playbook:

- **Stickies** — `rsync -av ~/Library/Containers/com.apple.Stickies/ "$BUNDLE/stickies/"` (still flagged as ACL-risk; restore-time advisory)
- **Notes** — iCloud sync handles; never copied locally
- **Mail** — `rsync -av ~/Library/Mail/ "$BUNDLE/mail/"` — this is the non-Container path; rules + signatures + smart mailboxes captured

See `../../references/per-app/messages.md` and `../../references/per-app/mail.md` for the load-bearing playbooks.

### D4. Fonts

- **Command:** `rsync -av ~/Library/Fonts/ "$BUNDLE/fonts/"`
- **Skip key:** `opt_outs.lane_d.fonts`
- **Gotcha:** System fonts in `/Library/Fonts` require sudo (rarely customized — skip by default unless `opt_outs.lane_d.system_fonts: false` is explicitly set).

### D5. Stickies, Mail

Handled inline above under D3. Skip keys: `opt_outs.lane_d.stickies`, `opt_outs.lane_d.mail`.

## LANE E — Browsers

### E1. Chrome

```bash
chrome_ext_dir="$HOME/Library/Application Support/Google/Chrome/Default/Extensions"
[ -d "$chrome_ext_dir" ] && ls -1 "$chrome_ext_dir" > "$BUNDLE/browsers/chrome-extensions.txt"
```

- **Skip key:** `opt_outs.lane_e.chrome`
- **Gotcha:** Account sync handles bookmarks/extensions/passwords on the new Mac. The extension ID list is a cross-check + manual fallback only.

### E2. Brave / Edge

Same pattern as Chrome — extension lists only, account sync handles the rest.

### E3. Firefox

```bash
ff_profiles="$HOME/Library/Application Support/Firefox/Profiles"
if [ -d "$ff_profiles" ]; then
  if pgrep -x firefox >/dev/null; then
    "$AUDIT" lane-e firefox warn "Firefox is RUNNING — profile copy may be inconsistent. Quit Firefox and re-run."
  fi
  rsync -av "$ff_profiles/" "$BUNDLE/browsers/firefox-profiles/"
fi
```

- **Skip key:** `opt_outs.lane_e.firefox`
- **Gotcha:** Firefox MUST be quit. Warn loudly; continue but flag the result.

### E4. Safari

```bash
[ -f "$HOME/Library/Safari/Bookmarks.plist" ] && cp "$HOME/Library/Safari/Bookmarks.plist" "$BUNDLE/browsers/safari-bookmarks.plist"
```

- **Skip key:** `opt_outs.lane_e.safari`
- **Gotcha:** Safari on Ventura+ needs Full Disk Access for any script to read Bookmarks.plist. Restore must land this before first Safari launch.

### E5. Arc

```bash
arc_dir="$HOME/Library/Application Support/Arc"
if [ -d "$arc_dir" ]; then
  ls -1 "$arc_dir" > "$BUNDLE/browsers/arc-state.txt"
fi
```

Account-sync-based — Arc reconstructs from server. Skip key: `opt_outs.lane_e.arc`.

## LANE F — IDEs + Terminals

### F1. VS Code

```bash
if command -v code >/dev/null; then
  code --list-extensions > "$BUNDLE/ides/vscode-extensions.txt"
fi
vscode_user="$HOME/Library/Application Support/Code/User"
if [ -d "$vscode_user" ]; then
  mkdir -p "$BUNDLE/ides/vscode"
  cp -p "$vscode_user/settings.json"    "$BUNDLE/ides/vscode/" 2>/dev/null || true
  cp -p "$vscode_user/keybindings.json" "$BUNDLE/ides/vscode/" 2>/dev/null || true
  [ -d "$vscode_user/snippets" ] && rsync -av "$vscode_user/snippets/" "$BUNDLE/ides/vscode/snippets/"
fi
```

- **Skip key:** `opt_outs.lane_f.vscode`
- **Gotcha:** If Settings Sync was enabled, this is partially redundant — but capture anyway for offline-restore safety.

### F2. Cursor

Same shape as VS Code, paths swapped. Extension marketplace partially diverges from VS Code's — some extensions fail to re-install. Manual fallback: copy `~/.vscode/extensions/<id>` directly (covered in restore).

```bash
if command -v cursor >/dev/null; then
  cursor --list-extensions > "$BUNDLE/ides/cursor-extensions.txt"
fi
cursor_user="$HOME/Library/Application Support/Cursor/User"
if [ -d "$cursor_user" ]; then
  mkdir -p "$BUNDLE/ides/cursor"
  cp -p "$cursor_user/settings.json"    "$BUNDLE/ides/cursor/" 2>/dev/null || true
  cp -p "$cursor_user/keybindings.json" "$BUNDLE/ides/cursor/" 2>/dev/null || true
  [ -d "$cursor_user/snippets" ] && rsync -av "$cursor_user/snippets/" "$BUNDLE/ides/cursor/snippets/"
fi
```

### F3. Zed, Nvim, Emacs

Config-dir copies — these are normally in dotfiles, but capture as backup:

```bash
[ -d ~/.config/zed ]      && rsync -av ~/.config/zed/      "$BUNDLE/ides/zed/"
[ -d ~/.config/nvim ]     && rsync -av ~/.config/nvim/     "$BUNDLE/ides/nvim/"
[ -d ~/.emacs.d ]         && rsync -av ~/.emacs.d/         "$BUNDLE/ides/emacs/"
[ -d ~/.config/emacs ]    && rsync -av ~/.config/emacs/    "$BUNDLE/ides/emacs/"
```

Skip keys: `opt_outs.lane_f.{zed,nvim,emacs}`.

### F4. JetBrains

```bash
jb="$HOME/Library/Application Support/JetBrains"
[ -d "$jb" ] && rsync -av "$jb/" "$BUNDLE/ides/jetbrains/"
```

- **Skip key:** `opt_outs.lane_f.jetbrains`
- **Gotcha:** Configs embed absolute paths (SDK roots, project paths). Restore-time fix via `File > Project Structure` — flag in audit log.

### F5. Terminals

```bash
[ -f "$HOME/Library/Preferences/com.googlecode.iterm2.plist" ] \
  && cp -p "$HOME/Library/Preferences/com.googlecode.iterm2.plist" "$BUNDLE/ides/iterm2.plist"
warp="$HOME/Library/Application Support/dev.warp.Warp-Stable"
[ -d "$warp" ] && rsync -av \
  --exclude='Cache*' --exclude='*cache*' --exclude='Logs' \
  "$warp/" "$BUNDLE/ides/warp/"
[ -f ~/.config/ghostty/config ]            && cp -p ~/.config/ghostty/config            "$BUNDLE/ides/ghostty-config"
[ -f ~/.config/alacritty/alacritty.toml ]  && cp -p ~/.config/alacritty/alacritty.toml  "$BUNDLE/ides/alacritty.toml"
[ -f ~/.config/kitty/kitty.conf ]          && cp -p ~/.config/kitty/kitty.conf          "$BUNDLE/ides/kitty.conf"
```

Skip keys: `opt_outs.lane_f.{iterm2,warp,ghostty,alacritty,kitty}`.

## LANE G — Databases + Containers

Each sub-module gated on its tool. Heavy users — these are the most failure-prone captures, so verbose logging matters.

### G1. Postgres

Calls into [../../references/per-app/postgres.md](../../references/per-app/postgres.md) for the portable vs raw-data-dir decision.

```bash
if command -v pg_dumpall >/dev/null; then
  mkdir -p "$BUNDLE/databases"
  "$AUDIT" lane-g postgres start "Running pg_dumpall (portable mode)"
  pg_dumpall -U postgres > "$BUNDLE/databases/postgres-all.sql" 2>"$BUNDLE/databases/postgres-dump.log" || \
    "$AUDIT" lane-g postgres fail "pg_dumpall failed; see databases/postgres-dump.log"
fi
```

- **Skip key:** `opt_outs.lane_g.postgres`
- **Gotcha:** Requires Postgres running. Restore uses `psql -U postgres -f postgres-all.sql` against fresh install. Cross-major: see playbook for `pg_upgrade`. Extensions (pgvector, postgis) must be reinstalled separately.

### G2. MySQL

```bash
if command -v mysqldump >/dev/null; then
  mysqldump --all-databases > "$BUNDLE/databases/mysql-all.sql"
fi
```

Skip key: `opt_outs.lane_g.mysql`.

### G3. Redis

```bash
redis_dump=/opt/homebrew/var/db/redis/dump.rdb
[ -f "$redis_dump" ] && cp -p "$redis_dump" "$BUNDLE/databases/redis-dump.rdb"
```

Skip key: `opt_outs.lane_g.redis`. Gotcha: file may be locked while Redis is running — restore may need `brew services stop redis` before copying for cleanest state.

### G4. MongoDB

```bash
if command -v mongodump >/dev/null; then
  mongodump --out "$BUNDLE/databases/mongodb-dump/"
fi
```

Skip key: `opt_outs.lane_g.mongo`.

### G5. Docker

Calls into [../../references/per-app/docker.md](../../references/per-app/docker.md) — load-bearing rule: never copy Group Containers.

```bash
if [ -d ~/.docker ]; then
  rsync -av ~/.docker/ "$BUNDLE/docker/"
  "$AUDIT" lane-g docker info "Captured ~/.docker/ only. Group Containers intentionally excluded — see per-app/docker.md."
fi
```

- **Skip key:** `opt_outs.lane_g.docker`
- **Gotcha:** `~/Library/Group Containers/group.com.docker/` and `~/Library/Containers/com.docker.docker/` MUST NOT be captured. Migration Assistant doing this is the #1 cause of broken Docker on new Macs. Audit log records the deliberate skip.

### G6/G7. Kubernetes + Helm

```bash
[ -f ~/.kube/config ] && cp -p ~/.kube/config "$BUNDLE/manifests/kubeconfig"
command -v kubectl >/dev/null && kubectl krew list > "$BUNDLE/manifests/krew-plugins.txt" 2>/dev/null || true
command -v helm    >/dev/null && helm repo list      > "$BUNDLE/manifests/helm-repos.txt"  2>/dev/null || true
```

Skip keys: `opt_outs.lane_g.{k8s,helm}`. Gotcha: krew binaries are platform-specific — reinstall, never copy.

## LANE H — Background Services

### H1. User LaunchAgents

```bash
[ -d ~/Library/LaunchAgents ] && rsync -av ~/Library/LaunchAgents/ "$BUNDLE/launchd/user-LaunchAgents/"
```

Skip key: `opt_outs.lane_h.user_agents`. Gotcha: plist `ProgramArguments` paths must exist on new Mac — restore verifies after Brewfile + chezmoi apply.

### H2. System LaunchAgents + LaunchDaemons

```bash
sudo cp -R /Library/LaunchAgents  "$BUNDLE/launchd/system-LaunchAgents"
sudo cp -R /Library/LaunchDaemons "$BUNDLE/launchd/system-LaunchDaemons"
```

Skip key: `opt_outs.lane_h.system_daemons`. Gotcha: macOS Tahoe (26) tightens SIP on `/Library/LaunchDaemons` — custom daemons may need SMAppService rewrite. Restore surfaces advisory.

### H3. launchctl list snapshot

```bash
launchctl list > "$BUNDLE/launchd/launchctl-list.txt"
```

Skip key: `opt_outs.lane_h.launchctl_list`. The current running-state — distinct from the on-disk plists.

### H4. brew services state

Already captured in Lane A2 — re-emit here under launchd/ for completeness:

```bash
brew services list > "$BUNDLE/manifests/brew-services-running.txt"
```

### H5. PM2

```bash
if command -v pm2 >/dev/null; then
  pm2 save
  [ -f ~/.pm2/dump.pm2 ] && cp -p ~/.pm2/dump.pm2 "$BUNDLE/manifests/pm2-dump.pm2"
fi
```

Skip key: `opt_outs.lane_h.pm2`.

### H6. cron

```bash
crontab -l > "$BUNDLE/manifests/user-crontab.txt"     2>/dev/null || true
sudo crontab -l > "$BUNDLE/manifests/root-crontab.txt" 2>/dev/null || true
```

Skip key: `opt_outs.lane_h.cron`. Gotcha: `/var/at/tabs/` is wiped on clean install — explicit capture is mandatory. Empty crontab returns non-zero; tolerate with `|| true`.

### H7. Login Items

```bash
osascript -e 'tell application "System Events" to get the name of every login item' \
  > "$BUNDLE/manifests/login-items.txt" 2>/dev/null || true
```

Skip key: `opt_outs.lane_h.login_items`. Gotcha: AppleScript misses SMAppService apps. List is INCOMPLETE — audit log flags this.

### H8. Launchpad layout (optional)

```bash
if command -v lporg >/dev/null; then
  lporg save -c "$BUNDLE/manifests/launchpad-layout.yml" || \
    "$AUDIT" lane-h launchpad warn "lporg save failed — known reliability issue with folder recreation"
fi
```

Skip key: `opt_outs.lane_h.launchpad`. Gotcha: `lporg` archived 2025-09-19. Many power users opt out and use Spotlight/Raycast instead.

## LANE I — Credentials + Auth (encrypted)

All credential captures land in a working `$BUNDLE/credentials/` dir. After all sub-modules complete, `encrypt_creds.sh seal` GPG-seals + shreds.

### I1. SSH

```bash
[ -d ~/.ssh ] && rsync -av ~/.ssh/ "$BUNDLE/credentials/ssh/"
```

Skip key: `opt_outs.lane_i.ssh`. Restore reapplies `chmod 700 ~/.ssh && chmod 600 ~/.ssh/*` — SSH refuses keys with wrong perms.

### I2. GPG

```bash
[ -d ~/.gnupg ] && rsync -av ~/.gnupg/ "$BUNDLE/credentials/gnupg/"
gpg --export-secret-keys -a > "$BUNDLE/credentials/gpg-secret.asc" 2>/dev/null || true
gpg --export-ownertrust    > "$BUNDLE/credentials/gpg-trust.txt"   2>/dev/null || true
```

Skip key: `opt_outs.lane_i.gpg`. NOTE: encrypt_creds.sh seals using this same GPG key — there's a chicken-and-egg if the user wants to encrypt with the very key being captured. Restore-time the GPG key needs separate sideband transfer (e.g. YubiKey) and import BEFORE unseal. Audit log surfaces this.

### I3. Cloud CLIs

```bash
[ -d ~/.aws ]              && rsync -av ~/.aws/              "$BUNDLE/credentials/aws/"
[ -d ~/.config/gcloud ]    && rsync -av ~/.config/gcloud/    "$BUNDLE/credentials/gcloud/"
[ -d ~/.azure ]            && rsync -av ~/.azure/            "$BUNDLE/credentials/azure/"
[ -d ~/.cloudflared ]      && rsync -av ~/.cloudflared/      "$BUNDLE/credentials/cloudflared/"
[ -d ~/.config/doctl ]     && rsync -av ~/.config/doctl/     "$BUNDLE/credentials/doctl/"
[ -d ~/.config/linode-cli ] && rsync -av ~/.config/linode-cli/ "$BUNDLE/credentials/linode-cli/"
```

Skip key: `opt_outs.lane_i.cloud_clis`. Gotcha: gcloud OAuth tokens expire in ~1h; usually need `gcloud auth login` on new Mac regardless. AWS SSO same. Static keys clean.

### I4. git + gh + language-package tokens

```bash
mkdir -p "$BUNDLE/credentials/git"
for f in ~/.gitconfig ~/.gitconfig.local ~/.gitignore_global; do
  [ -f "$f" ] && cp -p "$f" "$BUNDLE/credentials/git/"
done
[ -f ~/.config/gh/hosts.yml ] && \
  mkdir -p "$BUNDLE/credentials/gh" && cp -p ~/.config/gh/hosts.yml "$BUNDLE/credentials/gh/"

mkdir -p "$BUNDLE/credentials/lang-tokens"
[ -f ~/.npmrc ]                       && cp -p ~/.npmrc                       "$BUNDLE/credentials/lang-tokens/"
[ -f ~/.cargo/credentials.toml ]      && cp -p ~/.cargo/credentials.toml      "$BUNDLE/credentials/lang-tokens/"
[ -f ~/.gem/credentials ]             && cp -p ~/.gem/credentials             "$BUNDLE/credentials/lang-tokens/"
[ -f ~/.config/composer/auth.json ]   && cp -p ~/.config/composer/auth.json   "$BUNDLE/credentials/lang-tokens/"
[ -f ~/.pypirc ]                      && cp -p ~/.pypirc                      "$BUNDLE/credentials/lang-tokens/"
[ -f ~/.huggingface/token ]           && cp -p ~/.huggingface/token           "$BUNDLE/credentials/lang-tokens/"
[ -f ~/.netrc ]                       && cp -p ~/.netrc                       "$BUNDLE/credentials/lang-tokens/"
```

Skip key: `opt_outs.lane_i.git_and_tokens`. Gotcha: npm classic tokens revoked Nov-Dec 2025. If `.npmrc` has `_authToken=`, that token is DEAD — audit log flags for regeneration before relying on bundle.

### I5. WireGuard

```bash
if [ -d /etc/wireguard ]; then
  sudo cp -r /etc/wireguard "$BUNDLE/credentials/wireguard/"
fi
```

Skip key: `opt_outs.lane_i.wireguard`. App Store WireGuard uses Group Containers — handled separately via GUI export (Lane J manual checklist).

### I6. SEAL

After all sub-modules:

```bash
bash "$SKILL_DIR/scripts/encrypt_creds.sh" seal
```

This tars + gzips + GPG-encrypts `$BUNDLE/credentials/` → `$BUNDLE/credentials/credentials.tar.gz.gpg`, then shreds the unencrypted source. Audit log records the GPG recipient ID. Full mechanics in [../../references/encryption-flow.md](../../references/encryption-flow.md).

Only AFTER successful seal does the script write `.done/lane-i-creds`.

## Package step

After all 9 lanes complete (or are skipped via opt-out), `package_bundle.sh`:

1. Iterates manifest.json's `opt_outs` list and verifies each non-opted-out lane has a `.done` marker. If any are missing, exits with a clear error pointing at the broken lane.
2. Walks `$BUNDLE/` and computes SHA256 per file → `manifest.sha256`.
3. If `--tarball` flag: rolls up into `migration-bundle.tar.zst` using zstd (high ratio, fast decompress on target). Tarball goes ABOVE the bundle dir so the user can move just the one file.
4. Prints final summary: lanes captured, lanes skipped, total bundle size, tarball size if applicable, exact paths, and recommended next step (transfer to new Mac, then route to `restore` sub-skill).

The summary is the user-facing payoff. Surface it clearly. The audit log captures everything machine-readable.
