#!/usr/bin/env bash
# restore_lane_f_ides.sh -- Lane F: VS Code + Cursor + Zed + JetBrains + Neovim/Emacs + terminals.

set -euo pipefail

PARENT="$(cd "$(dirname "$0")/../.." && pwd)"
BUNDLE="${BUNDLE:-$HOME/migration-bundle}"
LANE="lane-f-ides"

audit_log() {
  printf '{"ts":"%s","lane":"F","action":"%s","target":"%s","rc":%d}\n' \
    "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$1" "$2" "$3" >> "$BUNDLE/migration.log.jsonl"
}

if [ -f "$BUNDLE/.done/$LANE" ] && [ "${1:-}" != "--force" ]; then
  echo "[lane-f] Already complete. Pass --force to re-run."
  exit 0
fi

if [ -f "$BUNDLE/manifest.json" ] && command -v jq > /dev/null; then
  if [ "$(jq -r '.lane_f.skip // false' "$BUNDLE/manifest.json")" = "true" ]; then
    echo "[lane-f] Skipped per manifest.json opt-out."
    echo "skipped=true" > "$BUNDLE/.done/$LANE"
    audit_log "skip" "manifest_opt_out" 0
    exit 0
  fi
fi

mkdir -p "$BUNDLE/.done"

# F1. VS Code
if command -v code > /dev/null && [ -f "$BUNDLE/ides/vscode-extensions.txt" ]; then
  echo "[lane-f] Installing VS Code extensions..."
  while IFS= read -r ext; do
    [ -z "$ext" ] && continue
    code --install-extension "$ext" 2>/dev/null || echo "[lane-f]   FAIL: $ext"
  done < "$BUNDLE/ides/vscode-extensions.txt"
  audit_log "vscode_extensions" "$BUNDLE/ides/vscode-extensions.txt" 0
fi

CODE_USER="$HOME/Library/Application Support/Code/User"
if [ -d "$BUNDLE/ides/vscode" ]; then
  echo "[lane-f] Restoring VS Code settings..."
  mkdir -p "$CODE_USER"
  [ -f "$BUNDLE/ides/vscode/settings.json" ] && cp "$BUNDLE/ides/vscode/settings.json" "$CODE_USER/"
  [ -f "$BUNDLE/ides/vscode/keybindings.json" ] && cp "$BUNDLE/ides/vscode/keybindings.json" "$CODE_USER/"
  [ -d "$BUNDLE/ides/vscode/snippets" ] && rsync -av "$BUNDLE/ides/vscode/snippets/" "$CODE_USER/snippets/"
  audit_log "rsync_vscode_user" "$CODE_USER" 0
fi

# F1b. Cursor
if command -v cursor > /dev/null && [ -f "$BUNDLE/ides/cursor-extensions.txt" ]; then
  echo "[lane-f] Installing Cursor extensions..."
  while IFS= read -r ext; do
    [ -z "$ext" ] && continue
    cursor --install-extension "$ext" 2>/dev/null || echo "[lane-f]   FAIL: $ext (Cursor marketplace may differ from VS Code)"
  done < "$BUNDLE/ides/cursor-extensions.txt"
fi

CURSOR_USER="$HOME/Library/Application Support/Cursor/User"
if [ -d "$BUNDLE/ides/cursor" ]; then
  echo "[lane-f] Restoring Cursor settings..."
  mkdir -p "$CURSOR_USER"
  rsync -av "$BUNDLE/ides/cursor/" "$CURSOR_USER/"
  audit_log "rsync_cursor_user" "$CURSOR_USER" 0
fi

# F2. Zed
if [ -d "$BUNDLE/ides/zed" ]; then
  echo "[lane-f] Restoring Zed config..."
  mkdir -p "$HOME/.config/zed"
  rsync -av "$BUNDLE/ides/zed/" "$HOME/.config/zed/"
  audit_log "rsync_zed" "$HOME/.config/zed" 0
fi

# F3. JetBrains
if [ -d "$BUNDLE/ides/jetbrains" ]; then
  echo "[lane-f] Restoring JetBrains configs..."
  JB_DIR="$HOME/Library/Application Support/JetBrains"
  mkdir -p "$JB_DIR"
  rsync -av "$BUNDLE/ides/jetbrains/" "$JB_DIR/"
  echo "[lane-f]   ADVISORY: JetBrains configs embed absolute paths from old Mac."
  echo "[lane-f]   Open each IDE > File > Project Structure > Project SDK to update."
  audit_log "rsync_jetbrains" "$JB_DIR" 0
fi

# F4. Neovim / Emacs -- covered by Lane B (dotfiles via chezmoi)
# Just verify the dirs exist
if [ -d "$HOME/.config/nvim" ]; then
  echo "[lane-f] Neovim config present at ~/.config/nvim (restored by Lane B)."
fi
if [ -d "$HOME/.emacs.d" ] || [ -d "$HOME/.config/emacs" ]; then
  echo "[lane-f] Emacs config present (restored by Lane B)."
fi

# F5. Terminals
# iTerm2
if [ -f "$BUNDLE/ides/iterm2.plist" ]; then
  echo "[lane-f] Restoring iTerm2 preferences..."
  cp "$BUNDLE/ides/iterm2.plist" "$HOME/Library/Preferences/com.googlecode.iterm2.plist"
  defaults read com.googlecode.iterm2 > /dev/null 2>&1 || true
  killall cfprefsd 2>/dev/null || true
  audit_log "cp_iterm2" "$HOME/Library/Preferences/com.googlecode.iterm2.plist" 0
fi

# Warp
if [ -d "$BUNDLE/ides/warp" ]; then
  WARP_DIR="$HOME/Library/Application Support/dev.warp.Warp-Stable"
  mkdir -p "$WARP_DIR"
  rsync -av "$BUNDLE/ides/warp/" "$WARP_DIR/"
  echo "[lane-f] Warp config restored. If old Mac used iTerm2, run Warp's built-in iTerm2 importer."
  audit_log "rsync_warp" "$WARP_DIR" 0
fi

# Ghostty / Alacritty / Kitty -- covered by Lane B
[ -d "$HOME/.config/ghostty" ] && echo "[lane-f] Ghostty config present (Lane B)."
[ -d "$HOME/.config/alacritty" ] && echo "[lane-f] Alacritty config present (Lane B)."
[ -d "$HOME/.config/kitty" ] && echo "[lane-f] Kitty config present (Lane B)."

echo "$(date -u +%Y-%m-%dT%H:%M:%SZ)" > "$BUNDLE/.done/$LANE"
audit_log "complete" "$LANE" 0
echo "[lane-f] DONE."
exit 0
