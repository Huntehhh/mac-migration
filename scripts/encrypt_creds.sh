#!/usr/bin/env bash
# encrypt_creds.sh -- GPG seal / unseal of Lane I credentials.
#
# Usage:
#   encrypt_creds.sh seal   [--recipient KEYID] [--passphrase-file PATH] [--verbose]
#                             Tars $BUNDLE/credentials/ (excluding the .gpg target itself), GPG-encrypts to
#                             recipient (defaults to first secret key), writes
#                             $BUNDLE/credentials/credentials.tar.gz.gpg, then SHREDS the plaintext files
#                             that were sealed.
#
#   encrypt_creds.sh unseal [--passphrase-file PATH] [--out DIR] [--verbose]
#                             Decrypts $BUNDLE/credentials/credentials.tar.gz.gpg into a temp dir (or --out
#                             DIR), prints the path on stdout so restore can rsync from it.
#                             Use 'encrypt_creds.sh post-restore-cleanup --out DIR' to shred after handoff.
#
#   encrypt_creds.sh post-restore-cleanup --out DIR
#                             Securely deletes the unseal temp dir.
#
# Environment:
#   BUNDLE         default: $HOME/migration-bundle
#   GPG_TTY        recommended: $(tty) for interactive GPG passphrase prompts
#
# Behavior notes:
#   - On macOS, srm was removed in 10.12. Fallback: rm -P (3-pass overwrite, native BSD), with a warning that
#     on APFS overwriting may not destroy old blocks (SSD garbage collection). Encrypted bundle is the real
#     safety net; shredding is belt-and-suspenders.
#   - If --recipient is omitted, picks the first secret key from `gpg --list-secret-keys --keyid-format LONG`.
#     If multiple secret keys exist and --recipient is omitted, ERRORS -- user must disambiguate.
#   - Verbose mode prints file count + total bytes; never prints filenames or file contents.
#
# Exit codes:
#   0  success
#   1  GPG failure / decryption failure / tar failure
#   2  preconditions failed (no credentials dir, no GPG keys, missing dependencies)
#   3  invalid invocation

set -euo pipefail

# --- Defaults --------------------------------------------------------------
BUNDLE="${BUNDLE:-$HOME/migration-bundle}"
CREDS_DIR="$BUNDLE/credentials"
SEALED="$CREDS_DIR/credentials.tar.gz.gpg"

CMD=""
RECIPIENT=""
PASS_FILE=""
OUT_DIR=""
VERBOSE=0

# --- Arg parse -------------------------------------------------------------
if [ $# -lt 1 ]; then
  sed -n '2,30p' "$0"
  exit 3
fi
CMD="$1"; shift

while [ $# -gt 0 ]; do
  case "$1" in
    --recipient)        RECIPIENT="${2:?--recipient needs KEYID}"; shift 2 ;;
    --passphrase-file)  PASS_FILE="${2:?--passphrase-file needs path}"; shift 2 ;;
    --out)              OUT_DIR="${2:?--out needs dir}"; shift 2 ;;
    --verbose|-v)       VERBOSE=1; shift ;;
    -h|--help)          sed -n '2,30p' "$0"; exit 0 ;;
    *) echo "encrypt_creds.sh: unknown flag: $1" >&2; exit 3 ;;
  esac
done

# --- Helpers --------------------------------------------------------------
log() { [ "$VERBOSE" -eq 1 ] && echo "encrypt_creds.sh: $*" >&2 || true; }
err() { echo "encrypt_creds.sh: $*" >&2; }

# Secure delete a path. Prefers srm if present, else rm -P, else rm with warning.
shred_path() {
  local p="$1"
  [ -e "$p" ] || return 0
  if command -v srm >/dev/null 2>&1; then
    if [ -d "$p" ]; then srm -rf "$p"; else srm -f "$p"; fi
  elif rm -P /dev/null >/dev/null 2>&1; then
    # rm -P does 3-pass overwrite. Works on files; for dirs we recurse manually.
    if [ -d "$p" ]; then
      find "$p" -type f -exec rm -P -f {} + 2>/dev/null || true
      rm -rf "$p"
    else
      rm -P -f "$p"
    fi
  else
    err "WARN: neither srm nor rm -P available; falling back to rm. APFS SSD garbage collection still applies."
    rm -rf "$p"
  fi
}

# Auto-pick GPG recipient if not specified. Returns the keyid on stdout.
auto_recipient() {
  command -v gpg >/dev/null 2>&1 || { err "gpg not installed (brew install gnupg)"; exit 2; }
  local keys
  keys=$(gpg --list-secret-keys --keyid-format LONG 2>/dev/null \
           | awk '/^sec/ {split($2, a, "/"); print a[2]}')
  local count
  count=$(echo "$keys" | grep -c . || true)
  if [ "$count" -eq 0 ]; then
    err "no GPG secret keys found -- generate one or pass --recipient KEYID"
    exit 2
  fi
  if [ "$count" -gt 1 ]; then
    err "multiple GPG secret keys present -- pass --recipient KEYID to disambiguate. Available:"
    echo "$keys" | sed 's/^/  /' >&2
    exit 2
  fi
  echo "$keys"
}

# GPG args for non-interactive passphrase mode if --passphrase-file given.
gpg_pass_args() {
  if [ -n "$PASS_FILE" ]; then
    test -f "$PASS_FILE" || { err "passphrase file not found: $PASS_FILE"; exit 2; }
    echo "--batch --yes --pinentry-mode loopback --passphrase-file $PASS_FILE"
  fi
}

# --- Commands -------------------------------------------------------------

cmd_seal() {
  test -d "$CREDS_DIR" || { err "no credentials dir at $CREDS_DIR -- nothing to seal"; exit 2; }

  # Pick recipient.
  if [ -z "$RECIPIENT" ]; then
    RECIPIENT=$(auto_recipient)
    log "auto-recipient: $RECIPIENT"
  fi

  # Build the list of files to seal (everything in CREDS_DIR EXCEPT the .gpg target).
  local file_list count total_bytes
  file_list=$(mktemp)
  trap 'rm -f "$file_list"' EXIT
  (
    cd "$CREDS_DIR"
    # NUL-delimited so paths with spaces survive.
    find . -mindepth 1 \! -path './credentials.tar.gz.gpg' -print0
  ) > "$file_list"

  count=$(tr -cd '\0' < "$file_list" | wc -c | tr -d ' ')
  if [ "$count" -eq 0 ]; then
    err "credentials dir is empty (or only contains the existing .gpg) -- nothing to seal"
    exit 2
  fi

  total_bytes=$( (cd "$CREDS_DIR" && xargs -0 -I {} stat -f '%z' "{}" < "$file_list" 2>/dev/null \
                 | awk '{s+=$1} END {print s+0}') )
  log "sealing $count items, ~$total_bytes bytes"

  # Tar -> gzip -> gpg pipeline. Tar reads paths from $file_list NUL-delimited.
  local tmp_tar
  tmp_tar=$(mktemp -t creds.tar.gz.XXXX)
  trap 'rm -f "$file_list" "$tmp_tar"' EXIT

  (cd "$CREDS_DIR" && tar --null -czf "$tmp_tar" -T "$file_list") || {
    err "tar failed"
    exit 1
  }

  # shellcheck disable=SC2046
  if [ -n "$PASS_FILE" ]; then
    gpg $(gpg_pass_args) --output "$SEALED.tmp" --encrypt --recipient "$RECIPIENT" "$tmp_tar"
  else
    gpg --yes --output "$SEALED.tmp" --encrypt --recipient "$RECIPIENT" "$tmp_tar"
  fi || { err "gpg encrypt failed"; rm -f "$SEALED.tmp"; exit 1; }

  mv "$SEALED.tmp" "$SEALED"
  log "wrote sealed bundle -> $SEALED ($(stat -f '%z' "$SEALED") bytes)"

  # Shred plaintext sources now that the encrypted copy exists.
  (
    cd "$CREDS_DIR"
    while IFS= read -r -d '' rel; do
      shred_path "$rel"
    done < "$file_list"
  )
  log "shredded plaintext sources"

  rm -f "$tmp_tar" "$file_list"
  trap - EXIT

  echo "encrypt_creds.sh: sealed -> $SEALED"
}

cmd_unseal() {
  test -f "$SEALED" || { err "no sealed bundle at $SEALED"; exit 2; }
  command -v gpg >/dev/null 2>&1 || { err "gpg not installed"; exit 2; }

  if [ -z "$OUT_DIR" ]; then
    OUT_DIR=$(mktemp -d -t creds-unseal.XXXX)
  else
    mkdir -p "$OUT_DIR"
  fi
  log "unsealing into $OUT_DIR"

  local tmp_tar
  tmp_tar=$(mktemp -t creds-decrypt.tar.gz.XXXX)

  # shellcheck disable=SC2046
  if [ -n "$PASS_FILE" ]; then
    gpg $(gpg_pass_args) --output "$tmp_tar" --decrypt "$SEALED"
  else
    gpg --yes --output "$tmp_tar" --decrypt "$SEALED"
  fi || { err "gpg decrypt failed"; rm -f "$tmp_tar"; exit 1; }

  tar -xzf "$tmp_tar" -C "$OUT_DIR" || { err "tar extract failed"; rm -f "$tmp_tar"; shred_path "$OUT_DIR"; exit 1; }

  # Immediately shred the intermediate plaintext tar -- only the extracted tree should exist.
  shred_path "$tmp_tar"
  log "extracted to $OUT_DIR"

  # Print the path on stdout so restore can pick it up.
  echo "$OUT_DIR"
}

cmd_post_restore_cleanup() {
  test -n "$OUT_DIR" || { err "post-restore-cleanup requires --out DIR (the path returned by unseal)"; exit 3; }
  test -d "$OUT_DIR" || { err "no such directory: $OUT_DIR"; exit 2; }
  log "shredding $OUT_DIR"
  shred_path "$OUT_DIR"
  echo "encrypt_creds.sh: post-restore cleanup complete"
}

# --- Dispatch -------------------------------------------------------------
case "$CMD" in
  seal)                  cmd_seal ;;
  unseal)                cmd_unseal ;;
  post-restore-cleanup)  cmd_post_restore_cleanup ;;
  *) err "unknown command: $CMD (try: seal | unseal | post-restore-cleanup)"; exit 3 ;;
esac
