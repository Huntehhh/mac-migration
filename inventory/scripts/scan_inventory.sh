#!/usr/bin/env bash
#
# scan_inventory.sh
#
# Phase 1 main scan. Walks all 10 lanes from references/inventory-lanes.md
# and writes a structured manifest at $BUNDLE/manifest.json. Idempotent - re-runs
# replace per-lane scan blocks but PRESERVE opt_outs from any prior run.
#
# Modes:
#   (default)         Full scan. Writes manifest.json.
#   --save-baseline   Run full scan, then copy manifest.json to ~/.mac-migration/baseline.json.
#   --diff-baseline   Run full scan into temp, diff against ~/.mac-migration/baseline.json,
#                     print summary. Does NOT update the bundle manifest.
#   --verbose         More detail in diff output (include unchanged categories).
#
# Env overrides:
#   BUNDLE   Default ~/migration-bundle
#
# Cron-rerunnable: yes. No state outside $BUNDLE and ~/.mac-migration/.

set -euo pipefail

BUNDLE="${BUNDLE:-$HOME/migration-bundle}"
BASELINE_DIR="$HOME/.mac-migration"
BASELINE_FILE="$BASELINE_DIR/baseline.json"
LOG="$BUNDLE/migration.log.jsonl"

MODE="full"
VERBOSE=0
for arg in "$@"; do
  case "$arg" in
    --save-baseline) MODE="save-baseline" ;;
    --diff-baseline) MODE="diff-baseline" ;;
    --verbose) VERBOSE=1 ;;
    *) echo "Unknown arg: $arg" >&2; exit 2 ;;
  esac
done

mkdir -p "$BUNDLE/manifests" "$BUNDLE/.done"
touch "$LOG"

iso_ts() { date -u +"%Y-%m-%dT%H:%M:%SZ"; }

log_lane() {
  local lane="$1" action="$2" status="$3" detail="$4"
  printf '{"ts":"%s","lane":"%s","action":"%s","status":"%s","detail":"%s"}\n' \
    "$(iso_ts)" "$lane" "$action" "$status" "$(printf '%s' "$detail" | sed 's/"/\\"/g')" \
    >> "$LOG"
}

# Where to write the working manifest. In diff mode we use a temp file.
if [ "$MODE" = "diff-baseline" ]; then
  WORK_MANIFEST="$(mktemp -t mac-migration-scan.XXXXXX).json"
  trap 'rm -f "$WORK_MANIFEST"' EXIT
else
  WORK_MANIFEST="$BUNDLE/manifest.json"
fi

# Preserve opt_outs from prior manifest if present
PRIOR_OPTOUTS='{}'
if [ -f "$BUNDLE/manifest.json" ] && [ "$MODE" != "diff-baseline" ]; then
  PRIOR_OPTOUTS=$(jq -c '.opt_outs // {}' "$BUNDLE/manifest.json" 2>/dev/null || echo '{}')
fi

# -----------------------------------------------------------------------------
# Host metadata
# -----------------------------------------------------------------------------
HOSTNAME_VAL=$(scutil --get LocalHostName 2>/dev/null || hostname)
MACOS_VER=$(sw_vers -productVersion 2>/dev/null || echo "unknown")
ARCH_VAL=$(uname -m)
USER_VAL=$(whoami)

# Codename - call shared script if it exists, otherwise inline best-effort
PARENT_SCRIPTS="$(cd "$(dirname "$0")/../../scripts" 2>/dev/null && pwd || echo "")"
if [ -n "$PARENT_SCRIPTS" ] && [ -x "$PARENT_SCRIPTS/detect_macos_version.sh" ]; then
  MACOS_CODENAME=$("$PARENT_SCRIPTS/detect_macos_version.sh" --codename-only 2>/dev/null || echo "unknown")
else
  case "${MACOS_VER%%.*}" in
    15) MACOS_CODENAME="Sequoia" ;;
    14) MACOS_CODENAME="Sonoma" ;;
    13) MACOS_CODENAME="Ventura" ;;
    26) MACOS_CODENAME="Tahoe" ;;
    *)  MACOS_CODENAME="unknown" ;;
  esac
fi

log_lane "-" "scan_start" "ok" "mode=$MODE host=$HOSTNAME_VAL os=$MACOS_VER ($MACOS_CODENAME)"

# -----------------------------------------------------------------------------
# Lane A - Applications
# -----------------------------------------------------------------------------
scan_lane_a() {
  local formula_count=0 cask_count=0 tap_count=0 mas_count=0 orphan_count=0
  local formula_highlights="[]" cask_highlights="[]"

  if command -v brew >/dev/null 2>&1; then
    brew list --formula > "$BUNDLE/manifests/brew-formulae.txt" 2>/dev/null || true
    brew list --cask    > "$BUNDLE/manifests/brew-casks.txt"    2>/dev/null || true
    brew tap            > "$BUNDLE/manifests/brew-taps.txt"     2>/dev/null || true
    brew leaves         > "$BUNDLE/manifests/brew-leaves.txt"   2>/dev/null || true
    formula_count=$(wc -l < "$BUNDLE/manifests/brew-formulae.txt" 2>/dev/null | tr -d ' ' || echo 0)
    cask_count=$(wc -l    < "$BUNDLE/manifests/brew-casks.txt"    2>/dev/null | tr -d ' ' || echo 0)
    tap_count=$(wc -l     < "$BUNDLE/manifests/brew-taps.txt"     2>/dev/null | tr -d ' ' || echo 0)
    formula_highlights=$(head -10 "$BUNDLE/manifests/brew-formulae.txt" 2>/dev/null | jq -R . | jq -s -c . || echo "[]")
    cask_highlights=$(head -10 "$BUNDLE/manifests/brew-casks.txt" 2>/dev/null | jq -R . | jq -s -c . || echo "[]")
  fi

  if command -v mas >/dev/null 2>&1; then
    mas list > "$BUNDLE/manifests/mas-installed.txt" 2>/dev/null || true
    mas_count=$(grep -cE '^[0-9]+' "$BUNDLE/manifests/mas-installed.txt" 2>/dev/null || echo 0)
  fi

  # Orphan apps: system_profiler minus what's in Brewfile + mas
  system_profiler SPApplicationsDataType -json > "$BUNDLE/manifests/system-apps.json" 2>/dev/null || echo '{}' > "$BUNDLE/manifests/system-apps.json"

  # All /Applications app names
  local sys_apps_file
  sys_apps_file=$(mktemp -t sysapps.XXXXXX)
  jq -r '.SPApplicationsDataType[]? | select(.path | startswith("/Applications/")) | ._name' \
    "$BUNDLE/manifests/system-apps.json" 2>/dev/null | sort -u > "$sys_apps_file"

  # mas app names - second token onward up to "(", e.g. "497799835 Xcode (16.0)"
  local mas_apps_file
  mas_apps_file=$(mktemp -t masapps.XXXXXX)
  sed -E 's/^[0-9]+ +//; s/ +\([^)]*\)$//' "$BUNDLE/manifests/mas-installed.txt" 2>/dev/null | sort -u > "$mas_apps_file"

  # Cask app names - best-effort; cask token != display name. Use brew info --json if available
  local cask_apps_file
  cask_apps_file=$(mktemp -t caskapps.XXXXXX)
  if command -v brew >/dev/null 2>&1 && [ -s "$BUNDLE/manifests/brew-casks.txt" ]; then
    while IFS= read -r cask; do
      brew info --cask "$cask" --json=v2 2>/dev/null | \
        jq -r '.casks[0].name[]?, .casks[0].artifacts[]?.app[]? // empty' 2>/dev/null | \
        sed -E 's/\.app$//'
    done < "$BUNDLE/manifests/brew-casks.txt" | sort -u > "$cask_apps_file"
  fi

  # Orphans: in sys_apps but NOT in mas_apps and NOT in cask_apps
  local orphan_file
  orphan_file=$(mktemp -t orphans.XXXXXX)
  comm -23 "$sys_apps_file" <(cat "$mas_apps_file" "$cask_apps_file" | sort -u) > "$orphan_file"
  orphan_count=$(wc -l < "$orphan_file" | tr -d ' ')
  mv "$orphan_file" "$BUNDLE/manifests/orphan-apps.txt"

  rm -f "$sys_apps_file" "$mas_apps_file" "$cask_apps_file"

  log_lane "A" "scan" "ok" "$formula_count formulae, $cask_count casks, $tap_count taps, $mas_count mas, $orphan_count orphans"

  jq -n \
    --arg ts "$(iso_ts)" \
    --argjson formula_count "${formula_count:-0}" \
    --argjson cask_count "${cask_count:-0}" \
    --argjson tap_count "${tap_count:-0}" \
    --argjson mas_count "${mas_count:-0}" \
    --argjson orphan_count "${orphan_count:-0}" \
    --argjson formula_highlights "${formula_highlights:-[]}" \
    --argjson cask_highlights "${cask_highlights:-[]}" \
    '{
      name: "Applications",
      scanned_at: $ts,
      items: {
        "A1.brew_formulae": { count: $formula_count, highlights: $formula_highlights },
        "A1.brew_casks":    { count: $cask_count, highlights: $cask_highlights },
        "A1.brew_taps":     { count: $tap_count },
        "A2.mas_apps":      { count: $mas_count },
        "A3.orphan_apps":   { count: $orphan_count }
      }
    }'
}

# -----------------------------------------------------------------------------
# Lane B - Shell + PATH + Custom Scripts
# -----------------------------------------------------------------------------
scan_lane_b() {
  local chezmoi_source="" chezmoi_unpushed=0 dotfiles_count=0
  local paths_d_count=0 bin_count=0 local_bin_count=0
  local hosts_lines=0 sudoers_files=0

  if command -v chezmoi >/dev/null 2>&1; then
    chezmoi_source=$(chezmoi source-path 2>/dev/null || echo "")
    if [ -n "$chezmoi_source" ] && [ -d "$chezmoi_source" ]; then
      chezmoi_unpushed=$(cd "$chezmoi_source" && git log '@{u}..' --oneline 2>/dev/null | wc -l | tr -d ' ' || echo 0)
    fi
  fi

  for f in "$HOME/.zshrc" "$HOME/.zprofile" "$HOME/.zshenv" "$HOME/.bashrc" "$HOME/.bash_profile" "$HOME/.tmux.conf" "$HOME/.gitconfig"; do
    [ -f "$f" ] && dotfiles_count=$((dotfiles_count + 1))
  done

  paths_d_count=$(ls /etc/paths.d 2>/dev/null | wc -l | tr -d ' ' || echo 0)
  [ -d "$HOME/bin" ] && bin_count=$(find "$HOME/bin" -maxdepth 1 -type f -perm +111 2>/dev/null | wc -l | tr -d ' ' || echo 0)
  [ -d "$HOME/.local/bin" ] && local_bin_count=$(find "$HOME/.local/bin" -maxdepth 1 -type f -perm +111 2>/dev/null | wc -l | tr -d ' ' || echo 0)

  hosts_lines=$(grep -cvE '^(#|$)' /etc/hosts 2>/dev/null || echo 0)
  sudoers_files=$(ls /etc/sudoers.d 2>/dev/null | grep -v README | wc -l | tr -d ' ' || echo 0)

  log_lane "B" "scan" "ok" "chezmoi:$chezmoi_unpushed unpushed, dotfiles:$dotfiles_count, paths.d:$paths_d_count, bin:$bin_count, local/bin:$local_bin_count"

  jq -n \
    --arg ts "$(iso_ts)" \
    --arg chezmoi_source "$chezmoi_source" \
    --argjson chezmoi_unpushed "${chezmoi_unpushed:-false}" \
    --argjson dotfiles_count "${dotfiles_count:-0}" \
    --argjson paths_d_count "${paths_d_count:-0}" \
    --argjson bin_count "${bin_count:-0}" \
    --argjson local_bin_count "${local_bin_count:-0}" \
    --argjson hosts_lines "${hosts_lines:-0}" \
    --argjson sudoers_files "${sudoers_files:-0}" \
    '{
      name: "Shell + PATH + Custom Scripts",
      scanned_at: $ts,
      items: {
        "B1.chezmoi":         { source: $chezmoi_source, unpushed_commits: $chezmoi_unpushed },
        "B2.dotfiles_present":{ count: $dotfiles_count },
        "B3.etc_paths_d":     { count: $paths_d_count },
        "B4.home_bin":        { count: $bin_count },
        "B4.home_local_bin":  { count: $local_bin_count },
        "B5.etc_hosts_lines": { count: $hosts_lines },
        "B5.sudoers_d_files": { count: $sudoers_files }
      }
    }'
}

# -----------------------------------------------------------------------------
# Lane C - Language Toolchains + Globals
# -----------------------------------------------------------------------------
scan_lane_c() {
  local mise_tools=0 pipx_count=0 npm_count=0 cargo_count=0 gem_count=0 go_count=0 composer_count=0

  [ -f "$HOME/.tool-versions" ] && cp "$HOME/.tool-versions" "$BUNDLE/manifests/.tool-versions"
  [ -f "$HOME/.config/mise/config.toml" ] && cp "$HOME/.config/mise/config.toml" "$BUNDLE/manifests/mise-config.toml"
  mise_tools=$(grep -cvE '^(#|$)' "$HOME/.tool-versions" 2>/dev/null || echo 0)

  if command -v pipx >/dev/null 2>&1; then
    pipx list --json > "$BUNDLE/manifests/pipx.json" 2>/dev/null || echo '{}' > "$BUNDLE/manifests/pipx.json"
    pipx_count=$(jq '.venvs | length' "$BUNDLE/manifests/pipx.json" 2>/dev/null || echo 0)
  fi

  if command -v npm >/dev/null 2>&1; then
    npm list -g --depth=0 --json > "$BUNDLE/manifests/npm-globals.json" 2>/dev/null || echo '{}' > "$BUNDLE/manifests/npm-globals.json"
    npm_count=$(jq '.dependencies | length // 0' "$BUNDLE/manifests/npm-globals.json" 2>/dev/null || echo 0)
  fi

  if command -v cargo >/dev/null 2>&1; then
    cargo install --list > "$BUNDLE/manifests/cargo-installs.txt" 2>/dev/null || true
    cargo_count=$(grep -cE '^[a-z0-9_-]+ v' "$BUNDLE/manifests/cargo-installs.txt" 2>/dev/null || echo 0)
  fi

  if command -v gem >/dev/null 2>&1; then
    gem list > "$BUNDLE/manifests/gem-list.txt" 2>/dev/null || true
    gem_count=$(wc -l < "$BUNDLE/manifests/gem-list.txt" 2>/dev/null | tr -d ' ' || echo 0)
  fi

  if command -v go >/dev/null 2>&1; then
    local gopath
    gopath=$(go env GOPATH 2>/dev/null || echo "")
    if [ -n "$gopath" ] && [ -d "$gopath/bin" ]; then
      ls -1 "$gopath/bin" > "$BUNDLE/manifests/go-bin.txt" 2>/dev/null || true
      go_count=$(wc -l < "$BUNDLE/manifests/go-bin.txt" 2>/dev/null | tr -d ' ' || echo 0)
    fi
  fi

  if command -v composer >/dev/null 2>&1; then
    composer global show --format=json > "$BUNDLE/manifests/composer-globals.json" 2>/dev/null || echo '{}' > "$BUNDLE/manifests/composer-globals.json"
    composer_count=$(jq '.installed | length // 0' "$BUNDLE/manifests/composer-globals.json" 2>/dev/null || echo 0)
  fi

  log_lane "C" "scan" "ok" "mise:$mise_tools pipx:$pipx_count npm:$npm_count cargo:$cargo_count gem:$gem_count go:$go_count composer:$composer_count"

  jq -n \
    --arg ts "$(iso_ts)" \
    --argjson mise_tools "${mise_tools:-[]}" \
    --argjson pipx_count "${pipx_count:-0}" \
    --argjson npm_count "${npm_count:-0}" \
    --argjson cargo_count "${cargo_count:-0}" \
    --argjson gem_count "${gem_count:-0}" \
    --argjson go_count "${go_count:-0}" \
    --argjson composer_count "${composer_count:-0}" \
    '{
      name: "Language Toolchains + Globals",
      scanned_at: $ts,
      items: {
        "C1.mise":      { tools_pinned: $mise_tools },
        "C2.pipx":      { envs: $pipx_count },
        "C3.npm":       { globals: $npm_count },
        "C4.cargo":     { installs: $cargo_count },
        "C5.gem":       { count: $gem_count },
        "C6.go_bin":    { count: $go_count },
        "C7.composer":  { globals: $composer_count }
      }
    }'
}

# -----------------------------------------------------------------------------
# Lane D - GUI App Configs
# -----------------------------------------------------------------------------
scan_lane_d() {
  local defaults_count=0 appsupport_count=0 containers_count=0 group_containers_count=0
  local user_fonts=0 system_fonts=0 stickies_count=0 mail_rules_present=false

  defaults_count=$(defaults domains 2>/dev/null | tr ',' '\n' | grep -cvE '^\s*$' || echo 0)
  appsupport_count=$(ls -1 "$HOME/Library/Application Support" 2>/dev/null | wc -l | tr -d ' ' || echo 0)
  containers_count=$(ls -1 "$HOME/Library/Containers" 2>/dev/null | wc -l | tr -d ' ' || echo 0)
  group_containers_count=$(ls -1 "$HOME/Library/Group Containers" 2>/dev/null | wc -l | tr -d ' ' || echo 0)
  user_fonts=$(ls -1 "$HOME/Library/Fonts" 2>/dev/null | wc -l | tr -d ' ' || echo 0)
  system_fonts=$(ls -1 /Library/Fonts 2>/dev/null | wc -l | tr -d ' ' || echo 0)

  if [ -d "$HOME/Library/Containers/com.apple.Stickies/Data/Library/Stickies" ]; then
    stickies_count=$(ls -1 "$HOME/Library/Containers/com.apple.Stickies/Data/Library/Stickies" 2>/dev/null | wc -l | tr -d ' ' || echo 0)
  fi

  local mail_v_dir
  mail_v_dir=$(ls -d "$HOME"/Library/Mail/V* 2>/dev/null | head -1 || echo "")
  if [ -n "$mail_v_dir" ] && [ -f "$mail_v_dir/MailData/SyncedRules.plist" ]; then
    mail_rules_present=true
  fi

  log_lane "D" "scan" "ok" "defaults:$defaults_count appsupport:$appsupport_count containers:$containers_count fonts:$user_fonts stickies:$stickies_count"

  jq -n \
    --arg ts "$(iso_ts)" \
    --argjson defaults_count "${defaults_count:-0}" \
    --argjson appsupport_count "${appsupport_count:-0}" \
    --argjson containers_count "${containers_count:-0}" \
    --argjson group_containers_count "${group_containers_count:-0}" \
    --argjson user_fonts "${user_fonts:-0}" \
    --argjson system_fonts "${system_fonts:-0}" \
    --argjson stickies_count "${stickies_count:-0}" \
    --argjson mail_rules_present "${mail_rules_present:-false}" \
    '{
      name: "GUI App Configs",
      scanned_at: $ts,
      items: {
        "D1.defaults_domains":   { count: $defaults_count },
        "D2.application_support":{ count: $appsupport_count },
        "D3.containers":         { count: $containers_count },
        "D3.group_containers":   { count: $group_containers_count },
        "D4.user_fonts":         { count: $user_fonts },
        "D4.system_fonts":       { count: $system_fonts },
        "D5.stickies":           { count: $stickies_count },
        "D5.mail_rules":         { present: $mail_rules_present }
      }
    }'
}

# -----------------------------------------------------------------------------
# Lane E - Browsers
# -----------------------------------------------------------------------------
scan_lane_e() {
  local browsers_present="[]" chrome_ext_count=0

  declare -a browsers=()
  [ -d "$HOME/Library/Application Support/Google/Chrome" ] && browsers+=('"Chrome"')
  [ -d "$HOME/Library/Application Support/BraveSoftware/Brave-Browser" ] && browsers+=('"Brave"')
  [ -d "$HOME/Library/Application Support/Firefox/Profiles" ] && browsers+=('"Firefox"')
  [ -d "$HOME/Library/Application Support/Arc" ] && browsers+=('"Arc"')
  [ -d "$HOME/Library/Application Support/Microsoft Edge" ] && browsers+=('"Edge"')
  [ -d "$HOME/Library/Safari" ] && browsers+=('"Safari"')

  if [ ${#browsers[@]} -gt 0 ]; then
    browsers_present="[$(IFS=,; echo "${browsers[*]}")]"
  fi

  local chrome_ext_dir="$HOME/Library/Application Support/Google/Chrome/Default/Extensions"
  [ -d "$chrome_ext_dir" ] && chrome_ext_count=$(ls -1 "$chrome_ext_dir" 2>/dev/null | wc -l | tr -d ' ' || echo 0)

  log_lane "E" "scan" "ok" "browsers:${#browsers[@]} chrome_ext:$chrome_ext_count"

  jq -n \
    --arg ts "$(iso_ts)" \
    --argjson browsers_present "${browsers_present:-[]}" \
    --argjson chrome_ext_count "${chrome_ext_count:-0}" \
    '{
      name: "Browsers",
      scanned_at: $ts,
      items: {
        "E.detected":      { browsers: $browsers_present },
        "E.chrome_ext":    { count: $chrome_ext_count }
      }
    }'
}

# -----------------------------------------------------------------------------
# Lane F - IDEs + Terminals
# -----------------------------------------------------------------------------
scan_lane_f() {
  local vscode_count=0 cursor_count=0 zed_present=false jetbrains_dirs=0
  local iterm2_present=false warp_present=false ghostty_present=false alacritty_present=false kitty_present=false

  command -v code >/dev/null 2>&1 && vscode_count=$(code --list-extensions 2>/dev/null | wc -l | tr -d ' ' || echo 0)
  command -v cursor >/dev/null 2>&1 && cursor_count=$(cursor --list-extensions 2>/dev/null | wc -l | tr -d ' ' || echo 0)
  [ -f "$HOME/.config/zed/settings.json" ] && zed_present=true
  [ -d "$HOME/Library/Application Support/JetBrains" ] && jetbrains_dirs=$(ls -1 "$HOME/Library/Application Support/JetBrains" 2>/dev/null | wc -l | tr -d ' ' || echo 0)
  [ -f "$HOME/Library/Preferences/com.googlecode.iterm2.plist" ] && iterm2_present=true
  [ -d "$HOME/Library/Application Support/dev.warp.Warp-Stable" ] && warp_present=true
  [ -f "$HOME/.config/ghostty/config" ] && ghostty_present=true
  [ -f "$HOME/.config/alacritty/alacritty.toml" ] && alacritty_present=true
  [ -f "$HOME/.config/kitty/kitty.conf" ] && kitty_present=true

  log_lane "F" "scan" "ok" "vscode:$vscode_count cursor:$cursor_count zed:$zed_present jetbrains:$jetbrains_dirs"

  jq -n \
    --arg ts "$(iso_ts)" \
    --argjson vscode_count "${vscode_count:-0}" \
    --argjson cursor_count "${cursor_count:-0}" \
    --argjson zed_present "${zed_present:-false}" \
    --argjson jetbrains_dirs "${jetbrains_dirs:-[]}" \
    --argjson iterm2_present "${iterm2_present:-false}" \
    --argjson warp_present "${warp_present:-false}" \
    --argjson ghostty_present "${ghostty_present:-false}" \
    --argjson alacritty_present "${alacritty_present:-false}" \
    --argjson kitty_present "${kitty_present:-false}" \
    '{
      name: "IDEs + Terminals",
      scanned_at: $ts,
      items: {
        "F1.vscode":     { extensions: $vscode_count },
        "F1.cursor":     { extensions: $cursor_count },
        "F2.zed":        { present: $zed_present },
        "F3.jetbrains":  { ide_configs: $jetbrains_dirs },
        "F5.iterm2":     { present: $iterm2_present },
        "F5.warp":       { present: $warp_present },
        "F5.ghostty":    { present: $ghostty_present },
        "F5.alacritty":  { present: $alacritty_present },
        "F5.kitty":      { present: $kitty_present }
      }
    }'
}

# -----------------------------------------------------------------------------
# Lane G - Databases + Containers
# -----------------------------------------------------------------------------
scan_lane_g() {
  local pg_version="" pg_dbs=0 pg_size_bytes=0
  local mysql_present=false redis_present=false mongo_present=false
  local docker_contexts=0 kube_present=false krew_count=0 helm_repos=0

  if command -v psql >/dev/null 2>&1; then
    pg_version=$(psql --version 2>/dev/null | awk '{print $3}' || echo "")
    pg_dbs=$(psql -U "$(whoami)" -tAc "SELECT count(*) FROM pg_database WHERE datistemplate=false;" 2>/dev/null | tr -d ' ' || echo 0)
    for d in /opt/homebrew/var/postgresql@*; do
      if [ -d "$d" ]; then
        local sz
        sz=$(du -sk "$d" 2>/dev/null | awk '{print $1*1024}' || echo 0)
        pg_size_bytes=$((pg_size_bytes + sz))
      fi
    done
  fi

  command -v mysql >/dev/null 2>&1 && mysql_present=true
  [ -f /opt/homebrew/var/db/redis/dump.rdb ] && redis_present=true
  command -v mongosh >/dev/null 2>&1 && mongo_present=true
  [ -d "$HOME/.docker/contexts/meta" ] && docker_contexts=$(ls -1 "$HOME/.docker/contexts/meta" 2>/dev/null | wc -l | tr -d ' ' || echo 0)
  [ -f "$HOME/.kube/config" ] && kube_present=true
  command -v kubectl >/dev/null 2>&1 && krew_count=$(kubectl krew list 2>/dev/null | tail -n +2 | wc -l | tr -d ' ' || echo 0)
  command -v helm >/dev/null 2>&1 && helm_repos=$(helm repo list 2>/dev/null | tail -n +2 | wc -l | tr -d ' ' || echo 0)

  log_lane "G" "scan" "ok" "pg:$pg_dbs mysql:$mysql_present redis:$redis_present mongo:$mongo_present docker:$docker_contexts kube:$kube_present"

  jq -n \
    --arg ts "$(iso_ts)" \
    --arg pg_version "$pg_version" \
    --argjson pg_dbs "${pg_dbs:-[]}" \
    --argjson pg_size_bytes "${pg_size_bytes:-0}" \
    --argjson mysql_present "${mysql_present:-false}" \
    --argjson redis_present "${redis_present:-false}" \
    --argjson mongo_present "${mongo_present:-false}" \
    --argjson docker_contexts "${docker_contexts:-[]}" \
    --argjson kube_present "${kube_present:-false}" \
    --argjson krew_count "${krew_count:-0}" \
    --argjson helm_repos "${helm_repos:-[]}" \
    '{
      name: "Databases + Containers",
      scanned_at: $ts,
      items: {
        "G1.postgres": { version: $pg_version, databases: $pg_dbs, size_bytes: $pg_size_bytes },
        "G2.mysql":    { present: $mysql_present },
        "G3.redis":    { present: $redis_present },
        "G4.mongo":    { present: $mongo_present },
        "G5.docker":   { contexts: $docker_contexts },
        "G6.kube":     { config_present: $kube_present, krew_plugins: $krew_count },
        "G7.helm":     { repos: $helm_repos }
      }
    }'
}

# -----------------------------------------------------------------------------
# Lane H - Background Services
# -----------------------------------------------------------------------------
scan_lane_h() {
  local user_launchagents=0 system_launchagents=0 system_launchdaemons=0
  local brew_services_running=0 pm2_processes=0 cron_lines=0 login_items=0

  user_launchagents=$(ls -1 "$HOME/Library/LaunchAgents" 2>/dev/null | grep -c '\.plist$' || echo 0)
  system_launchagents=$(ls -1 /Library/LaunchAgents 2>/dev/null | grep -c '\.plist$' || echo 0)
  system_launchdaemons=$(ls -1 /Library/LaunchDaemons 2>/dev/null | grep -c '\.plist$' || echo 0)

  if command -v brew >/dev/null 2>&1; then
    brew services list > "$BUNDLE/manifests/brew-services-running.txt" 2>/dev/null || true
    brew_services_running=$(awk '$2=="started"' "$BUNDLE/manifests/brew-services-running.txt" 2>/dev/null | wc -l | tr -d ' ' || echo 0)
  fi

  if command -v pm2 >/dev/null 2>&1; then
    pm2_processes=$(pm2 jlist 2>/dev/null | jq 'length // 0' 2>/dev/null || echo 0)
  fi

  crontab -l > "$BUNDLE/manifests/user-crontab.txt" 2>/dev/null || echo "" > "$BUNDLE/manifests/user-crontab.txt"
  cron_lines=$(grep -cvE '^(#|$)' "$BUNDLE/manifests/user-crontab.txt" 2>/dev/null || echo 0)

  # Login Items via AppleScript (incomplete by design - SMAppService apps invisible)
  login_items=$(osascript -e 'tell application "System Events" to get the name of every login item' 2>/dev/null | tr ',' '\n' | grep -cvE '^\s*$' || echo 0)

  log_lane "H" "scan" "ok" "user_LA:$user_launchagents sys_LA:$system_launchagents sys_LD:$system_launchdaemons brew_running:$brew_services_running pm2:$pm2_processes cron:$cron_lines login_items:$login_items"

  jq -n \
    --arg ts "$(iso_ts)" \
    --argjson user_launchagents "${user_launchagents:-0}" \
    --argjson system_launchagents "${system_launchagents:-0}" \
    --argjson system_launchdaemons "${system_launchdaemons:-0}" \
    --argjson brew_services_running "${brew_services_running:-false}" \
    --argjson pm2_processes "${pm2_processes:-[]}" \
    --argjson cron_lines "${cron_lines:-0}" \
    --argjson login_items "${login_items:-0}" \
    '{
      name: "Background Services",
      scanned_at: $ts,
      items: {
        "H1.user_launchagents":   { count: $user_launchagents },
        "H2.system_launchagents": { count: $system_launchagents },
        "H2.system_launchdaemons":{ count: $system_launchdaemons },
        "H3.brew_services_running":{ count: $brew_services_running },
        "H4.pm2_processes":       { count: $pm2_processes },
        "H5.cron_lines":          { count: $cron_lines },
        "H6.login_items":         { count: $login_items, note: "AppleScript probe incomplete; SMAppService apps not listed" },
        "H7.launchpad":           { note: "lporg snapshot optional, archived 2025-09" }
      }
    }'
}

# -----------------------------------------------------------------------------
# Lane I - Credentials + Auth (presence only, never values)
# -----------------------------------------------------------------------------
scan_lane_i() {
  local git_config_present=false gh_hosts_present=false
  local aws_profiles=0 gcloud_present=false azure_present=false cloudflared_present=false doctl_present=false
  local tokens_present=0 ssh_keys=0 gpg_secret_keys=0 wg_tunnels=0

  [ -f "$HOME/.gitconfig" ] && git_config_present=true
  [ -f "$HOME/.config/gh/hosts.yml" ] && gh_hosts_present=true
  [ -f "$HOME/.aws/credentials" ] && aws_profiles=$(grep -c '^\[' "$HOME/.aws/credentials" 2>/dev/null || echo 0)
  [ -d "$HOME/.config/gcloud" ] && gcloud_present=true
  [ -d "$HOME/.azure" ] && azure_present=true
  [ -d "$HOME/.cloudflared" ] && cloudflared_present=true
  [ -d "$HOME/.config/doctl" ] && doctl_present=true

  for tf in "$HOME/.npmrc" "$HOME/.cargo/credentials.toml" "$HOME/.gem/credentials" "$HOME/.config/composer/auth.json" "$HOME/.pypirc" "$HOME/.huggingface/token" "$HOME/.netrc"; do
    [ -f "$tf" ] && tokens_present=$((tokens_present + 1))
  done

  if [ -d "$HOME/.ssh" ]; then
    ssh_keys=$(find "$HOME/.ssh" -maxdepth 1 -name 'id_*' ! -name '*.pub' 2>/dev/null | wc -l | tr -d ' ' || echo 0)
  fi

  if command -v gpg >/dev/null 2>&1; then
    gpg_secret_keys=$(gpg --list-secret-keys --with-colons 2>/dev/null | grep -c '^sec:' || echo 0)
  fi

  local wg_dir="$HOME/Library/Group Containers/group.com.wireguard.macos/Library/Application Support/WireGuard"
  [ -d "$wg_dir" ] && wg_tunnels=$(ls -1 "$wg_dir" 2>/dev/null | wc -l | tr -d ' ' || echo 0)

  log_lane "I" "scan" "ok" "git:$git_config_present gh:$gh_hosts_present aws:$aws_profiles gcloud:$gcloud_present ssh_keys:$ssh_keys gpg:$gpg_secret_keys wg:$wg_tunnels"

  jq -n \
    --arg ts "$(iso_ts)" \
    --argjson git_config_present "${git_config_present:-false}" \
    --argjson gh_hosts_present "${gh_hosts_present:-false}" \
    --argjson aws_profiles "${aws_profiles:-[]}" \
    --argjson gcloud_present "${gcloud_present:-false}" \
    --argjson azure_present "${azure_present:-false}" \
    --argjson cloudflared_present "${cloudflared_present:-false}" \
    --argjson doctl_present "${doctl_present:-false}" \
    --argjson tokens_present "${tokens_present:-false}" \
    --argjson ssh_keys "${ssh_keys:-[]}" \
    --argjson gpg_secret_keys "${gpg_secret_keys:-[]}" \
    --argjson wg_tunnels "${wg_tunnels:-[]}" \
    '{
      name: "Credentials + Auth",
      scanned_at: $ts,
      items: {
        "I1.git_config":     { present: $git_config_present },
        "I1.gh_hosts":       { present: $gh_hosts_present },
        "I2.aws_profiles":   { count: $aws_profiles },
        "I2.gcloud":         { present: $gcloud_present },
        "I2.azure":          { present: $azure_present },
        "I2.cloudflared":    { present: $cloudflared_present },
        "I2.doctl":          { present: $doctl_present },
        "I3.cli_token_files":{ count: $tokens_present },
        "I4.ssh_keys":       { count: $ssh_keys },
        "I5.gpg_secret_keys":{ count: $gpg_secret_keys },
        "I6.wireguard":      { tunnels: $wg_tunnels }
      }
    }'
}

# -----------------------------------------------------------------------------
# Lane J - Manual / Deferred (checklist, not a scan)
# -----------------------------------------------------------------------------
scan_lane_j() {
  local tcc_accessible=false tcc_grant_count=0
  local tcc_db="$HOME/Library/Application Support/com.apple.TCC/TCC.db"
  if [ -f "$tcc_db" ] && sqlite3 "$tcc_db" ".tables" >/dev/null 2>&1; then
    tcc_accessible=true
    tcc_grant_count=$(sqlite3 "$tcc_db" "SELECT count(*) FROM access;" 2>/dev/null || echo 0)
  fi

  log_lane "J" "scan" "ok" "tcc_accessible:$tcc_accessible grants:$tcc_grant_count"

  jq -n \
    --arg ts "$(iso_ts)" \
    --argjson tcc_accessible "${tcc_accessible:-false}" \
    --argjson tcc_grant_count "${tcc_grant_count:-0}" \
    '{
      name: "Manual / Deferred",
      scanned_at: $ts,
      items: {
        "J1.icloud_keychain": { note: "Sign in to iCloud on new Mac, enable Keychain, verify WiFi auto-joins" },
        "J2.app_licenses":    { note: "Deactivate offline-licensed apps on OLD Mac BEFORE wipe: Backblaze, Adobe, JetBrains, Setapp, Plex" },
        "J3.tcc":             { accessible: $tcc_accessible, grant_count: $tcc_grant_count, note: "Re-grant FDA / Accessibility / Camera / Mic per app" },
        "J4.time_machine":    { note: "Re-add Time Machine + Spotlight exclusions via System Settings" },
        "J5.rosetta":         { note: "Run `arch` after first terminal launch; if i386, relaunch natively" },
        "J6.tahoe_sip":       { note: "If new Mac on macOS 26, audit /Library/LaunchDaemons restore for SMAppService rewrite" }
      }
    }'
}

# -----------------------------------------------------------------------------
# Assemble the manifest
# -----------------------------------------------------------------------------
LANE_A=$(scan_lane_a)
LANE_B=$(scan_lane_b)
LANE_C=$(scan_lane_c)
LANE_D=$(scan_lane_d)
LANE_E=$(scan_lane_e)
LANE_F=$(scan_lane_f)
LANE_G=$(scan_lane_g)
LANE_H=$(scan_lane_h)
LANE_I=$(scan_lane_i)
LANE_J=$(scan_lane_j)

jq -n \
  --arg ts "$(iso_ts)" \
  --arg hostname "$HOSTNAME_VAL" \
  --arg macos_version "$MACOS_VER" \
  --arg macos_codename "$MACOS_CODENAME" \
  --arg arch "$ARCH_VAL" \
  --arg user "$USER_VAL" \
  --argjson lane_a "${LANE_A:-0}" \
  --argjson lane_b "${LANE_B:-0}" \
  --argjson lane_c "${LANE_C:-0}" \
  --argjson lane_d "${LANE_D:-0}" \
  --argjson lane_e "${LANE_E:-0}" \
  --argjson lane_f "${LANE_F:-0}" \
  --argjson lane_g "${LANE_G:-0}" \
  --argjson lane_h "${LANE_H:-0}" \
  --argjson lane_i "${LANE_I:-0}" \
  --argjson lane_j "${LANE_J:-0}" \
  --argjson opt_outs "${PRIOR_OPTOUTS:-[]}" \
  '{
    version: "1",
    generated_at: $ts,
    host: {
      hostname: $hostname,
      macos_version: $macos_version,
      macos_codename: $macos_codename,
      arch: $arch,
      user: $user
    },
    target: {
      macos_version: null,
      macos_codename: null,
      notes: "Filled in by restore phase on the new Mac"
    },
    lanes: {
      A: $lane_a, B: $lane_b, C: $lane_c, D: $lane_d, E: $lane_e,
      F: $lane_f, G: $lane_g, H: $lane_h, I: $lane_i, J: $lane_j
    },
    opt_outs: $opt_outs,
    preflight: { checked_at: null, passes: [], warnings: [], blockers: [] },
    bundle: { size_estimate_bytes: null, lane_count: 10, captured_at: null }
  }' > "$WORK_MANIFEST"

log_lane "-" "scan_complete" "ok" "manifest written to $WORK_MANIFEST"

# -----------------------------------------------------------------------------
# Mode-specific post-processing
# -----------------------------------------------------------------------------
if [ "$MODE" = "save-baseline" ]; then
  mkdir -p "$BASELINE_DIR"
  cp "$WORK_MANIFEST" "$BASELINE_FILE"
  log_lane "-" "baseline_saved" "ok" "$BASELINE_FILE"
  echo "Baseline saved to $BASELINE_FILE"
  exit 0
fi

if [ "$MODE" = "diff-baseline" ]; then
  if [ ! -f "$BASELINE_FILE" ]; then
    echo "No baseline at $BASELINE_FILE - run with --save-baseline first" >&2
    exit 3
  fi

  echo "Drift since baseline ($(jq -r .generated_at "$BASELINE_FILE"))"
  echo "================================================================"

  diff_field() {
    local lane_id="$1" item="$2" label="$3"
    local before after
    before=$(jq -r ".lanes.\"$lane_id\".items.\"$item\".count // .lanes.\"$lane_id\".items.\"$item\".present // \"-\"" "$BASELINE_FILE")
    after=$(jq -r ".lanes.\"$lane_id\".items.\"$item\".count // .lanes.\"$lane_id\".items.\"$item\".present // \"-\"" "$WORK_MANIFEST")
    if [ "$before" != "$after" ]; then
      echo "  ~ $label: $before -> $after"
    elif [ "$VERBOSE" = "1" ]; then
      echo "  = $label: $before (unchanged)"
    fi
  }

  echo
  echo "Lane A  Applications"
  diff_field A "A1.brew_formulae" "brew formulae"
  diff_field A "A1.brew_casks"    "brew casks"
  diff_field A "A2.mas_apps"      "MAS apps"
  diff_field A "A3.orphan_apps"   "orphan apps"

  echo
  echo "Lane B  Shell + PATH"
  diff_field B "B2.dotfiles_present" "dotfiles present"
  diff_field B "B3.etc_paths_d"      "/etc/paths.d entries"
  diff_field B "B4.home_bin"         "~/bin scripts"

  echo
  echo "Lane C  Language toolchains"
  diff_field C "C1.mise"     "mise tools"
  diff_field C "C2.pipx"     "pipx envs"
  diff_field C "C3.npm"      "npm globals"
  diff_field C "C4.cargo"    "cargo installs"

  echo
  echo "Lane D  GUI configs"
  diff_field D "D1.defaults_domains"    "defaults domains"
  diff_field D "D2.application_support" "AppSupport dirs"
  diff_field D "D4.user_fonts"          "user fonts"

  echo
  echo "Lane F  IDEs"
  diff_field F "F1.vscode"  "VS Code extensions"
  diff_field F "F1.cursor"  "Cursor extensions"

  echo
  echo "Lane H  Background services"
  diff_field H "H1.user_launchagents"     "user LaunchAgents"
  diff_field H "H3.brew_services_running" "brew services running"
  diff_field H "H4.pm2_processes"         "PM2 processes"

  echo
  echo "Lane I  Credentials"
  diff_field I "I2.aws_profiles"  "AWS profiles"
  diff_field I "I4.ssh_keys"      "SSH keys"
  diff_field I "I5.gpg_secret_keys" "GPG secret keys"

  exit 0
fi

# Default mode: print summary
echo
echo "Mac inventory complete. Manifest at $BUNDLE/manifest.json"
echo
jq -r '
"  Lane A  Applications",
"          \(.lanes.A.items."A1.brew_formulae".count) brew formulae + \(.lanes.A.items."A1.brew_casks".count) casks + \(.lanes.A.items."A1.brew_taps".count) taps",
"          \(.lanes.A.items."A2.mas_apps".count) Mac App Store apps",
"          \(.lanes.A.items."A3.orphan_apps".count) orphan apps in /Applications",
"",
"  Lane B  Shell + PATH + Custom scripts",
"          chezmoi: \(.lanes.B.items."B1.chezmoi".source // "not configured") (\(.lanes.B.items."B1.chezmoi".unpushed_commits) unpushed)",
"          \(.lanes.B.items."B2.dotfiles_present".count) top-level dotfiles",
"          /etc/paths.d: \(.lanes.B.items."B3.etc_paths_d".count) entries",
"          ~/bin: \(.lanes.B.items."B4.home_bin".count), ~/.local/bin: \(.lanes.B.items."B4.home_local_bin".count)",
"          /etc/hosts custom lines: \(.lanes.B.items."B5.etc_hosts_lines".count), sudoers.d: \(.lanes.B.items."B5.sudoers_d_files".count)",
"",
"  Lane C  Language toolchains + globals",
"          mise: \(.lanes.C.items."C1.mise".tools_pinned) tools pinned",
"          pipx: \(.lanes.C.items."C2.pipx".envs) envs, npm globals: \(.lanes.C.items."C3.npm".globals)",
"          cargo: \(.lanes.C.items."C4.cargo".installs), gem: \(.lanes.C.items."C5.gem".count), go: \(.lanes.C.items."C6.go_bin".count), composer: \(.lanes.C.items."C7.composer".globals)",
"",
"  Lane D  GUI app configs",
"          \(.lanes.D.items."D1.defaults_domains".count) defaults domains",
"          ~/Library/Application Support: \(.lanes.D.items."D2.application_support".count) dirs",
"          Containers: \(.lanes.D.items."D3.containers".count), Group Containers: \(.lanes.D.items."D3.group_containers".count)",
"          User fonts: \(.lanes.D.items."D4.user_fonts".count), Stickies: \(.lanes.D.items."D5.stickies".count) notes, Mail rules: \(.lanes.D.items."D5.mail_rules".present)",
"",
"  Lane E  Browsers",
"          Detected: \(.lanes.E.items."E.detected".browsers | join(", "))",
"          Chrome extensions: \(.lanes.E.items."E.chrome_ext".count)",
"",
"  Lane F  IDEs + Terminals",
"          VS Code: \(.lanes.F.items."F1.vscode".extensions) extensions, Cursor: \(.lanes.F.items."F1.cursor".extensions)",
"          Zed: \(.lanes.F.items."F2.zed".present), JetBrains: \(.lanes.F.items."F3.jetbrains".ide_configs) configs",
"          iTerm2: \(.lanes.F.items."F5.iterm2".present), Warp: \(.lanes.F.items."F5.warp".present), Ghostty: \(.lanes.F.items."F5.ghostty".present)",
"",
"  Lane G  Databases + Containers",
"          Postgres \(.lanes.G.items."G1.postgres".version // "n/a"): \(.lanes.G.items."G1.postgres".databases) DBs (\(.lanes.G.items."G1.postgres".size_bytes) bytes)",
"          MySQL: \(.lanes.G.items."G2.mysql".present), Redis: \(.lanes.G.items."G3.redis".present), MongoDB: \(.lanes.G.items."G4.mongo".present)",
"          Docker contexts: \(.lanes.G.items."G5.docker".contexts), Kube config: \(.lanes.G.items."G6.kube".config_present), krew: \(.lanes.G.items."G6.kube".krew_plugins), Helm repos: \(.lanes.G.items."G7.helm".repos)",
"",
"  Lane H  Background services",
"          User LaunchAgents: \(.lanes.H.items."H1.user_launchagents".count)",
"          System LaunchAgents: \(.lanes.H.items."H2.system_launchagents".count), LaunchDaemons: \(.lanes.H.items."H2.system_launchdaemons".count)",
"          brew services running: \(.lanes.H.items."H3.brew_services_running".count), PM2: \(.lanes.H.items."H4.pm2_processes".count), cron: \(.lanes.H.items."H5.cron_lines".count) lines, Login Items: \(.lanes.H.items."H6.login_items".count)",
"",
"  Lane I  Credentials + Auth",
"          git: \(.lanes.I.items."I1.git_config".present), gh: \(.lanes.I.items."I1.gh_hosts".present)",
"          AWS profiles: \(.lanes.I.items."I2.aws_profiles".count), gcloud: \(.lanes.I.items."I2.gcloud".present), Azure: \(.lanes.I.items."I2.azure".present)",
"          Cloudflare: \(.lanes.I.items."I2.cloudflared".present), DigitalOcean: \(.lanes.I.items."I2.doctl".present)",
"          CLI token files: \(.lanes.I.items."I3.cli_token_files".count) present",
"          SSH keys: \(.lanes.I.items."I4.ssh_keys".count), GPG secret keys: \(.lanes.I.items."I5.gpg_secret_keys".count), WireGuard tunnels: \(.lanes.I.items."I6.wireguard".tunnels)",
"",
"  Lane J  Manual / Deferred",
"          6 items in post-restore checklist (TCC accessible: \(.lanes.J.items."J3.tcc".accessible), grants: \(.lanes.J.items."J3.tcc".grant_count))",
"",
"All of the above will be migrated. Anything you do NOT want me to handle?"
' "$WORK_MANIFEST"

exit 0
