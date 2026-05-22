#!/usr/bin/env bash
# restore_lane_b_shell.sh -- Lane B: dotfiles + /etc/paths + ~/bin + /etc/hosts + sudoers.d.
# Idempotent, cron-rerunnable. Validates sudoers BEFORE activating to prevent lock-out.

set -euo pipefail

PARENT="$(cd "$(dirname "$0")/../.." && pwd)"
BUNDLE="${BUNDLE:-$HOME/migration-bundle}"
LANE="lane-b-shell"

audit_log() {
  printf '{"ts":"%s","lane":"B","action":"%s","target":"%s","rc":%d}\n' \
    "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$1" "$2" "$3" >> "$BUNDLE/migration.log.jsonl"
}

if [ -f "$BUNDLE/.done/$LANE" ] && [ "${1:-}" != "--force" ]; then
  echo "[lane-b] Already complete. Pass --force to re-run."
  exit 0
fi

if [ -f "$BUNDLE/manifest.json" ] && command -v jq > /dev/null; then
  if [ "$(jq -r '.lane_b.skip // false' "$BUNDLE/manifest.json")" = "true" ]; then
    echo "[lane-b] Skipped per manifest.json opt-out."
    echo "skipped=true" > "$BUNDLE/.done/$LANE"
    audit_log "skip" "manifest_opt_out" 0
    exit 0
  fi
fi

mkdir -p "$BUNDLE/.done"

# B1 + B2. Dotfiles
CHEZMOI_REPO=""
if [ -f "$BUNDLE/manifest.json" ] && command -v jq > /dev/null; then
  CHEZMOI_REPO=$(jq -r '.lane_b.chezmoi_repo // empty' "$BUNDLE/manifest.json")
fi

if [ -n "$CHEZMOI_REPO" ]; then
  echo "[lane-b] chezmoi repo configured: $CHEZMOI_REPO"
  brew install chezmoi 2>/dev/null || true
  chezmoi init --apply "$CHEZMOI_REPO"
  audit_log "chezmoi_apply" "$CHEZMOI_REPO" $?
elif [ -d "$BUNDLE/dotfiles-refs" ]; then
  echo "[lane-b] No chezmoi repo set; rsyncing dotfiles-refs/ to \$HOME."
  echo "[lane-b] ADVISORY: consider initializing chezmoi to track these going forward."
  rsync -av "$BUNDLE/dotfiles-refs/" "$HOME/"
  audit_log "rsync_dotfiles" "$BUNDLE/dotfiles-refs" $?
fi

# B3. /etc/paths + /etc/paths.d/
if [ -f "$BUNDLE/manifests/etc-paths.txt" ]; then
  echo "[lane-b] Restoring /etc/paths (sudo required)..."
  sudo cp "$BUNDLE/manifests/etc-paths.txt" /etc/paths
  audit_log "cp" "/etc/paths" $?
fi
if [ -d "$BUNDLE/manifests/etc-paths.d" ]; then
  echo "[lane-b] Restoring /etc/paths.d/ (sudo required)..."
  sudo mkdir -p /etc/paths.d
  sudo cp -R "$BUNDLE/manifests/etc-paths.d/." /etc/paths.d/
  audit_log "cp_R" "/etc/paths.d" $?
fi

# B4. ~/bin + ~/.local/bin
if [ -d "$BUNDLE/home-bin" ]; then
  mkdir -p "$HOME/bin"
  rsync -av "$BUNDLE/home-bin/" "$HOME/bin/"
  chmod -R +x "$HOME/bin" 2>/dev/null || true
  audit_log "rsync" "$HOME/bin" 0
fi
if [ -d "$BUNDLE/home-local-bin" ]; then
  mkdir -p "$HOME/.local/bin"
  rsync -av "$BUNDLE/home-local-bin/" "$HOME/.local/bin/"
  chmod -R +x "$HOME/.local/bin" 2>/dev/null || true
  audit_log "rsync" "$HOME/.local/bin" 0
fi

# B5. /etc/hosts
if [ -f "$BUNDLE/manifests/etc-hosts" ]; then
  echo "[lane-b] Restoring /etc/hosts (sudo required)..."
  sudo cp "$BUNDLE/manifests/etc-hosts" /etc/hosts
  audit_log "cp" "/etc/hosts" $?
fi

# B5. sudoers.d -- VALIDATE BEFORE ACTIVATING
if [ -d "$BUNDLE/manifests/sudoers.d" ]; then
  echo "[lane-b] Validating + restoring /etc/sudoers.d/ entries (sudo required)..."
  for f in "$BUNDLE/manifests/sudoers.d/"*; do
    [ -f "$f" ] || continue
    fname=$(basename "$f")
    # Critical: visudo -c -f checks syntax BEFORE we copy
    if sudo visudo -c -f "$f" > /dev/null 2>&1; then
      sudo cp "$f" "/etc/sudoers.d/$fname"
      sudo chmod 0440 "/etc/sudoers.d/$fname"
      sudo chown root:wheel "/etc/sudoers.d/$fname" 2>/dev/null || true
      echo "[lane-b]   OK: $fname"
      audit_log "cp_sudoers" "$fname" 0
    else
      echo "[lane-b]   SKIP: $fname failed visudo syntax check"
      audit_log "skip_sudoers" "$fname" 1
    fi
  done
fi

echo "$(date -u +%Y-%m-%dT%H:%M:%SZ)" > "$BUNDLE/.done/$LANE"
audit_log "complete" "$LANE" 0
echo "[lane-b] DONE."
exit 0
