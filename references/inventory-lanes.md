# Mac Migration — Master Inventory

**Generated:** 2026-05-22
**Sources:** Lane files 01–05 + INVENTORY-GAPS.md (18 blind-spot sections)
**Purpose:** Single centralized inventory of every item, path, config file, and background process a power user migrates from Mac → Mac. Becomes the spec the Claude skill will plan against.

---

## Skill UX — Choose-Your-Own-Adventure

```
USER:    "Hey, I'm about to move everything to a new Mac."

SKILL:   [Phase 1 — quick scan, ~60s]
         Found:
           Lane A. 87 brew formulae + 24 casks + 6 App Store apps + 3 orphan apps
           Lane B. 5 dotfiles dirs + custom PATH (3 entries in /etc/paths.d) + 12 scripts in ~/bin
           Lane C. mise (.tool-versions: node 22, python 3.13, ruby 3.4, go 1.24)
                  pipx (14 envs), npm globals (8), cargo (6), gem (4), go bin (3)
           Lane D. 234 defaults domains, 89 dirs in Application Support, 47 in Containers
                  219 user fonts
           Lane E. Chrome (signed in), Safari (iCloud), Firefox (profile), Arc
           Lane F. VS Code (47 extensions), Cursor, Zed, iTerm2, Warp
           Lane G. Postgres 16 (4 DBs, 3.2 GB), Redis (12 MB), Docker (47 contexts)
           Lane H. 8 user LaunchAgents, 2 brew services running, 0 cron, 3 PM2 services, 12 Login Items
           Lane I. AWS (2 profiles), GCP (1 acct), git config, 6 CLI tokens

         These will be migrated. Anything you DON'T want me to handle?

USER:    "Skip Launchpad layout, skip stickies, skip Notes — and I'll redo TCC manually."

SKILL:   Got it. Phase 2 — capturing to ~/migration-bundle/. Streaming progress…
```

The skill maps user opt-outs to lane/sub-module flags. CAPTURE.sh + RESTORE.sh are parameterized by those flags.

---

## Module Map (10 Lanes, ~40 Sub-Modules)

| Lane | Theme | Sub-modules | Tool that helps |
|---|---|---|---|
| **A** | Applications | Brewfile, MAS, orphan apps | `brew bundle`, `mas-cli` |
| **B** | Shell + PATH + Custom scripts | dotfiles, rc files, /etc/paths.d, ~/bin, /etc/hosts, sudoers.d | `chezmoi` |
| **C** | Language toolchains + globals | mise, pipx, npm, cargo, gem, go, composer | `mise`, `pipx`, `cargo-binstall` |
| **D** | GUI app configs | defaults plists, Application Support, Containers, fonts, Stickies/Notes/Mail | `macprefs`, `brokosz/macos-defaults` |
| **E** | Browsers | Chrome, Firefox, Safari, Arc, Brave, Edge | account sync + per-browser import |
| **F** | IDEs + Terminals | VS Code/Cursor, Zed, JetBrains, Nvim/Emacs, iTerm2/Warp/Ghostty | `code --list-extensions`, dotfiles |
| **G** | Databases + Containers | Postgres, MySQL, Redis, Mongo, Docker, k8s, krew, helm | `pg_dumpall`, `kubectl krew` |
| **H** | Background services | user LaunchAgents, system LaunchDaemons, brew services, PM2, cron, Login Items, Launchpad | `launchctl`, `pm2 save`, `lporg` (archived) |
| **I** | Credentials + Auth | git/gh, AWS/GCP/Azure/CF/DO, CLI tokens, SSH, GPG, WireGuard | direct copy + re-auth |
| **J** | Manual / Deferred | iCloud Keychain, app licenses, TCC, Time Machine, Spotlight, WiFi | user re-prompt |

---

## LANE A — Applications

### A1. Brewfile (formulae + casks + taps)

- **What:** Homebrew packages — CLI tools, GUI apps via casks, taps
- **Path:** `/opt/homebrew/` (Apple Silicon) or `/usr/local/` (Intel)
- **Capture:** `brew bundle dump --force --describe --file=~/migration-bundle/Brewfile`
- **Restore:** `brew bundle --file=~/migration-bundle/Brewfile`
- **Gotchas:** `brew bundle dump` captures the INSTALLED state, not the RUNNING state (see H3). Casks include macOS App Store IDs if `mas-cli` is present.
- **Tool:** `brew bundle` (built-in)

### A2. Mac App Store apps (mas-cli)

- **What:** Paid + free App Store apps tied to Apple ID
- **Capture:** `mas list > ~/migration-bundle/manifests/mas-installed.txt`
- **Restore:** Apps appear in Brewfile as `mas "AppName", id: 123456`. On the new Mac: sign in to App Store first, then `brew bundle` re-installs them.
- **Gotchas:** `mas install <id>` only re-downloads previously purchased apps. On a fresh Apple ID, prefer `mas get <id>` (handles both purchased and free). [Open Homebrew issue tracks this.](https://github.com/Homebrew/homebrew-bundle/issues/371)
- **Tool:** `mas-cli/mas`

### A3. Manual / orphan apps (dropped DMGs, npm-installed Electron, etc.)

- **What:** Apps NOT in Brewfile or MAS — installed by dragging to `/Applications`, downloaded directly, or installed by other package managers
- **Capture:** `system_profiler SPApplicationsDataType -json > ~/migration-bundle/manifests/system-apps.json`
- **Restore:** Manual — surface the diff between `system-apps.json` and Brewfile + mas list, ask user how to handle each.
- **Gotchas:** Orphan list often includes apps that COULD be in Brewfile (Hunter forgot to add them). The skill should suggest `brew search <appname>` for each orphan and offer to add it to Brewfile retroactively.

---

## LANE B — Shell + PATH + Custom Scripts

### B1. Dotfiles (chezmoi)

- **What:** `~/.zshrc`, `~/.zprofile`, `~/.zshenv`, `~/.gitconfig`, `~/.ssh/config`, `~/.tmux.conf`, etc.
- **Path:** `~/` (top-level dotfiles) + `~/.config/`
- **Capture:** Versioned in a chezmoi repo (e.g., `~/.local/share/chezmoi/`); push to GitHub
- **Restore:** `chezmoi init --apply <repo-url>`
- **Gotchas:** Mackup is broken on Sonoma+ — DO NOT use. chezmoi is the canonical choice. `run_once_*` scripts in chezmoi can trigger `brew bundle` automatically on `chezmoi apply`.
- **Tool:** `twpayne/chezmoi`

### B2. Shell rc / profile / env files (not yet in dotfiles)

- **What:** Anything in `~/.zshrc` etc. that's not version-controlled yet — discover BEFORE migration
- **Capture:** `cp ~/.zshrc ~/.zprofile ~/.zshenv ~/.bashrc ~/.bash_profile ~/migration-bundle/dotfiles-refs/ 2>/dev/null`
- **Restore:** Move into chezmoi repo as part of migration prep, not on the new Mac
- **Gotchas:** `path_helper` (macOS) runs from `/etc/zprofile` and reorders PATH if you set entries in `~/.zshenv` instead of `~/.zshrc`. Tool precedence breaks silently.

### B3. /etc/paths and /etc/paths.d/

- **What:** System-level PATH extensions (homebrew adds an entry here on install)
- **Capture:** `sudo cp /etc/paths ~/migration-bundle/manifests/etc-paths.txt && sudo cp -R /etc/paths.d ~/migration-bundle/manifests/etc-paths.d`
- **Restore:** `sudo cp ~/migration-bundle/manifests/etc-paths.txt /etc/paths && sudo cp -R ~/migration-bundle/manifests/etc-paths.d /etc/`
- **Gotchas:** Order matters — earlier paths take precedence. Some apps (Postgres.app, Visual Studio) install drop-ins here.

### B4. ~/bin and ~/.local/bin custom scripts

- **What:** Hand-rolled scripts NOT tracked by any package manager — the invisible gap
- **Capture:** `[ -d ~/bin ] && cp -R ~/bin ~/migration-bundle/home-bin; [ -d ~/.local/bin ] && cp -R ~/.local/bin ~/migration-bundle/home-local-bin`
- **Restore:** rsync back, `chmod +x` each
- **Gotchas:** Long-term solution is to commit these to the chezmoi dotfile repo. Migration is the moment to do that.

### B5. /etc/hosts + /etc/sudoers.d/

- **What:** Custom hostname → IP mappings (dev domains, ad blockers); passwordless sudo rules
- **Capture:** `sudo cp /etc/hosts ~/migration-bundle/manifests/etc-hosts && sudo cp -r /etc/sudoers.d ~/migration-bundle/manifests/sudoers.d`
- **Restore:** Copy back; validate sudoers with `sudo visudo -c -f /etc/sudoers.d/<file>` BEFORE activating
- **Gotchas:** `/etc/hosts` resets on major macOS upgrades — check after every OS update. `/etc/pf.conf` (packet filter) also resets.

---

## LANE C — Language Toolchains + Global Packages

### C1. mise (`.tool-versions`)

- **What:** Replaces nvm, fnm, pyenv, rbenv, asdf, Volta in one binary. Manages node, python, ruby, go, rust, java, etc.
- **Capture:** `cp ~/.tool-versions ~/migration-bundle/manifests/.tool-versions && cp ~/.config/mise/config.toml ~/migration-bundle/manifests/mise-config.toml 2>/dev/null`
- **Restore:** `brew install mise && cp ~/migration-bundle/manifests/.tool-versions ~/ && mise install`
- **Gotchas:** Volta was EOL'd Nov 2025; GitLab made mise mandatory July 2025. Migrate to mise on the OLD machine BEFORE backup if not already there.
- **Tool:** `jdx/mise`

### C2. pipx (Python CLIs)

- **What:** Isolated Python CLI installs (the only Python tool with a clean round-trip)
- **Capture:** `pipx list --json > ~/migration-bundle/manifests/pipx.json`
- **Restore:** `pipx install-all ~/migration-bundle/manifests/pipx.json` (or loop with `jq -r '.venvs | keys[]' | xargs -n1 pipx install`)
- **Gotchas:** pipx envs are Python-version-locked. If mise restores a different Python minor version, some envs may fail re-install.
- **Tool:** `pypa/pipx`

### C3. npm globals

- **What:** Global npm packages (`-g` flag)
- **Capture:** `npm list -g --depth=0 --json > ~/migration-bundle/manifests/npm-globals.json`
- **Restore:** `jq -r '.dependencies | keys[]' npm-globals.json | grep -v '^npm$' | xargs -n1 npm install -g`
- **Gotchas:** No native round-trip. Some globals are actually local-only (Volta legacy); audit before assuming.

### C4. cargo + cargo-binstall (Rust CLIs)

- **What:** Globally-installed Rust binaries
- **Capture:** `cargo install --list > ~/migration-bundle/manifests/cargo-installs.txt`
- **Restore:** `cargo install cargo-binstall && awk '/^[a-z0-9_-]+ v/ {print $1}' cargo-installs.txt | xargs -I{} cargo binstall -y {}`
- **Gotchas:** `cargo-binstall` pulls pre-built GitHub release binaries (80%+ faster than recompile). Falls back to source compile if no binary exists.
- **Tool:** `cargo-bins/cargo-binstall`

### C5. gem (Ruby globals)

- **Capture:** `gem list > ~/migration-bundle/manifests/gem-list.txt`
- **Restore:** Parse + `gem install` each
- **Gotchas:** mise-managed Ruby has its own gem dirs per-version — capture per-version if multi-version

### C6. go bin

- **Capture:** `ls -1 $(go env GOPATH)/bin > ~/migration-bundle/manifests/go-bin.txt`
- **Restore:** Manual `go install` for each (Go has no install-from-list); record the import path of each `go install <path>@latest` invocation when first installed

### C7. composer globals (PHP)

- **Capture:** `composer global show --format=json > ~/migration-bundle/manifests/composer-globals.json`
- **Restore:** Loop `composer global require <pkg>`

---

## LANE D — GUI App Configs

### D1. macOS `defaults` plist database

- **What:** All app + system preferences (~200+ domains typical)
- **Capture:** Loop `defaults export <domain> ~/migration-bundle/defaults/<domain>.plist` for each `defaults domains` entry
- **Restore:** Loop `defaults import <domain> <plist>`
- **Gotchas:** `cfprefsd` caches in memory — `killall cfprefsd` after writes, or apps may overwrite your imports. Sandboxed apps' prefs live in `~/Library/Containers/<bundle>/Data/Library/Preferences/` and `defaults import` won't reach those.
- **Tool:** `clintmod/macprefs`, `brokosz/macos-defaults`

### D2. ~/Library/Application Support (selective)

- **What:** Per-app local data — Raycast snippets, VS Code state, Slack cache, etc.
- **Capture:** `rsync -av --exclude='*Cache*' ~/Library/Application\ Support/ ~/migration-bundle/AppSupport/`
- **Restore:** `rsync -av ~/migration-bundle/AppSupport/ ~/Library/Application\ Support/`
- **Gotchas:** Do NOT bulk-copy wholesale — carry forward gigabytes of stale cache. Cloud-synced apps (1Password, Notion, Slack) don't need this — reinstall + login.

### D3. ~/Library/Containers + Group Containers (sandboxed apps)

- **What:** Mac App Store + sandboxed apps' data
- **Path:** `~/Library/Containers/<BundleID>/Data/`, `~/Library/Group Containers/<group>/`
- **Capture/Restore:** Per-app, NOT bulk. Use each app's own export/import.
- **Gotchas:** **macOS ACLs containers to the app's code signature + Team ID.** Copying containers to a new Mac with a different signing context produces silent failures or "different app wants to access this container" warnings. Safest approach: let each app re-create its container on first launch, then import via the app's native export.

### D4. Fonts

- **What:** `~/Library/Fonts` (user) + `/Library/Fonts` (system, admin required)
- **Capture:** `rsync -av ~/Library/Fonts/ ~/migration-bundle/user-fonts/`
- **Restore:** `rsync -av ~/migration-bundle/user-fonts/ ~/Library/Fonts/ && sudo atsutil databases -remove` then reboot
- **Gotchas:** Migration Assistant sometimes misses fonts. Font Book > File > Validate Fonts catches corrupted ones.

### D5. Stickies + Notes (local) + Mail rules

- **Stickies:** `~/Library/Containers/com.apple.Stickies/Data/Library/Stickies/` (Catalina+: individual RTF files, no more monolithic `StickiesDatabase`)
- **Notes (local):** `~/Library/Group Containers/group.com.apple.notes/` — iCloud sync handles this if signed in
- **Mail rules + signatures:** `~/Library/Mail/V<n>/MailData/SyncedRules.plist` + `Signatures/` (V number bumps with macOS — verify after migration)

---

## LANE E — Browsers

| Browser | Profile path | Migration |
|---|---|---|
| Chrome | `~/Library/Application Support/Google/Chrome/Default/` | Sign into Google account; sync handles bookmarks/extensions/passwords. List extension IDs: `ls ~/Library/Application\ Support/Google/Chrome/Default/Extensions/` |
| Brave | `~/Library/Application Support/BraveSoftware/Brave-Browser/Default/` | Brave Sync in Settings (more reliable than manual copy) |
| Firefox | `~/Library/Application Support/Firefox/Profiles/<hash>.default-release/` | **Quit Firefox**, copy `Profiles/` dir wholesale |
| Safari | `~/Library/Safari/` + `~/Library/Containers/com.apple.Safari/` (sandboxed) | iCloud sync; or copy `Bookmarks.plist` before first launch |
| Arc | `~/Library/Application Support/Arc/` | Use Arc's built-in `Import from Another Browser` |
| Edge | `~/Library/Application Support/Microsoft Edge/Default/` | Microsoft account sync |

**Gotcha:** Safari on Ventura+ needs Full Disk Access for any script reading `Bookmarks.plist`. Restore before first Safari launch.

---

## LANE F — IDEs + Terminals

### F1. VS Code / Cursor

- **Settings:** `~/Library/Application Support/Code/User/settings.json` (Cursor uses `Cursor/User/`)
- **Keybindings:** `keybindings.json` in same dir
- **Extensions list:** `code --list-extensions > vscode-extensions.txt`
- **Restore extensions:** `cat vscode-extensions.txt | xargs -I {} code --install-extension {}`
- **Gotcha:** Cursor uses a different extension marketplace from VS Code; some extensions fail. Manual copy of `~/.vscode/extensions/<id>` is the fallback. Settings Sync (built-in, syncs to GitHub Gist) is cleanest if already enabled.

### F2. Zed

- **Config:** `~/.config/zed/settings.json` — in dotfiles
- **Migration:** Command Palette > `zed: import vs code settings`

### F3. JetBrains (IntelliJ, PyCharm, WebStorm, etc.)

- **Config:** `~/Library/Application Support/JetBrains/<IDE><version>/`
- **Capture:** `rsync -av ~/Library/Application\ Support/JetBrains/ ~/migration-bundle/jetbrains/`
- **Gotcha:** Configs embed absolute paths (SDK roots, project paths) — fix via `File > Project Structure` after restore.

### F4. Neovim / Emacs

- **Neovim:** `~/.config/nvim/` — fully in dotfiles
- **Emacs:** `~/.emacs.d/` or `~/.config/emacs/` — fully in dotfiles

### F5. Terminals

| Terminal | Config |
|---|---|
| iTerm2 | `~/Library/Preferences/com.googlecode.iterm2.plist` (binary plist, `plutil -convert xml1` to edit). Cleaner: `Preferences > General > Preferences > Load preferences from custom folder` → point to dotfile repo |
| Warp | `~/Library/Application Support/dev.warp.Warp-Stable/` (has iTerm2 importer built-in) |
| Ghostty | `~/.config/ghostty/config` — dotfile |
| Alacritty | `~/.config/alacritty/alacritty.toml` — dotfile |
| Kitty | `~/.config/kitty/kitty.conf` — dotfile |

---

## LANE G — Databases + Containers

### G1. Postgres

- **Data dir:** `/opt/homebrew/var/postgresql@<n>/`
- **Capture (portable):** Stop service, then `pg_dumpall -U postgres > ~/migration-bundle/postgres-all.sql`
- **Capture (fast, same-major-version only):** `rsync -avz /opt/homebrew/var/postgresql@17/ ~/migration-bundle/pg17-data/`
- **Restore:** `brew install postgresql@17 && brew services start postgresql@17 && psql -U postgres -f ~/migration-bundle/postgres-all.sql`
- **Cross-major upgrade:** Use `pg_upgrade` (separate flow — see lane file 04)
- **Gotchas:** Homebrew NEVER touches the data dir on version upgrades. Extensions (`pgvector`, `postgis`) must be reinstalled on the new major: `brew reinstall pgvector`.

### G2. MySQL / MariaDB

- **Data dir:** `/opt/homebrew/var/mysql/`
- **Capture:** `mysqldump --all-databases > ~/migration-bundle/mysql-all.sql`
- **Restore:** Reinstall + `mysql < mysql-all.sql`

### G3. Redis

- **Data:** `/opt/homebrew/var/db/redis/dump.rdb`
- **Capture:** `cp /opt/homebrew/var/db/redis/dump.rdb ~/migration-bundle/redis-dump.rdb`
- **Restore:** Reinstall + copy dump back

### G4. MongoDB

- **Data:** `/opt/homebrew/var/mongodb/`
- **Capture:** `mongodump --out ~/migration-bundle/mongodb-dump/`
- **Restore:** `mongorestore ~/migration-bundle/mongodb-dump/`

### G5. Docker

- **Configs:** `~/.docker/` (contexts, credentials, daemon.json)
- **Capture:** `rsync -av ~/.docker/ ~/migration-bundle/docker/`
- **Restore:** Install Docker Desktop fresh, THEN copy `~/.docker/` back
- **Gotchas:** **DO NOT copy `~/Library/Group Containers/group.com.docker/` or `~/Library/Containers/com.docker.docker/`** — this is the known Migration Assistant failure mode that kills the daemon. Let Docker Desktop recreate these on first launch.

### G6. Kubernetes

- **Config:** `~/.kube/config` (or `$KUBECONFIG` colon-separated list)
- **Capture:** `cp ~/.kube/config ~/migration-bundle/kubeconfig`
- **Restore:** `mkdir -p ~/.kube && cp ~/migration-bundle/kubeconfig ~/.kube/config`
- **krew plugins:** `kubectl krew list > krew-plugins.txt` capture; reinstall plugins on new Mac
- **Gotchas:** krew binaries are platform-specific — reinstall, don't copy

### G7. Helm

- **Config:** `~/Library/Preferences/helm/` or `~/.config/helm/`
- **Capture:** `helm repo list > helm-repos.txt`
- **Restore:** Parse + `helm repo add <name> <url>` each

---

## LANE H — Background Services

### H1. User LaunchAgents

- **Path:** `~/Library/LaunchAgents/*.plist`
- **Capture:** `cp -R ~/Library/LaunchAgents ~/migration-bundle/launchd/user-LaunchAgents`
- **Restore:** Copy plists back, then `launchctl bootstrap gui/$(id -u) <plist>` for each
- **Gotchas:** Plist's `ProgramArguments` paths must exist on the new Mac. Verify after Brewfile + chezmoi apply.

### H2. System LaunchAgents + LaunchDaemons

- **Path:** `/Library/LaunchAgents/` + `/Library/LaunchDaemons/` (root-owned)
- **Capture:** `sudo cp -R /Library/LaunchAgents ~/migration-bundle/launchd/system-LaunchAgents && sudo cp -R /Library/LaunchDaemons ~/migration-bundle/launchd/system-LaunchDaemons`
- **Restore:** Manual — sudo + `launchctl bootstrap system <plist>`
- **Gotchas:** **macOS Tahoe (26) tightens SIP on `/Library/LaunchDaemons`.** Custom root-level daemons may need rewrite as `SMAppService`-based app-bundle helpers. Sandboxed apps can NO LONGER install non-sandboxed daemons (since macOS 14.2).

### H3. brew services running state

- **What:** Which services were actually RUNNING (vs just installed)
- **Capture:** `brew services list > ~/migration-bundle/manifests/brew-services-running.txt`
- **Restore:** `awk '$2=="started" {print $1}' brew-services-running.txt | xargs -n1 brew services start`
- **Gotchas:** `brew bundle dump` does NOT capture running state — separate snapshot required.

### H4. PM2 (Node services)

- **What:** Cleanest of any scheduled-task layer
- **Capture:** `pm2 save` → produces `~/.pm2/dump.pm2`, copy to bundle
- **Restore:** Copy `dump.pm2` back, `pm2 resurrect && pm2 startup`
- **Tool:** `Unitech/pm2`

### H5. cron

- **What:** Legacy scheduler (Apple deprecated but functional)
- **Capture:** `crontab -l > ~/migration-bundle/manifests/user-crontab.txt` (root: `sudo crontab -l`)
- **Restore:** `crontab ~/migration-bundle/manifests/user-crontab.txt`
- **Gotchas:** Cron does NOT survive a clean install — `/var/at/tabs/` is wiped. Migration Assistant may or may not copy it; explicit capture is safer.

### H6. Login Items + SMAppService

- **Legacy:** `osascript -e 'tell application "System Events" to get the name of every login item'` — incomplete (misses SMAppService apps)
- **Modern:** Apps registered via `SMAppService` re-register themselves on first launch on the new Mac — no manual step needed for those
- **Path (legacy store):** `/var/db/com.apple.xpc.launchd/loginitems.<uid>.plist`
- **Gotcha:** Listing is incomplete via any single mechanism. Lingon X (~$10 commercial) is the only tool that surfaces a complete view.

### H7. Launchpad layout (optional)

- **Tool:** `blacktop/lporg` — **ARCHIVED Sept 19, 2025** but still functional on macOS 26
- **Capture:** `lporg save -c ~/migration-bundle/launchpad-layout.yml`
- **Restore:** `lporg load -c ~/migration-bundle/launchpad-layout.yml` (kills + restarts Dock)
- **Gotchas:** Known reliability issues with folder recreation (issue #67). Most power users use Spotlight/Raycast and skip this entirely.

---

## LANE I — Credentials + Auth

### I1. Git + GitHub CLI

- **Files:** `~/.gitconfig`, `~/.gitconfig.local`, `~/.config/gh/hosts.yml`
- **Capture:** `cp ~/.gitconfig ~/migration-bundle/gitconfig && cp ~/.config/gh/hosts.yml ~/migration-bundle/gh-hosts.yml`
- **Restore:** Copy back, then `gh auth setup-git`
- **Gotchas:** `osxkeychain` credential helper data lives in Keychain — does NOT migrate with `~/.gitconfig`. Re-auth on new Mac. `gh auth setup-git` injects absolute path to `gh` binary (`/opt/homebrew/bin/gh`) — verify on new Mac.

### I2. Cloud CLIs

| CLI | Path | Transfer behavior |
|---|---|---|
| AWS | `~/.aws/credentials` + `~/.aws/config` | Static keys: clean. SSO: re-auth (`aws sso login`) |
| gcloud | `~/.config/gcloud/` | OAuth tokens expire (1h access / longer refresh). Often need `gcloud auth login` + `gcloud auth application-default login` |
| Azure | `~/.azure/` | Short-lived; `az login` always safer |
| Cloudflare | `~/.cloudflared/` | Tunnel `credentials.json` are long-lived; clean. Launch plist for auto-start needs re-register |
| DigitalOcean | `~/.config/doctl/` | Long-lived token; clean. Fallback: `doctl auth init` |

### I3. CLI tool auth tokens

| Tool | Path | Note |
|---|---|---|
| npm | `~/.npmrc` | **⚠ npm classic tokens REVOKED Nov–Dec 2025.** Old `_authToken` is dead. Generate new granular tokens before migration |
| Cargo | `~/.cargo/credentials.toml` | Long-lived; clean |
| Gem | `~/.gem/credentials` | Clean |
| Composer | `~/.config/composer/auth.json` | Clean |
| PyPI | `~/.pypirc` | Clean (API tokens) |
| HuggingFace | `~/.huggingface/token` | Clean |
| netrc | `~/.netrc` | Audit before copying — often legacy creds worth rotating |

### I4. SSH keys

- **Path:** `~/.ssh/` (id_*, config, known_hosts, authorized_keys)
- **Capture:** `rsync -av ~/.ssh/ ~/migration-bundle/ssh/` (or via chezmoi with `--gpg` encryption)
- **Restore:** Copy back, then **`chmod 700 ~/.ssh && chmod 600 ~/.ssh/*`** — SSH silently refuses keys with wrong permissions
- **Gotcha:** Treat the bundle as secret-bearing; encrypt the transfer.

### I5. GPG keys + trust DB

- **Path:** `~/.gnupg/`
- **Capture:** `gpg --export-secret-keys -a > ~/migration-bundle/gpg-secret.asc && gpg --export-ownertrust > ~/migration-bundle/gpg-trust.txt`
- **Restore:** `gpg --import gpg-secret.asc && gpg --import-ownertrust gpg-trust.txt`

### I6. VPN tunnels (WireGuard, OpenVPN)

- **WireGuard (App Store):** `~/Library/Group Containers/group.com.wireguard.macos/` — use GUI gear icon > Export Tunnels to Zip
- **WireGuard (CLI):** `/etc/wireguard/`
- **OpenVPN:** `.ovpn` profile files (location varies)
- **Gotchas:** Private keys in WG configs — encrypt during transfer

---

## LANE J — Manual / Deferred (Skill surfaces, doesn't auto-handle)

These are intentionally NOT auto-migrated. The skill should display each at the end of the restore run and walk Hunter through them.

### J1. iCloud Keychain passwords + WiFi

**Hunter's call:** skip. Will not auto-handle. Surface a one-line reminder: "Re-enable iCloud Keychain via System Settings, then verify WiFi auto-joins."

### J2. App-specific licenses

**Hunter's call:** skip — Apple ID + per-app account login handles most. Surface reminders for apps with offline machine licenses (Backblaze, Adobe, JetBrains, Setapp, Plex) so Hunter knows to deactivate on old Mac BEFORE wiping.

### J3. TCC permissions (Full Disk Access, Accessibility, Camera, Mic)

**Cannot migrate programmatically without MDM.** The TCC database is per-machine. Apps re-prompt on the new Mac.

**Strategy:** Skill produces a checklist of which apps had TCC grants on the old Mac. After restore, Hunter walks System Settings > Privacy & Security and re-grants.

**Capture (sanity reference):** `sqlite3 ~/Library/Application\ Support/com.apple.TCC/TCC.db "SELECT service, client FROM access;"` — requires Full Disk Access to read.

### J4. Time Machine + Spotlight exclusions

- Time Machine: `tmutil listexclusions` capture → `tmutil addexclusion <path>` replay per path
- Spotlight Privacy: NOT in any easily-exported plist; re-add via System Settings UI

### J5. Rosetta state verification

After restore: run `arch` in the shell. If it returns `i386`, the shell is running emulated. Reset by relaunching the terminal natively. Common after Migration Assistant; less common after fresh install + manual restore — but worth a one-shot check.

### J6. macOS Tahoe (26) SIP advisory

For any custom LaunchDaemon in `/Library/LaunchDaemons/` (Lane H2), advise rewriting as `SMAppService`-based helpers if running on Tahoe. Auto-detect target macOS version and warn.

---

## Tools matrix (which open-source repo covers which lane)

| Lane | Tool | Repo | Status |
|---|---|---|---|
| A1 | brew bundle | `Homebrew/homebrew-bundle` | Built-in |
| A2 | mas-cli | `mas-cli/mas` | Active |
| B1 | chezmoi | `twpayne/chezmoi` | Active |
| C1 | mise | `jdx/mise` | Active (consensus winner) |
| C2 | pipx | `pypa/pipx` | Active |
| C4 | cargo-binstall | `cargo-bins/cargo-binstall` | Active |
| D1 | macprefs | `clintmod/macprefs` | Active |
| D1 | macos-defaults | `brokosz/macos-defaults` | Active |
| H4 | PM2 | `Unitech/pm2` | Active |
| H7 | lporg | `blacktop/lporg` | **Archived 2025-09-19** |
| Bootstrap pattern | mac-dev-playbook | `geerlingguy/mac-dev-playbook` | Active (Ansible) |
| Bootstrap pattern | laptop | `thoughtbot/laptop` | Active |
| AI orchestration ref | homebrew-mcp | `jeannier/homebrew-mcp` | Active (Claude MCP) |
| AI orchestration ref | genai-macstudiosetup | `jazmy/genai-macstudiosetup` | Inactive (reference shape) |
| Pkg-manager updater | topgrade | `topgrade-rs/topgrade` | Active |
| Dotfile alt | yadm | `TheLocehiliosan/yadm` | Active (reference) |
| Dotfile alt | dotbot | `anishathalye/dotbot` | Active (reference) |

This is the curated download list for Lane Task #3.

---

## Skill blueprint (4 sub-skills under one composable parent)

To be detailed in the actual SKILL.md once Hunter approves. Sketch:

- **`mac-migration` (parent)** — composable parent with routing table + the choose-your-own-adventure entry flow
  - **`mac-inventory`** — Phase 1 scan. Runs the CAPTURE detection logic. Outputs a structured manifest. Asks user for opt-outs.
  - **`mac-capture`** — Phase 2. Runs the actual capture against approved lanes. Produces `~/migration-bundle/`.
  - **`mac-restore`** — Phase 3. Consumes `~/migration-bundle/`. Step-by-step verify-and-continue. Handles Tahoe SIP advisory.
  - **`mac-diff`** — Phase 4 sanity check. Compare old-Mac manifest vs new-Mac state post-restore. Surface anything missing.

Optional fifth:
- **`mac-launchd-reasoner`** — read each plist, explain what it does, flag Tahoe-incompatible patterns, suggest `SMAppService` rewrites.

---

## Sources

All sources cited inline in the 5 lane files and INVENTORY-GAPS.md. Key references:

- 5 lane files: 01-claude-and-ai-driven.md, 02-brewfile-and-dotfile-managers.md, 03-shell-path-versions-globals.md, 04-launchd-cron-background-services.md, 05-commercial-gui-pro-it.md
- Gap-fill: INVENTORY-GAPS.md (sections 1–18)
- External: Apple Developer docs (Migration Assistant, SMAppService, Containers), Eclectic Light Company (containers + login items), Docker for Mac issue #6164 (Migration Assistant kills daemon), HN Feb 2026 thread (gap acknowledged), Cursor/Zed/Warp official migration docs
