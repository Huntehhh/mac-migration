#!/usr/bin/env bash
# capture_lane_i_creds.sh
# Lane I -- Credentials + Auth
#
# Sub-modules -- all collated under $BUNDLE/credentials/, then GPG-sealed:
#   I1  SSH  - ~/.ssh/
#   I2  GPG  - ~/.gnupg/ + exported secret keys + ownertrust
#   I3  Cloud CLIs - AWS, gcloud, Azure, Cloudflare, DigitalOcean, Linode
#   I4  git + gh + language-package tokens
#   I5  WireGuard - /etc/wireguard/ (sudo)
#   I6  SEAL - invoke encrypt_creds.sh seal
#
# After SEAL, only credentials.tar.gz.gpg remains in the bundle; cleartext credentials/ is shredded.
#
# Opt-out keys:
#   opt_outs.lane_i
#   opt_outs.lane_i.{ssh,gpg,cloud_clis,git_and_tokens,wireguard}

set -euo pipefail

BUNDLE="${BUNDLE:-$HOME/migration-bundle}"
DRY_RUN="${DRY_RUN:-0}"
FORCE="${FORCE:-0}"

for arg in "$@"; do
  case "$arg" in
    --force)   FORCE=1 ;;
    --dry-run) DRY_RUN=1 ;;
    *) echo "capture_lane_i_creds.sh: unknown arg: $arg" >&2; exit 2 ;;
  esac
done

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SUB_SKILL_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
SKILL_DIR="$(cd "$SUB_SKILL_DIR/.." && pwd)"
AUDIT="$SCRIPT_DIR/audit_log.sh"
DONE_HELPER="$SKILL_DIR/scripts/lane_done_marker.sh"
ENCRYPT_HELPER="$SKILL_DIR/scripts/encrypt_creds.sh"
LANE_ID="lane-i-creds"
MANIFEST="$BUNDLE/manifest.json"

if [ ! -f "$MANIFEST" ]; then
  echo "capture_lane_i_creds.sh: $MANIFEST not found -- run inventory first." >&2
  exit 3
fi

mkdir -p "$BUNDLE/credentials" "$BUNDLE/.done" "$BUNDLE/dry-run-report"

opt_out_lane() { jq -e ".opt_outs.lane_i == true" "$MANIFEST" >/dev/null 2>&1; }
opt_out_sub()  { jq -e ".opt_outs.lane_i.$1 == true" "$MANIFEST" >/dev/null 2>&1; }

if opt_out_lane; then
  "$AUDIT" "$LANE_ID" lane skip "manifest.json opts out of entire Lane I"
  [ "$DRY_RUN" != "1" ] && bash "$DONE_HELPER" set "$LANE_ID"
  exit 0
fi

if [ "$FORCE" != "1" ] && bash "$DONE_HELPER" check "$LANE_ID" >/dev/null 2>&1; then
  "$AUDIT" "$LANE_ID" lane skip "Already done -- use --force to re-capture"
  exit 0
fi

"$AUDIT" "$LANE_ID" lane start "Lane I -- Credentials (dry_run=$DRY_RUN, force=$FORCE)"

# --- I1. SSH ------------------------------------------------------------

if ! opt_out_sub ssh; then
  if [ -d ~/.ssh ]; then
    if [ "$DRY_RUN" = "1" ]; then
      "$AUDIT" "$LANE_ID" ssh info "Would copy ~/.ssh/"
    else
      mkdir -p "$BUNDLE/credentials/ssh"
      rsync -a ~/.ssh/ "$BUNDLE/credentials/ssh/" 2>/dev/null \
        && "$AUDIT" "$LANE_ID" ssh ok "Captured ~/.ssh/" \
        || "$AUDIT" "$LANE_ID" ssh warn "~/.ssh rsync returned non-zero"
      "$AUDIT" "$LANE_ID" ssh info "Restore: chmod 700 ~/.ssh && chmod 600 ~/.ssh/* (else SSH refuses keys)"
    fi
  else
    "$AUDIT" "$LANE_ID" ssh skip "No ~/.ssh directory"
  fi
else
  "$AUDIT" "$LANE_ID" ssh skip "Opted out via manifest"
fi

# --- I2. GPG ------------------------------------------------------------

if ! opt_out_sub gpg; then
  if [ -d ~/.gnupg ]; then
    if [ "$DRY_RUN" = "1" ]; then
      "$AUDIT" "$LANE_ID" gpg info "Would copy ~/.gnupg/ + export secret keys + ownertrust"
    else
      mkdir -p "$BUNDLE/credentials/gnupg"
      rsync -a ~/.gnupg/ "$BUNDLE/credentials/gnupg/" 2>/dev/null \
        && "$AUDIT" "$LANE_ID" gpg ok "Captured ~/.gnupg/" \
        || "$AUDIT" "$LANE_ID" gpg warn "~/.gnupg rsync returned non-zero"
      if command -v gpg >/dev/null 2>&1; then
        gpg --export-secret-keys -a > "$BUNDLE/credentials/gpg-secret.asc" 2>/dev/null \
          && "$AUDIT" "$LANE_ID" gpg ok "Exported secret keys (gpg-secret.asc)" \
          || "$AUDIT" "$LANE_ID" gpg warn "GPG secret key export failed"
        gpg --export-ownertrust > "$BUNDLE/credentials/gpg-trust.txt" 2>/dev/null \
          && "$AUDIT" "$LANE_ID" gpg ok "Exported ownertrust (gpg-trust.txt)" \
          || "$AUDIT" "$LANE_ID" gpg warn "GPG ownertrust export failed"
      fi
      "$AUDIT" "$LANE_ID" gpg warn "encrypt_creds.sh seals with GPG. If sealing with the same key being captured, sideband-transfer the key to new Mac BEFORE unseal."
    fi
  else
    "$AUDIT" "$LANE_ID" gpg skip "No ~/.gnupg directory"
  fi
else
  "$AUDIT" "$LANE_ID" gpg skip "Opted out via manifest"
fi

# --- I3. Cloud CLIs ----------------------------------------------------

if ! opt_out_sub cloud_clis; then
  if [ "$DRY_RUN" = "1" ]; then
    "$AUDIT" "$LANE_ID" cloud_clis info "Would copy AWS/gcloud/Azure/CF/DO/Linode credentials"
  else
    for entry in \
      ".aws:aws" \
      ".config/gcloud:gcloud" \
      ".azure:azure" \
      ".cloudflared:cloudflared" \
      ".config/doctl:doctl" \
      ".config/linode-cli:linode-cli"; do
      src_rel="${entry%%:*}"
      label="${entry##*:}"
      src="$HOME/$src_rel"
      if [ -d "$src" ]; then
        mkdir -p "$BUNDLE/credentials/$label"
        rsync -a "$src/" "$BUNDLE/credentials/$label/" 2>/dev/null \
          && "$AUDIT" "$LANE_ID" cloud_clis ok "Captured $src_rel" \
          || "$AUDIT" "$LANE_ID" cloud_clis warn "$src rsync returned non-zero"
      fi
    done
    "$AUDIT" "$LANE_ID" cloud_clis info "gcloud OAuth tokens expire ~1h; usually need 'gcloud auth login' on new Mac. AWS SSO same."
  fi
else
  "$AUDIT" "$LANE_ID" cloud_clis skip "Opted out via manifest"
fi

# --- I4. git + gh + language-package tokens -----------------------------

if ! opt_out_sub git_and_tokens; then
  if [ "$DRY_RUN" = "1" ]; then
    "$AUDIT" "$LANE_ID" git_and_tokens info "Would copy git + gh + npm + cargo + gem + composer + pypi + huggingface + netrc tokens"
  else
    mkdir -p "$BUNDLE/credentials/git" "$BUNDLE/credentials/gh" "$BUNDLE/credentials/lang-tokens"
    for f in .gitconfig .gitconfig.local .gitignore_global; do
      [ -f "$HOME/$f" ] && cp -p "$HOME/$f" "$BUNDLE/credentials/git/$f" 2>/dev/null \
        && "$AUDIT" "$LANE_ID" git_and_tokens ok "Captured ~/$f"
    done
    if [ -f ~/.config/gh/hosts.yml ]; then
      cp -p ~/.config/gh/hosts.yml "$BUNDLE/credentials/gh/hosts.yml" \
        && "$AUDIT" "$LANE_ID" git_and_tokens ok "Captured ~/.config/gh/hosts.yml"
      "$AUDIT" "$LANE_ID" git_and_tokens info "gh auth setup-git embeds absolute /opt/homebrew/bin/gh path -- verify on new Mac"
    fi
    for f_pair in \
      ".npmrc:npmrc" \
      ".cargo/credentials.toml:cargo-credentials.toml" \
      ".gem/credentials:gem-credentials" \
      ".config/composer/auth.json:composer-auth.json" \
      ".pypirc:pypirc" \
      ".huggingface/token:huggingface-token" \
      ".netrc:netrc"; do
      src_rel="${f_pair%%:*}"
      out="${f_pair##*:}"
      src="$HOME/$src_rel"
      if [ -f "$src" ]; then
        cp -p "$src" "$BUNDLE/credentials/lang-tokens/$out" 2>/dev/null \
          && "$AUDIT" "$LANE_ID" git_and_tokens ok "Captured ~/$src_rel"
      fi
    done
    if [ -f ~/.npmrc ] && grep -q "_authToken=" ~/.npmrc 2>/dev/null; then
      "$AUDIT" "$LANE_ID" git_and_tokens warn "~/.npmrc contains _authToken= -- npm classic tokens REVOKED Nov-Dec 2025. Regenerate granular tokens before relying on bundle."
    fi
    "$AUDIT" "$LANE_ID" git_and_tokens info "osxkeychain credential helper data lives in Keychain -- does NOT migrate. Re-auth on new Mac."
  fi
else
  "$AUDIT" "$LANE_ID" git_and_tokens skip "Opted out via manifest"
fi

# --- I5. WireGuard ------------------------------------------------------

if ! opt_out_sub wireguard; then
  if [ -d /etc/wireguard ]; then
    if [ "$DRY_RUN" = "1" ]; then
      "$AUDIT" "$LANE_ID" wireguard info "Would sudo-copy /etc/wireguard/"
    else
      mkdir -p "$BUNDLE/credentials/wireguard"
      if sudo cp -r /etc/wireguard/. "$BUNDLE/credentials/wireguard/" 2>/dev/null; then
        "$AUDIT" "$LANE_ID" wireguard ok "Captured /etc/wireguard/"
      else
        "$AUDIT" "$LANE_ID" wireguard warn "WireGuard copy returned non-zero"
      fi
    fi
  else
    "$AUDIT" "$LANE_ID" wireguard skip "No /etc/wireguard directory (App Store WG handled via Lane J manual checklist)"
  fi
else
  "$AUDIT" "$LANE_ID" wireguard skip "Opted out via manifest"
fi

# --- I6. SEAL via encrypt_creds.sh --------------------------------------

if [ "$DRY_RUN" = "1" ]; then
  "$AUDIT" "$LANE_ID" seal info "Would invoke encrypt_creds.sh seal (cleartext credentials/ would be shredded)"
else
  if [ ! -x "$ENCRYPT_HELPER" ] && [ ! -f "$ENCRYPT_HELPER" ]; then
    "$AUDIT" "$LANE_ID" seal fail "encrypt_creds.sh not found at $ENCRYPT_HELPER"
    exit 40
  fi
  "$AUDIT" "$LANE_ID" seal start "Invoking encrypt_creds.sh seal"
  if bash "$ENCRYPT_HELPER" seal; then
    "$AUDIT" "$LANE_ID" seal ok "Credentials sealed to credentials.tar.gz.gpg, cleartext shredded"
  else
    "$AUDIT" "$LANE_ID" seal fail "encrypt_creds.sh seal failed -- cleartext credentials/ still present, do NOT ship bundle"
    exit 41
  fi
fi

# --- done marker --------------------------------------------------------

if [ "$DRY_RUN" = "1" ]; then
  "$AUDIT" "$LANE_ID" lane info "Dry-run complete; no .done marker written"
else
  bash "$DONE_HELPER" set "$LANE_ID"
  "$AUDIT" "$LANE_ID" lane ok "Lane I capture complete (credentials GPG-sealed)"
fi
