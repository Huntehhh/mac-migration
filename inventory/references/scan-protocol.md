# Scan Protocol — Phase 1 Per-Lane Discovery

The canonical reference for how `scripts/scan_inventory.sh` walks the 10 lanes documented in `../../references/inventory-lanes.md`. Every command here is read-only against the source Mac. No bytes are copied to the bundle in Phase 1 except the small per-lane manifests under `~/migration-bundle/manifests/` (text files + JSON outputs, never app data).

## Output locations

```
~/migration-bundle/
  manifest.json              Master manifest. Updated incrementally by scan_inventory.sh.
  migration.log.jsonl        Audit log. Append-only.
  manifests/                 Per-lane raw snapshots. Inputs for capture later.
```

Environment overrides:
- `BUNDLE` — default `~/migration-bundle`. Override to scan into a different path.

## manifest.json schema

```json
{
  "version": "1",
  "generated_at": "2026-05-22T18:00:00Z",
  "host": {
    "hostname": "old-mac.local",
    "macos_version": "15.4",
    "macos_codename": "Sequoia",
    "arch": "arm64",
    "user": "alice"
  },
  "target": {
    "macos_version": null,
    "macos_codename": null,
    "notes": "Filled in by restore phase on the new Mac"
  },
  "lanes": {
    "A": {
      "name": "Applications",
      "scanned_at": "2026-05-22T18:00:01Z",
      "items": {
        "A1.brew_formulae": { "count": 87, "highlights": ["git", "node", "..."] },
        "A1.brew_casks": { "count": 24, "highlights": ["docker", "rectangle", "..."] },
        "A1.brew_taps": { "count": 3, "list": ["homebrew/core", "homebrew/cask", "blacktop/tap"] },
        "A2.mas_apps": { "count": 6, "highlights": ["Xcode", "Slack", "..."] },
        "A3.orphan_apps": { "count": 3, "list": ["MyDMGApp.app", "..."] }
      },
      "size_estimate_bytes": null
    },
    "B": { "...": "..." },
    "C": { "...": "..." },
    "...": "...",
    "J": {
      "name": "Manual / Deferred",
      "items": {
        "J1.icloud_keychain": { "note": "User re-enables on new Mac" },
        "J2.app_licenses": { "list": ["1Password", "Backblaze", "..."] },
        "J3.tcc": { "count": 14, "apps_with_grants": ["Terminal", "iTerm2", "..."] }
      }
    }
  },
  "opt_outs": {
    "lane_h": ["H7.launchpad"],
    "lane_d": ["D5.stickies", "D5.notes_local"],
    "lane_j": ["J3.tcc"]
  },
  "preflight": {
    "checked_at": "2026-05-22T17:58:30Z",
    "passes": ["disk_space", "mas_signed_in", "mise", "gpg_key"],
    "warnings": ["chezmoi_unpushed_commits"],
    "blockers": []
  },
  "bundle": {
    "size_estimate_bytes": null,
    "lane_count": 10,
    "captured_at": null
  }
}
```

`opt_outs` is preserved across re-runs. `lanes.<X>` is replaced wholesale per re-run.

## Per-lane scan commands

Each block is what `scan_inventory.sh` runs for that lane. All commands are read-only macOS BSD-flavored. Errors are caught — if a tool isn't installed, the lane records `"available": false` and moves on.

### Lane A — Applications

```bash
# A1 brew (formulae, casks, taps)
brew leaves > "$BUNDLE/manifests/brew-leaves.txt"
brew list --formula > "$BUNDLE/manifests/brew-formulae.txt"
brew list --cask > "$BUNDLE/manifests/brew-casks.txt"
brew tap > "$BUNDLE/manifests/brew-taps.txt"
formula_count=$(wc -l < "$BUNDLE/manifests/brew-formulae.txt" | tr -d ' ')
cask_count=$(wc -l < "$BUNDLE/manifests/brew-casks.txt" | tr -d ' ')
tap_count=$(wc -l < "$BUNDLE/manifests/brew-taps.txt" | tr -d ' ')

# A2 Mac App Store
mas list > "$BUNDLE/manifests/mas-installed.txt" 2>/dev/null || echo "" > "$BUNDLE/manifests/mas-installed.txt"
mas_count=$(wc -l < "$BUNDLE/manifests/mas-installed.txt" | tr -d ' ')

# A3 orphan apps — system_profiler minus Brewfile minus mas list
system_profiler SPApplicationsDataType -json > "$BUNDLE/manifests/system-apps.json"
# orphan calc happens in jq postprocess (see scan_inventory.sh body)
```

### Lane B — Shell + PATH + Custom Scripts

```bash
# B1 dotfiles (chezmoi presence)
if command -v chezmoi >/dev/null 2>&1; then
  chezmoi_root=$(chezmoi source-path 2>/dev/null || echo "")
  chezmoi_unpushed=$(cd "$chezmoi_root" && git log @{u}.. --oneline 2>/dev/null | wc -l | tr -d ' ')
fi

# B2 unversioned dotfiles (just count which exist)
for f in ~/.zshrc ~/.zprofile ~/.zshenv ~/.bashrc ~/.bash_profile ~/.tmux.conf ~/.gitconfig; do
  [ -f "$f" ] && echo "$f"
done > "$BUNDLE/manifests/dotfiles-present.txt"

# B3 /etc/paths.d
ls /etc/paths.d 2>/dev/null > "$BUNDLE/manifests/etc-paths-d.txt"
paths_d_count=$(wc -l < "$BUNDLE/manifests/etc-paths-d.txt" | tr -d ' ')

# B4 home bin
bin_count=0
[ -d ~/bin ] && bin_count=$(find ~/bin -maxdepth 1 -type f -perm +111 | wc -l | tr -d ' ')
local_bin_count=0
[ -d ~/.local/bin ] && local_bin_count=$(find ~/.local/bin -maxdepth 1 -type f -perm +111 | wc -l | tr -d ' ')

# B5 hosts + sudoers.d (counts only — content stays put)
hosts_lines=$(grep -cvE "^(#|$)" /etc/hosts 2>/dev/null || echo 0)
sudoers_files=$(ls /etc/sudoers.d 2>/dev/null | grep -v README | wc -l | tr -d ' ')
```

### Lane C — Language Toolchains + Globals

```bash
# C1 mise
[ -f ~/.tool-versions ] && cp ~/.tool-versions "$BUNDLE/manifests/.tool-versions"
[ -f ~/.config/mise/config.toml ] && cp ~/.config/mise/config.toml "$BUNDLE/manifests/mise-config.toml"
mise_tools=$(grep -cvE "^(#|$)" ~/.tool-versions 2>/dev/null || echo 0)

# C2 pipx
if command -v pipx >/dev/null 2>&1; then
  pipx list --json > "$BUNDLE/manifests/pipx.json" 2>/dev/null || echo "{}" > "$BUNDLE/manifests/pipx.json"
  pipx_count=$(jq '.venvs | length' "$BUNDLE/manifests/pipx.json" 2>/dev/null || echo 0)
fi

# C3 npm globals
if command -v npm >/dev/null 2>&1; then
  npm list -g --depth=0 --json > "$BUNDLE/manifests/npm-globals.json" 2>/dev/null || echo "{}" > "$BUNDLE/manifests/npm-globals.json"
  npm_count=$(jq '.dependencies | length' "$BUNDLE/manifests/npm-globals.json" 2>/dev/null || echo 0)
fi

# C4 cargo
if command -v cargo >/dev/null 2>&1; then
  cargo install --list > "$BUNDLE/manifests/cargo-installs.txt" 2>/dev/null
  cargo_count=$(grep -cE "^[a-z0-9_-]+ v" "$BUNDLE/manifests/cargo-installs.txt" 2>/dev/null || echo 0)
fi

# C5 gem
if command -v gem >/dev/null 2>&1; then
  gem list > "$BUNDLE/manifests/gem-list.txt" 2>/dev/null
  gem_count=$(wc -l < "$BUNDLE/manifests/gem-list.txt" | tr -d ' ')
fi

# C6 go bin
if command -v go >/dev/null 2>&1; then
  ls -1 "$(go env GOPATH)/bin" 2>/dev/null > "$BUNDLE/manifests/go-bin.txt"
  go_count=$(wc -l < "$BUNDLE/manifests/go-bin.txt" | tr -d ' ')
fi

# C7 composer
if command -v composer >/dev/null 2>&1; then
  composer global show --format=json > "$BUNDLE/manifests/composer-globals.json" 2>/dev/null || echo "{}" > "$BUNDLE/manifests/composer-globals.json"
fi
```

### Lane D — GUI App Configs

```bash
# D1 defaults domains count
defaults_count=$(defaults domains 2>/dev/null | tr ',' '\n' | wc -l | tr -d ' ')

# D2 Application Support dirs
appsupport_count=$(ls -1 ~/Library/Application\ Support 2>/dev/null | wc -l | tr -d ' ')

# D3 Containers
containers_count=$(ls -1 ~/Library/Containers 2>/dev/null | wc -l | tr -d ' ')
group_containers_count=$(ls -1 ~/Library/Group\ Containers 2>/dev/null | wc -l | tr -d ' ')

# D4 fonts
user_fonts=$(ls -1 ~/Library/Fonts 2>/dev/null | wc -l | tr -d ' ')
system_fonts=$(ls -1 /Library/Fonts 2>/dev/null | wc -l | tr -d ' ')

# D5 stickies + notes presence
stickies_count=0
[ -d ~/Library/Containers/com.apple.Stickies ] && stickies_count=$(ls -1 ~/Library/Containers/com.apple.Stickies/Data/Library/Stickies 2>/dev/null | wc -l | tr -d ' ')

# Mail rules + signatures
mail_v_dir=$(ls -d ~/Library/Mail/V* 2>/dev/null | head -1)
mail_rules_present=false
[ -f "$mail_v_dir/MailData/SyncedRules.plist" ] && mail_rules_present=true
```

### Lane E — Browsers

```bash
# Per-browser presence + profile size
for browser_path in \
  "~/Library/Application Support/Google/Chrome" \
  "~/Library/Application Support/BraveSoftware/Brave-Browser" \
  "~/Library/Application Support/Firefox/Profiles" \
  "~/Library/Application Support/Arc" \
  "~/Library/Application Support/Microsoft Edge" \
  "~/Library/Safari"; do
  path_eval=$(eval echo "$browser_path")
  if [ -d "$path_eval" ]; then
    size=$(du -sk "$path_eval" 2>/dev/null | awk '{print $1*1024}')
    echo "{\"path\":\"$path_eval\",\"size_bytes\":$size}"
  fi
done

# Chrome extensions (if Chrome present)
chrome_ext_count=0
chrome_ext_dir="$HOME/Library/Application Support/Google/Chrome/Default/Extensions"
[ -d "$chrome_ext_dir" ] && chrome_ext_count=$(ls -1 "$chrome_ext_dir" 2>/dev/null | wc -l | tr -d ' ')
```

### Lane F — IDEs + Terminals

```bash
# F1 VS Code / Cursor extensions
vscode_count=0
cursor_count=0
command -v code >/dev/null 2>&1 && vscode_count=$(code --list-extensions 2>/dev/null | wc -l | tr -d ' ')
command -v cursor >/dev/null 2>&1 && cursor_count=$(cursor --list-extensions 2>/dev/null | wc -l | tr -d ' ')

# F2 Zed config presence
[ -f ~/.config/zed/settings.json ] && zed_present=true

# F3 JetBrains IDEs
jetbrains_dirs=$(ls -1 ~/Library/Application\ Support/JetBrains 2>/dev/null | wc -l | tr -d ' ')

# F5 Terminals
iterm2_plist_present=false
[ -f ~/Library/Preferences/com.googlecode.iterm2.plist ] && iterm2_plist_present=true
warp_dir_present=false
[ -d ~/Library/Application\ Support/dev.warp.Warp-Stable ] && warp_dir_present=true
ghostty_present=false
[ -f ~/.config/ghostty/config ] && ghostty_present=true
```

### Lane G — Databases + Containers

```bash
# G1 Postgres
pg_version=""
pg_dbs=0
pg_size_bytes=0
if command -v psql >/dev/null 2>&1; then
  pg_version=$(psql --version 2>/dev/null | awk '{print $3}')
  pg_dbs=$(psql -U "$(whoami)" -t -c "SELECT count(*) FROM pg_database WHERE datistemplate=false;" 2>/dev/null | tr -d ' ')
  # data dir size — try common homebrew paths
  for d in /opt/homebrew/var/postgresql@*; do
    [ -d "$d" ] && pg_size_bytes=$((pg_size_bytes + $(du -sk "$d" 2>/dev/null | awk '{print $1*1024}')))
  done
fi

# G2 MySQL
mysql_present=false
command -v mysql >/dev/null 2>&1 && mysql_present=true

# G3 Redis
redis_present=false
[ -f /opt/homebrew/var/db/redis/dump.rdb ] && redis_present=true

# G4 MongoDB
mongo_present=false
command -v mongosh >/dev/null 2>&1 && mongo_present=true

# G5 Docker
docker_contexts=0
[ -d ~/.docker/contexts/meta ] && docker_contexts=$(ls -1 ~/.docker/contexts/meta 2>/dev/null | wc -l | tr -d ' ')

# G6 Kubernetes
kube_present=false
[ -f ~/.kube/config ] && kube_present=true
krew_count=0
command -v kubectl >/dev/null 2>&1 && krew_count=$(kubectl krew list 2>/dev/null | tail -n +2 | wc -l | tr -d ' ')

# G7 Helm
helm_repos=0
command -v helm >/dev/null 2>&1 && helm_repos=$(helm repo list 2>/dev/null | tail -n +2 | wc -l | tr -d ' ')
```

### Lane H — Background Services

```bash
# H1 user LaunchAgents
user_launchagents=$(ls -1 ~/Library/LaunchAgents 2>/dev/null | grep -c '\.plist$' | tr -d ' ')

# H2 system LaunchAgents + LaunchDaemons (no sudo — just counts via ls)
system_launchagents=$(ls -1 /Library/LaunchAgents 2>/dev/null | grep -c '\.plist$' | tr -d ' ')
system_launchdaemons=$(ls -1 /Library/LaunchDaemons 2>/dev/null | grep -c '\.plist$' | tr -d ' ')

# H3 brew services running
brew_services_running=0
if command -v brew >/dev/null 2>&1; then
  brew services list > "$BUNDLE/manifests/brew-services-running.txt" 2>/dev/null
  brew_services_running=$(awk '$2=="started"' "$BUNDLE/manifests/brew-services-running.txt" | wc -l | tr -d ' ')
fi

# H4 PM2
pm2_processes=0
if command -v pm2 >/dev/null 2>&1; then
  pm2_processes=$(pm2 jlist 2>/dev/null | jq 'length' 2>/dev/null || echo 0)
fi

# H5 cron
crontab -l > "$BUNDLE/manifests/user-crontab.txt" 2>/dev/null || echo "" > "$BUNDLE/manifests/user-crontab.txt"
cron_lines=$(grep -cvE "^(#|$)" "$BUNDLE/manifests/user-crontab.txt" 2>/dev/null || echo 0)

# H6 Login Items (legacy AppleScript probe)
login_items=$(osascript -e 'tell application "System Events" to get the name of every login item' 2>/dev/null | tr ',' '\n' | wc -l | tr -d ' ')
```

### Lane I — Credentials + Auth

```bash
# Count presence only — never read values.
# I1 git + gh
git_config_present=false
[ -f ~/.gitconfig ] && git_config_present=true
gh_hosts_present=false
[ -f ~/.config/gh/hosts.yml ] && gh_hosts_present=true

# I2 cloud CLIs
aws_profiles=0
[ -f ~/.aws/credentials ] && aws_profiles=$(grep -c '^\[' ~/.aws/credentials 2>/dev/null || echo 0)
gcloud_present=false
[ -d ~/.config/gcloud ] && gcloud_present=true
azure_present=false
[ -d ~/.azure ] && azure_present=true
cloudflared_present=false
[ -d ~/.cloudflared ] && cloudflared_present=true
doctl_present=false
[ -d ~/.config/doctl ] && doctl_present=true

# I3 CLI token files
declare -a token_files=(~/.npmrc ~/.cargo/credentials.toml ~/.gem/credentials ~/.config/composer/auth.json ~/.pypirc ~/.huggingface/token ~/.netrc)
tokens_present=0
for tf in "${token_files[@]}"; do
  [ -f "$tf" ] && tokens_present=$((tokens_present + 1))
done

# I4 SSH
ssh_keys=0
[ -d ~/.ssh ] && ssh_keys=$(find ~/.ssh -maxdepth 1 -name 'id_*' ! -name '*.pub' 2>/dev/null | wc -l | tr -d ' ')

# I5 GPG keys
gpg_secret_keys=0
command -v gpg >/dev/null 2>&1 && gpg_secret_keys=$(gpg --list-secret-keys --with-colons 2>/dev/null | grep -c '^sec:' | tr -d ' ')

# I6 WireGuard
wg_tunnels=0
[ -d ~/Library/Group\ Containers/group.com.wireguard.macos ] && wg_tunnels=$(ls -1 ~/Library/Group\ Containers/group.com.wireguard.macos/Library/Application\ Support/WireGuard 2>/dev/null | wc -l | tr -d ' ')
```

### Lane J — Manual / Deferred (checklist generation)

Lane J doesn't scan — it writes a pre-formatted checklist into `manifest.json` for the user to walk after restore. The skill's job is to surface these items so the user doesn't forget:

```json
{
  "J1.icloud_keychain": "Sign in to iCloud on new Mac, enable Keychain, verify WiFi auto-joins",
  "J2.app_licenses": "Deactivate offline-licensed apps on OLD Mac BEFORE wipe: Backblaze, Adobe, JetBrains, Setapp, Plex, etc.",
  "J3.tcc": "Re-grant Full Disk Access, Accessibility, Camera, Mic per app via System Settings > Privacy & Security",
  "J4.time_machine": "Re-add Time Machine + Spotlight exclusions via System Settings",
  "J5.rosetta": "Run `arch` after first terminal launch on new Mac; if i386, relaunch natively",
  "J6.tahoe_sip": "If new Mac is on macOS 26 (Tahoe), audit any /Library/LaunchDaemons restore for SMAppService rewrite"
}
```

The TCC sanity capture (`sqlite3 ~/Library/Application Support/com.apple.TCC/TCC.db "SELECT service, client FROM access;"`) runs IF the preflight FDA check passes. Otherwise Lane J records `tcc_accessible: false`.

## Summary template

After all lane scans complete, print this to stdout. The summary is what the user reads before opting out.

```
Mac inventory complete. Found:

  Lane A  Applications
          {brew_formulae} brew formulae + {brew_casks} casks + {brew_taps} taps
          {mas_apps} Mac App Store apps
          {orphan_apps} orphan apps in /Applications

  Lane B  Shell + PATH + Custom scripts
          chezmoi: {chezmoi_status} ({chezmoi_unpushed} unpushed commits)
          {dotfiles_present_count} top-level dotfiles
          /etc/paths.d: {paths_d_count} entries
          ~/bin: {bin_count} scripts, ~/.local/bin: {local_bin_count} scripts
          /etc/hosts: {hosts_lines} custom lines, sudoers.d: {sudoers_files} files

  Lane C  Language toolchains + globals
          mise: {mise_tools} tools pinned
          pipx: {pipx_count} envs, npm globals: {npm_count}
          cargo: {cargo_count}, gem: {gem_count}, go: {go_count}, composer: {composer_count}

  Lane D  GUI app configs
          {defaults_count} defaults domains
          ~/Library/Application Support: {appsupport_count} dirs
          ~/Library/Containers: {containers_count}, Group Containers: {group_containers_count}
          User fonts: {user_fonts}
          Stickies: {stickies_count} notes, Mail rules: {mail_rules_present}

  Lane E  Browsers
          {browsers_detected_list}
          Chrome extensions: {chrome_ext_count}

  Lane F  IDEs + Terminals
          VS Code: {vscode_count} extensions, Cursor: {cursor_count}, Zed: {zed_present}
          JetBrains: {jetbrains_dirs} IDE configs
          iTerm2: {iterm2_plist_present}, Warp: {warp_dir_present}, Ghostty: {ghostty_present}

  Lane G  Databases + Containers
          Postgres {pg_version}: {pg_dbs} DBs ({pg_size_bytes_h})
          MySQL: {mysql_present}, Redis: {redis_present}, MongoDB: {mongo_present}
          Docker contexts: {docker_contexts}, Kubernetes config: {kube_present}
          krew plugins: {krew_count}, Helm repos: {helm_repos}

  Lane H  Background services
          User LaunchAgents: {user_launchagents}
          System LaunchAgents: {system_launchagents}, LaunchDaemons: {system_launchdaemons}
          brew services running: {brew_services_running}
          PM2 processes: {pm2_processes}, cron lines: {cron_lines}, Login Items: {login_items}

  Lane I  Credentials + Auth
          git: {git_config_present}, gh: {gh_hosts_present}
          AWS profiles: {aws_profiles}, gcloud: {gcloud_present}, Azure: {azure_present}
          Cloudflare: {cloudflared_present}, DigitalOcean: {doctl_present}
          CLI token files: {tokens_present} present
          SSH keys: {ssh_keys}, GPG secret keys: {gpg_secret_keys}
          WireGuard tunnels: {wg_tunnels}

  Lane J  Manual / Deferred — 6 items in checklist (TCC, iCloud Keychain, licenses, etc.)

All of the above will be migrated. Anything you do NOT want me to handle?
```

The skill body parses the user's natural-language reply, maps phrases to lane/sub-module IDs (see the opt-out mapping table below), records to `manifest.json` under `opt_outs`.

## Opt-out mapping table

Phrases that map to specific lane/sub-module flags. Used by the skill body to translate the user's reply.

| User says | Maps to |
|-----------|---------|
| "skip Launchpad" / "skip Launchpad layout" | `lane_h.H7.launchpad` |
| "skip Stickies" | `lane_d.D5.stickies` |
| "skip Notes" / "skip local Notes" | `lane_d.D5.notes_local` |
| "I'll redo TCC manually" / "skip TCC" | `lane_j.J3.tcc` |
| "skip fonts" | `lane_d.D4.fonts` |
| "skip Mail" / "skip Mail rules" | `lane_d.D5.mail` |
| "skip Photos" | `lane_d.D2.photos` (Photos handled via Apple's flow per playbook) |
| "skip Docker" | `lane_g.G5.docker` |
| "skip Postgres" / "I'll dump Postgres myself" | `lane_g.G1.postgres` |
| "skip cloud CLIs" / "I'll re-auth everything" | `lane_i.I2.cloud_clis` |
| "skip SSH keys" / "I'll generate new keys" | `lane_i.I4.ssh` |
| "skip Safari" | `lane_e.safari` |
| "skip JetBrains" | `lane_f.F3.jetbrains` |

If the user says something the table doesn't cover, the skill asks a clarifying question rather than guessing.

## Drift-baseline workflow

Two modes:

### Save baseline

```bash
scripts/scan_inventory.sh --save-baseline
```

Runs the full scan, then copies `manifest.json` to `~/.mac-migration/baseline.json` with a timestamp. `~/.mac-migration/` is created if missing.

### Diff against baseline

```bash
scripts/scan_inventory.sh --diff-baseline
```

Runs the full scan into a temp manifest, then diffs key fields against `~/.mac-migration/baseline.json`:

- **Added**: brew formulae/casks present now but not in baseline; new LaunchAgents; new MAS apps; new fonts; new pipx envs; new VS Code extensions
- **Removed**: anything in baseline but not now
- **Changed**: mise `.tool-versions` deltas; new dotfiles; brew tap changes
- **Unchanged**: silenced unless `--verbose`

Output is grouped by lane. Example:

```
Drift since baseline (2026-05-01T09:14:00Z, 21 days ago):

  Lane A  Applications
    + brew formula:  ripgrep, fd, eza
    + brew cask:     ghostty
    - brew formula:  fzf (uninstalled 2026-05-10)
    + MAS app:       Things 3

  Lane C  Language toolchains
    ~ .tool-versions: node 22.4.1 -> 22.7.0, python 3.13.0 -> 3.13.1
    + pipx env: poetry

  Lane H  Background services
    + user LaunchAgent: com.local.deepl.plist
```

The `diff` sub-skill (Phase 4) reuses this script with `--baseline ~/migration-bundle/manifest.json --current /tmp/new-mac-manifest.json` to compare old-Mac state against new-Mac state after restore. Same comparison logic, different inputs.

## Audit log format

Every action appends one JSON line to `~/migration-bundle/migration.log.jsonl`:

```json
{"ts":"2026-05-22T18:00:01Z","lane":"A","action":"scan","status":"ok","detail":"87 formulae, 24 casks, 6 mas"}
{"ts":"2026-05-22T18:00:02Z","lane":"B","action":"scan","status":"ok","detail":"chezmoi: 2 unpushed commits"}
{"ts":"2026-05-22T18:00:03Z","lane":"D","action":"scan","status":"warn","detail":"FDA-gated paths skipped (no TCC access)"}
{"ts":"2026-05-22T18:02:00Z","lane":"-","action":"opt_out_recorded","status":"ok","detail":"lane_h.H7.launchpad, lane_d.D5.stickies"}
```

`detail` is free-form. `status` is `ok` | `warn` | `fail`. The diff/restore phases parse this log to surface a per-lane history when verifying.
