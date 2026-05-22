#!/usr/bin/env bash
# restore_lane_i_creds.sh -- Lane I: decrypt + restore credentials.
# - Decrypts credentials/credentials.tar.gz.gpg via shared encrypt_creds.sh
# - Rsyncs SSH/GPG/cloud/git/CLI tokens to canonical locations
# - Auto-fixes SSH perms (chmod 700/600)
# - Securely wipes plaintext after restore
# - Surfaces npm classic-token deprecation reminder

set -euo pipefail

PARENT="$(cd "$(dirname "$0")/../.." && pwd)"
BUNDLE="${BUNDLE:-$HOME/migration-bundle}"
LANE="lane-i-creds"
UNSEAL_DIR="$BUNDLE/credentials/_unsealed"

audit_log() {
  printf '{"ts":"%s","lane":"I","action":"%s","target":"%s","rc":%d}\n' \
    "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$1" "$2" "$3" >> "$BUNDLE/migration.log.jsonl"
}

if [ -f "$BUNDLE/.done/$LANE" ] && [ "${1:-}" != "--force" ]; then
  echo "[lane-i] Already complete. Pass --force to re-run."
  exit 0
fi

if [ -f "$BUNDLE/manifest.json" ] && command -v jq > /dev/null; then
  if [ "$(jq -r '.lane_i.skip // false' "$BUNDLE/manifest.json")" = "true" ]; then
    echo "[lane-i] Skipped per manifest.json opt-out."
    echo "skipped=true" > "$BUNDLE/.done/$LANE"
    audit_log "skip" "manifest_opt_out" 0
    exit 0
  fi
fi

mkdir -p "$BUNDLE/.done"

# Step 0: GPG sanity check
if ! command -v gpg > /dev/null; then
  echo "[lane-i] FATAL: gpg not installed. Run: brew install gnupg"
  exit 1
fi

if ! gpg --list-secret-keys 2>/dev/null | grep -q sec; then
  echo "[lane-i] FATAL: no GPG secret key available on this Mac."
  echo "[lane-i]   Import your personal GPG secret key first:"
  echo "[lane-i]     gpg --import /path/to/your-private-key.asc"
  echo "[lane-i]   OR plug in your YubiKey if you use hardware GPG."
  exit 2
fi

# Step 1: decrypt
ENCRYPTED="$BUNDLE/credentials/credentials.tar.gz.gpg"
if [ ! -f "$ENCRYPTED" ]; then
  echo "[lane-i] No encrypted credentials in bundle (credentials/credentials.tar.gz.gpg missing)."
  echo "$(date -u +%Y-%m-%dT%H:%M:%SZ)" > "$BUNDLE/.done/$LANE"
  echo "no_credentials=true" >> "$BUNDLE/.done/$LANE"
  audit_log "no_credentials" "$ENCRYPTED" 0
  exit 0
fi

echo "[lane-i] Decrypting credentials..."
if [ -x "$PARENT/scripts/encrypt_creds.sh" ]; then
  "$PARENT/scripts/encrypt_creds.sh" unseal "$ENCRYPTED" "$UNSEAL_DIR"
else
  # Fallback if shared script not yet present
  mkdir -p "$UNSEAL_DIR"
  gpg --decrypt "$ENCRYPTED" | tar -xzf - -C "$UNSEAL_DIR"
fi
audit_log "decrypt" "$ENCRYPTED" $?

if [ ! -d "$UNSEAL_DIR" ]; then
  echo "[lane-i] FATAL: decryption did not produce unsealed dir at $UNSEAL_DIR"
  exit 3
fi

# Step 2: I1 -- git + gh
[ -f "$UNSEAL_DIR/gitconfig" ] && cp "$UNSEAL_DIR/gitconfig" "$HOME/.gitconfig" && \
  audit_log "cp" "$HOME/.gitconfig" 0
[ -f "$UNSEAL_DIR/gitconfig.local" ] && cp "$UNSEAL_DIR/gitconfig.local" "$HOME/.gitconfig.local"
if [ -f "$UNSEAL_DIR/gh-hosts.yml" ]; then
  mkdir -p "$HOME/.config/gh"
  cp "$UNSEAL_DIR/gh-hosts.yml" "$HOME/.config/gh/hosts.yml"
fi
command -v gh > /dev/null && gh auth setup-git 2>/dev/null || true

# Step 3: I2 -- cloud CLIs
# AWS
if [ -d "$UNSEAL_DIR/aws" ]; then
  mkdir -p "$HOME/.aws"
  [ -f "$UNSEAL_DIR/aws/credentials" ] && cp "$UNSEAL_DIR/aws/credentials" "$HOME/.aws/credentials" && chmod 600 "$HOME/.aws/credentials"
  [ -f "$UNSEAL_DIR/aws/config" ] && cp "$UNSEAL_DIR/aws/config" "$HOME/.aws/config"
  audit_log "cp_aws" "$HOME/.aws" 0
fi

# gcloud -- short-lived tokens, advise re-auth
if [ -d "$UNSEAL_DIR/gcloud" ]; then
  mkdir -p "$HOME/.config/gcloud"
  rsync -av "$UNSEAL_DIR/gcloud/" "$HOME/.config/gcloud/" 2>/dev/null || true
  echo "[lane-i] gcloud restored. Tokens expire (~1h). Run if needed:"
  echo "[lane-i]   gcloud auth login"
  echo "[lane-i]   gcloud auth application-default login"
  audit_log "rsync_gcloud" "$HOME/.config/gcloud" 0
fi

# Azure -- short-lived, advise re-auth
if [ -d "$UNSEAL_DIR/azure" ]; then
  mkdir -p "$HOME/.azure"
  rsync -av "$UNSEAL_DIR/azure/" "$HOME/.azure/" 2>/dev/null || true
  echo "[lane-i] Azure restored. Run 'az login' if 'az account show' fails."
  audit_log "rsync_azure" "$HOME/.azure" 0
fi

# Cloudflare -- long-lived
if [ -d "$UNSEAL_DIR/cloudflared" ]; then
  mkdir -p "$HOME/.cloudflared"
  rsync -av "$UNSEAL_DIR/cloudflared/" "$HOME/.cloudflared/" 2>/dev/null || true
  audit_log "rsync_cloudflared" "$HOME/.cloudflared" 0
fi

# DigitalOcean
if [ -d "$UNSEAL_DIR/doctl" ]; then
  mkdir -p "$HOME/.config/doctl"
  rsync -av "$UNSEAL_DIR/doctl/" "$HOME/.config/doctl/" 2>/dev/null || true
  audit_log "rsync_doctl" "$HOME/.config/doctl" 0
fi

# Step 4: I3 -- CLI tokens
NPM_TOKEN_WARN=0
if [ -f "$UNSEAL_DIR/npmrc" ]; then
  cp "$UNSEAL_DIR/npmrc" "$HOME/.npmrc"
  # Detect classic _authToken pattern (24-char-ish hex w/o prefix)
  if grep -qE "_authToken=[a-zA-Z0-9-]{20,}" "$HOME/.npmrc" 2>/dev/null; then
    if ! grep -qE "_authToken=(npm_|npmt_)" "$HOME/.npmrc" 2>/dev/null; then
      NPM_TOKEN_WARN=1
    fi
  fi
fi
[ -f "$UNSEAL_DIR/cargo-credentials.toml" ] && mkdir -p "$HOME/.cargo" && cp "$UNSEAL_DIR/cargo-credentials.toml" "$HOME/.cargo/credentials.toml"
[ -f "$UNSEAL_DIR/gem-credentials" ] && mkdir -p "$HOME/.gem" && cp "$UNSEAL_DIR/gem-credentials" "$HOME/.gem/credentials" && chmod 600 "$HOME/.gem/credentials"
[ -f "$UNSEAL_DIR/composer-auth.json" ] && mkdir -p "$HOME/.config/composer" && cp "$UNSEAL_DIR/composer-auth.json" "$HOME/.config/composer/auth.json"
[ -f "$UNSEAL_DIR/pypirc" ] && cp "$UNSEAL_DIR/pypirc" "$HOME/.pypirc"
[ -f "$UNSEAL_DIR/huggingface-token" ] && mkdir -p "$HOME/.huggingface" && cp "$UNSEAL_DIR/huggingface-token" "$HOME/.huggingface/token"
[ -f "$UNSEAL_DIR/netrc" ] && cp "$UNSEAL_DIR/netrc" "$HOME/.netrc" && chmod 600 "$HOME/.netrc"

if [ "$NPM_TOKEN_WARN" = "1" ]; then
  echo
  echo "[lane-i] WARNING: ~/.npmrc has a classic npm token."
  echo "[lane-i]   npm classic tokens (legacy _authToken) were REVOKED Nov-Dec 2025."
  echo "[lane-i]   Generate a new granular token: https://www.npmjs.com/settings/<user>/tokens"
  echo
fi

# Step 5: I4 -- SSH keys with permission auto-fix (CRITICAL)
if [ -d "$UNSEAL_DIR/ssh" ]; then
  echo "[lane-i] Restoring SSH keys + auto-fixing permissions..."
  mkdir -p "$HOME/.ssh"
  rsync -av "$UNSEAL_DIR/ssh/" "$HOME/.ssh/" 2>/dev/null || true
  chmod 700 "$HOME/.ssh"
  # All private keys + config + known_hosts: 600
  find "$HOME/.ssh" -type f -exec chmod 600 {} \; 2>/dev/null || true
  # Public keys can be 644 (read-anyone) but 600 also works for SSH
  find "$HOME/.ssh" -name "*.pub" -exec chmod 644 {} \; 2>/dev/null || true
  audit_log "ssh_restore_chmod" "$HOME/.ssh" 0
fi

# Step 6: I5 -- GPG keys + ownertrust
if [ -f "$UNSEAL_DIR/gpg-secret.asc" ]; then
  echo "[lane-i] Importing GPG secret keys..."
  gpg --import "$UNSEAL_DIR/gpg-secret.asc" 2>/dev/null || echo "[lane-i]   gpg import had warnings"
  audit_log "gpg_import_secret" "$UNSEAL_DIR/gpg-secret.asc" $?
fi
if [ -f "$UNSEAL_DIR/gpg-trust.txt" ]; then
  gpg --import-ownertrust "$UNSEAL_DIR/gpg-trust.txt" 2>/dev/null || echo "[lane-i]   ownertrust import had warnings"
  audit_log "gpg_import_trust" "$UNSEAL_DIR/gpg-trust.txt" $?
fi

# Step 7: I6 -- WireGuard
if [ -d "$UNSEAL_DIR/wireguard-etc" ]; then
  echo "[lane-i] Restoring CLI WireGuard configs..."
  sudo mkdir -p /etc/wireguard
  sudo rsync -av "$UNSEAL_DIR/wireguard-etc/" "/etc/wireguard/" 2>/dev/null || true
  sudo chmod 600 /etc/wireguard/*.conf 2>/dev/null || true
  audit_log "rsync_wireguard" "/etc/wireguard" 0
fi
if [ -f "$UNSEAL_DIR/wireguard-tunnels.zip" ]; then
  echo "[lane-i] App Store WireGuard tunnels zip at: $UNSEAL_DIR/wireguard-tunnels.zip"
  echo "[lane-i]   Open WireGuard.app > File > Import Tunnels From File to restore."
fi

# Step 8: SECURELY WIPE plaintext
echo "[lane-i] Securely wiping decrypted plaintext at $UNSEAL_DIR ..."
if find "$UNSEAL_DIR" -type f -exec rm -P {} \; 2>/dev/null; then
  rmdir "$UNSEAL_DIR" 2>/dev/null || rm -rf "$UNSEAL_DIR"
else
  # Fallback if -P unsupported
  rm -rf "$UNSEAL_DIR"
fi
audit_log "wipe_unsealed" "$UNSEAL_DIR" 0

echo "$(date -u +%Y-%m-%dT%H:%M:%SZ)" > "$BUNDLE/.done/$LANE"
audit_log "complete" "$LANE" 0
echo "[lane-i] DONE."
exit 0
