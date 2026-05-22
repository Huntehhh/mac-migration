#!/usr/bin/env bash
# restore_lane_c_toolchains.sh -- Lane C: mise + pipx + npm + cargo + gem + go + composer globals.
# Idempotent. Depends on Lane A (brew) and Lane B (PATH).

set -euo pipefail

PARENT="$(cd "$(dirname "$0")/../.." && pwd)"
BUNDLE="${BUNDLE:-$HOME/migration-bundle}"
LANE="lane-c-toolchains"

audit_log() {
  printf '{"ts":"%s","lane":"C","action":"%s","target":"%s","rc":%d}\n' \
    "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$1" "$2" "$3" >> "$BUNDLE/migration.log.jsonl"
}

if [ -f "$BUNDLE/.done/$LANE" ] && [ "${1:-}" != "--force" ]; then
  echo "[lane-c] Already complete. Pass --force to re-run."
  exit 0
fi

if [ -f "$BUNDLE/manifest.json" ] && command -v jq > /dev/null; then
  if [ "$(jq -r '.lane_c.skip // false' "$BUNDLE/manifest.json")" = "true" ]; then
    echo "[lane-c] Skipped per manifest.json opt-out."
    echo "skipped=true" > "$BUNDLE/.done/$LANE"
    audit_log "skip" "manifest_opt_out" 0
    exit 0
  fi
fi

mkdir -p "$BUNDLE/.done"

# C1. mise
if [ -f "$BUNDLE/manifests/.tool-versions" ]; then
  echo "[lane-c] Installing mise + runtimes..."
  brew install mise 2>/dev/null || true
  cp "$BUNDLE/manifests/.tool-versions" "$HOME/.tool-versions"
  if [ -f "$BUNDLE/manifests/mise-config.toml" ]; then
    mkdir -p "$HOME/.config/mise"
    cp "$BUNDLE/manifests/mise-config.toml" "$HOME/.config/mise/config.toml"
  fi
  # mise needs to be activated for `mise install` to find shims, but the install command works standalone
  eval "$(mise activate bash 2>/dev/null || mise activate zsh 2>/dev/null || echo '')"
  mise install || echo "[lane-c] mise install had failures; continuing."
  audit_log "mise_install" "$HOME/.tool-versions" $?
fi

# C2. pipx
if [ -f "$BUNDLE/manifests/pipx.json" ]; then
  echo "[lane-c] Restoring pipx envs..."
  brew install pipx 2>/dev/null || true
  pipx ensurepath 2>/dev/null || true
  jq -r '.venvs | keys[]' "$BUNDLE/manifests/pipx.json" 2>/dev/null | while read pkg; do
    [ -z "$pkg" ] && continue
    pipx install "$pkg" 2>/dev/null || echo "[lane-c]   FAIL: pipx install $pkg"
    audit_log "pipx_install" "$pkg" $?
  done
fi

# C3. npm globals
if [ -f "$BUNDLE/manifests/npm-globals.json" ] && command -v npm > /dev/null; then
  echo "[lane-c] Restoring npm globals..."
  jq -r '.dependencies | keys[]' "$BUNDLE/manifests/npm-globals.json" 2>/dev/null \
    | grep -v '^npm$' \
    | while read pkg; do
      [ -z "$pkg" ] && continue
      npm install -g "$pkg" 2>/dev/null || echo "[lane-c]   FAIL: npm install -g $pkg"
      audit_log "npm_global" "$pkg" $?
    done
fi

# C4. cargo + cargo-binstall
if [ -f "$BUNDLE/manifests/cargo-installs.txt" ] && command -v cargo > /dev/null; then
  echo "[lane-c] Restoring cargo binaries via cargo-binstall..."
  cargo install cargo-binstall 2>/dev/null || true
  awk '/^[a-z0-9_-]+ v/ {print $1}' "$BUNDLE/manifests/cargo-installs.txt" \
    | xargs -I{} cargo binstall -y {} 2>/dev/null || \
    echo "[lane-c]   Some cargo installs failed; check manually."
  audit_log "cargo_binstall" "$BUNDLE/manifests/cargo-installs.txt" 0
fi

# C5. gem globals
if [ -f "$BUNDLE/manifests/gem-list.txt" ] && command -v gem > /dev/null; then
  echo "[lane-c] Restoring gem globals..."
  awk '/^[a-z]/ && $1 !~ /^---/ {print $1}' "$BUNDLE/manifests/gem-list.txt" \
    | while read pkg; do
      [ -z "$pkg" ] && continue
      gem install "$pkg" 2>/dev/null || echo "[lane-c]   FAIL: gem install $pkg"
      audit_log "gem_install" "$pkg" $?
    done
fi

# C6. go bin -- no install-from-list, emit checklist
if [ -f "$BUNDLE/manifests/go-bin.txt" ]; then
  GO_FILE="$BUNDLE/MANUAL-STEPS-go-bin.md"
  {
    echo "# Go binaries to reinstall"
    echo
    echo "Go has no install-from-list. The bundle captured binary NAMES only, not source paths."
    echo "For each, run \`go install <import-path>@latest\` after looking up the source repo."
    echo
    awk '{print "- [ ] " $1}' "$BUNDLE/manifests/go-bin.txt"
  } > "$GO_FILE"
  echo "[lane-c] Go bin checklist written: $GO_FILE"
fi

# C7. composer globals
if [ -f "$BUNDLE/manifests/composer-globals.json" ] && command -v composer > /dev/null; then
  echo "[lane-c] Restoring composer globals..."
  jq -r '.installed[].name' "$BUNDLE/manifests/composer-globals.json" 2>/dev/null \
    | while read pkg; do
      [ -z "$pkg" ] && continue
      composer global require "$pkg" 2>/dev/null || echo "[lane-c]   FAIL: composer global require $pkg"
      audit_log "composer_global" "$pkg" $?
    done
fi

echo "$(date -u +%Y-%m-%dT%H:%M:%SZ)" > "$BUNDLE/.done/$LANE"
audit_log "complete" "$LANE" 0
echo "[lane-c] DONE."
exit 0
