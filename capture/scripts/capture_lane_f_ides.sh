#!/usr/bin/env bash
# capture_lane_f_ides.sh
# Lane F — IDEs + Terminals
#
# Sub-modules:
#   F1  VS Code  - extension list + settings/keybindings/snippets
#   F2  Cursor   - extension list + settings/keybindings/snippets
#   F3  Zed      - ~/.config/zed/
#   F4  Nvim     - ~/.config/nvim/
#   F5  Emacs    - ~/.emacs.d/ or ~/.config/emacs/
#   F6  JetBrains - rsync ~/Library/Application Support/JetBrains/
#   F7  iTerm2   - com.googlecode.iterm2.plist
#   F8  Warp     - dev.warp.Warp-Stable/ (cache-excluded)
#   F9  Ghostty, Alacritty, Kitty configs
#
# Opt-out keys:
#   opt_outs.lane_f
#   opt_outs.lane_f.{vscode,cursor,zed,nvim,emacs,jetbrains,iterm2,warp,ghostty,alacritty,kitty}

set -euo pipefail

BUNDLE="${BUNDLE:-$HOME/migration-bundle}"
DRY_RUN="${DRY_RUN:-0}"
FORCE="${FORCE:-0}"

for arg in "$@"; do
  case "$arg" in
    --force)   FORCE=1 ;;
    --dry-run) DRY_RUN=1 ;;
    *) echo "capture_lane_f_ides.sh: unknown arg: $arg" >&2; exit 2 ;;
  esac
done

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SUB_SKILL_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
SKILL_DIR="$(cd "$SUB_SKILL_DIR/.." && pwd)"
AUDIT="$SCRIPT_DIR/audit_log.sh"
DONE_HELPER="$SKILL_DIR/scripts/lane_done_marker.sh"
LANE_ID="lane-f-ides"
MANIFEST="$BUNDLE/manifest.json"

if [ ! -f "$MANIFEST" ]; then
  echo "capture_lane_f_ides.sh: $MANIFEST not found — run inventory first." >&2
  exit 3
fi

mkdir -p "$BUNDLE/ides" "$BUNDLE/.done" "$BUNDLE/dry-run-report"

opt_out_lane() { jq -e ".opt_outs.lane_f == true" "$MANIFEST" >/dev/null 2>&1; }
opt_out_sub()  { jq -e ".opt_outs.lane_f.$1 == true" "$MANIFEST" >/dev/null 2>&1; }

if opt_out_lane; then
  "$AUDIT" "$LANE_ID" lane skip "manifest.json opts out of entire Lane F"
  [ "$DRY_RUN" != "1" ] && bash "$DONE_HELPER" write "$LANE_ID"
  exit 0
fi

if [ "$FORCE" != "1" ] && bash "$DONE_HELPER" check "$LANE_ID" >/dev/null 2>&1; then
  "$AUDIT" "$LANE_ID" lane skip "Already done — use --force to re-capture"
  exit 0
fi

"$AUDIT" "$LANE_ID" lane start "Lane F — IDEs (dry_run=$DRY_RUN, force=$FORCE)"

# helper: capture one VS Code-family editor (vscode, cursor)
# usage: capture_vscode_family <name> <cli-cmd> <user-dir-name>
capture_vscode_family() {
  local name="$1"
  local cmd="$2"
  local user_dir_name="$3"
  local out_dir="$BUNDLE/ides/$name"
  local user_dir="$HOME/Library/Application Support/$user_dir_name/User"

  if command -v "$cmd" >/dev/null 2>&1; then
    if [ "$DRY_RUN" = "1" ]; then
      ext_count="$("$cmd" --list-extensions 2>/dev/null | wc -l | tr -d ' ' || echo 0)"
      "$AUDIT" "$LANE_ID" "$name" info "Would record $ext_count $name extensions"
    else
      "$cmd" --list-extensions > "$BUNDLE/ides/${name}-extensions.txt" 2>/dev/null \
        && "$AUDIT" "$LANE_ID" "$name" ok "Wrote ides/${name}-extensions.txt" \
        || "$AUDIT" "$LANE_ID" "$name" warn "${cmd} --list-extensions returned non-zero"
    fi
  else
    "$AUDIT" "$LANE_ID" "$name" info "$cmd CLI not installed (settings may still be captured)"
  fi

  if [ -d "$user_dir" ]; then
    if [ "$DRY_RUN" = "1" ]; then
      "$AUDIT" "$LANE_ID" "$name" info "Would copy $name settings + keybindings + snippets"
    else
      mkdir -p "$out_dir"
      [ -f "$user_dir/settings.json" ]    && cp -p "$user_dir/settings.json"    "$out_dir/"
      [ -f "$user_dir/keybindings.json" ] && cp -p "$user_dir/keybindings.json" "$out_dir/"
      [ -d "$user_dir/snippets" ]         && rsync -a "$user_dir/snippets/" "$out_dir/snippets/" 2>/dev/null
      "$AUDIT" "$LANE_ID" "$name" ok "Wrote ides/$name/"
    fi
  fi
}

# --- F1. VS Code ---------------------------------------------------------

if ! opt_out_sub vscode; then
  capture_vscode_family vscode code Code
else
  "$AUDIT" "$LANE_ID" vscode skip "Opted out via manifest"
fi

# --- F2. Cursor ---------------------------------------------------------

if ! opt_out_sub cursor; then
  capture_vscode_family cursor cursor Cursor
  "$AUDIT" "$LANE_ID" cursor info "Cursor extension marketplace partially diverges from VS Code — some may fail to reinstall"
else
  "$AUDIT" "$LANE_ID" cursor skip "Opted out via manifest"
fi

# --- F3. Zed ------------------------------------------------------------

if ! opt_out_sub zed; then
  if [ -d ~/.config/zed ]; then
    if [ "$DRY_RUN" = "1" ]; then
      "$AUDIT" "$LANE_ID" zed info "Would copy ~/.config/zed"
    else
      rsync -a ~/.config/zed/ "$BUNDLE/ides/zed/" 2>/dev/null \
        && "$AUDIT" "$LANE_ID" zed ok "Wrote ides/zed/" \
        || "$AUDIT" "$LANE_ID" zed warn "Zed rsync returned non-zero"
    fi
  else
    "$AUDIT" "$LANE_ID" zed skip "No ~/.config/zed directory"
  fi
else
  "$AUDIT" "$LANE_ID" zed skip "Opted out via manifest"
fi

# --- F4. Nvim -----------------------------------------------------------

if ! opt_out_sub nvim; then
  if [ -d ~/.config/nvim ]; then
    if [ "$DRY_RUN" = "1" ]; then
      "$AUDIT" "$LANE_ID" nvim info "Would copy ~/.config/nvim"
    else
      rsync -a ~/.config/nvim/ "$BUNDLE/ides/nvim/" 2>/dev/null \
        && "$AUDIT" "$LANE_ID" nvim ok "Wrote ides/nvim/" \
        || "$AUDIT" "$LANE_ID" nvim warn "Nvim rsync returned non-zero"
    fi
  else
    "$AUDIT" "$LANE_ID" nvim skip "No ~/.config/nvim directory"
  fi
else
  "$AUDIT" "$LANE_ID" nvim skip "Opted out via manifest"
fi

# --- F5. Emacs ----------------------------------------------------------

if ! opt_out_sub emacs; then
  copied=0
  if [ -d ~/.emacs.d ]; then
    if [ "$DRY_RUN" = "1" ]; then
      "$AUDIT" "$LANE_ID" emacs info "Would copy ~/.emacs.d"
    else
      rsync -a ~/.emacs.d/ "$BUNDLE/ides/emacs/" 2>/dev/null && copied=$((copied + 1))
    fi
  fi
  if [ -d ~/.config/emacs ]; then
    if [ "$DRY_RUN" = "1" ]; then
      "$AUDIT" "$LANE_ID" emacs info "Would copy ~/.config/emacs"
    else
      rsync -a ~/.config/emacs/ "$BUNDLE/ides/emacs-config/" 2>/dev/null && copied=$((copied + 1))
    fi
  fi
  if [ "$DRY_RUN" != "1" ]; then
    if [ "$copied" -gt 0 ]; then
      "$AUDIT" "$LANE_ID" emacs ok "Captured $copied Emacs config dir(s)"
    else
      "$AUDIT" "$LANE_ID" emacs skip "No Emacs config directories found"
    fi
  fi
else
  "$AUDIT" "$LANE_ID" emacs skip "Opted out via manifest"
fi

# --- F6. JetBrains ------------------------------------------------------

if ! opt_out_sub jetbrains; then
  jb="$HOME/Library/Application Support/JetBrains"
  if [ -d "$jb" ]; then
    if [ "$DRY_RUN" = "1" ]; then
      size_mb="$(du -sm "$jb" 2>/dev/null | awk '{print $1}' || echo 0)"
      "$AUDIT" "$LANE_ID" jetbrains info "Would rsync JetBrains (~${size_mb} MB)"
    else
      "$AUDIT" "$LANE_ID" jetbrains start "Rsync JetBrains"
      mkdir -p "$BUNDLE/ides/jetbrains"
      if rsync -a "$jb/" "$BUNDLE/ides/jetbrains/" 2>/dev/null; then
        "$AUDIT" "$LANE_ID" jetbrains ok "Wrote ides/jetbrains/"
        "$AUDIT" "$LANE_ID" jetbrains info "Configs embed absolute paths (SDK roots) — fix via File > Project Structure on new Mac"
      else
        "$AUDIT" "$LANE_ID" jetbrains warn "JetBrains rsync returned non-zero"
      fi
    fi
  else
    "$AUDIT" "$LANE_ID" jetbrains skip "No JetBrains AppSupport directory"
  fi
else
  "$AUDIT" "$LANE_ID" jetbrains skip "Opted out via manifest"
fi

# --- F7. iTerm2 ---------------------------------------------------------

if ! opt_out_sub iterm2; then
  iterm_plist="$HOME/Library/Preferences/com.googlecode.iterm2.plist"
  if [ -f "$iterm_plist" ]; then
    if [ "$DRY_RUN" = "1" ]; then
      "$AUDIT" "$LANE_ID" iterm2 info "Would copy iTerm2 plist"
    else
      cp -p "$iterm_plist" "$BUNDLE/ides/iterm2.plist" \
        && "$AUDIT" "$LANE_ID" iterm2 ok "Wrote ides/iterm2.plist (binary plist)" \
        || "$AUDIT" "$LANE_ID" iterm2 warn "iTerm2 plist copy failed"
    fi
  else
    "$AUDIT" "$LANE_ID" iterm2 skip "No iTerm2 plist found"
  fi
else
  "$AUDIT" "$LANE_ID" iterm2 skip "Opted out via manifest"
fi

# --- F8. Warp -----------------------------------------------------------

if ! opt_out_sub warp; then
  warp_dir="$HOME/Library/Application Support/dev.warp.Warp-Stable"
  if [ -d "$warp_dir" ]; then
    if [ "$DRY_RUN" = "1" ]; then
      "$AUDIT" "$LANE_ID" warp info "Would rsync Warp (cache excluded)"
    else
      "$AUDIT" "$LANE_ID" warp start "Rsync Warp"
      mkdir -p "$BUNDLE/ides/warp"
      if rsync -a --exclude='Cache*' --exclude='*cache*' --exclude='Logs' \
        "$warp_dir/" "$BUNDLE/ides/warp/" 2>/dev/null; then
        "$AUDIT" "$LANE_ID" warp ok "Wrote ides/warp/"
      else
        "$AUDIT" "$LANE_ID" warp warn "Warp rsync returned non-zero"
      fi
    fi
  else
    "$AUDIT" "$LANE_ID" warp skip "No Warp data directory"
  fi
else
  "$AUDIT" "$LANE_ID" warp skip "Opted out via manifest"
fi

# --- F9. Ghostty / Alacritty / Kitty ------------------------------------

for term in ghostty alacritty kitty; do
  if ! opt_out_sub "$term"; then
    case "$term" in
      ghostty)   src=~/.config/ghostty/config;             dst="$BUNDLE/ides/ghostty-config" ;;
      alacritty) src=~/.config/alacritty/alacritty.toml;   dst="$BUNDLE/ides/alacritty.toml" ;;
      kitty)     src=~/.config/kitty/kitty.conf;           dst="$BUNDLE/ides/kitty.conf" ;;
    esac
    if [ -f "$src" ]; then
      if [ "$DRY_RUN" = "1" ]; then
        "$AUDIT" "$LANE_ID" "$term" info "Would copy $term config"
      else
        cp -p "$src" "$dst" \
          && "$AUDIT" "$LANE_ID" "$term" ok "Wrote $(basename "$dst")" \
          || "$AUDIT" "$LANE_ID" "$term" warn "$term config copy failed"
      fi
    fi
  else
    "$AUDIT" "$LANE_ID" "$term" skip "Opted out via manifest"
  fi
done

# --- done marker --------------------------------------------------------

if [ "$DRY_RUN" = "1" ]; then
  "$AUDIT" "$LANE_ID" lane info "Dry-run complete; no .done marker written"
else
  bash "$DONE_HELPER" write "$LANE_ID"
  "$AUDIT" "$LANE_ID" lane ok "Lane F capture complete"
fi
