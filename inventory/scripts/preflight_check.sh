#!/usr/bin/env bash
#
# preflight_check.sh
#
# Phase 1 gate. Probes for blockers BEFORE the inventory scan runs.
# Exits 0 if all hard checks pass. Exits non-zero with a blocker list if any hard check fails.
# Soft warnings continue with exit 0 but are surfaced in output.
#
# Output:
#   stdout  Human-readable PASS / WARN / FAIL list
#   stderr  Structured JSON summary (one line) for programmatic consumption
#   log     Appends one JSON entry per check to $BUNDLE/migration.log.jsonl
#
# Env overrides:
#   BUNDLE   Default ~/migration-bundle
#
# Cron-rerunnable: yes. No state outside $BUNDLE.

set -euo pipefail

BUNDLE="${BUNDLE:-$HOME/migration-bundle}"
LOG="$BUNDLE/migration.log.jsonl"
MIN_FREE_GB=20

mkdir -p "$BUNDLE"
touch "$LOG"

declare -a PASS=()
declare -a WARN=()
declare -a FAIL=()

iso_ts() { date -u +"%Y-%m-%dT%H:%M:%SZ"; }

log_check() {
  local lane="$1" action="$2" status="$3" detail="$4"
  printf '{"ts":"%s","lane":"%s","action":"%s","status":"%s","detail":"%s"}\n' \
    "$(iso_ts)" "$lane" "$action" "$status" "$(printf '%s' "$detail" | sed 's/"/\\"/g')" \
    >> "$LOG"
}

record_pass() { PASS+=("$1"); log_check "preflight" "$1" "ok" "$2"; }
record_warn() { WARN+=("$1: $2"); log_check "preflight" "$1" "warn" "$2"; }
record_fail() { FAIL+=("$1: $2"); log_check "preflight" "$1" "fail" "$2"; }

# -----------------------------------------------------------------------------
# Check 1: disk space (hard fail)
# -----------------------------------------------------------------------------
check_disk_space() {
  # df -k -P gives portable POSIX output. Column 4 = available 1KB blocks.
  local avail_kb
  avail_kb=$(df -k -P "$HOME" | awk 'NR==2 {print $4}')
  local avail_gb=$(( avail_kb / 1024 / 1024 ))
  if [ "$avail_gb" -ge "$MIN_FREE_GB" ]; then
    record_pass "disk_space" "${avail_gb}GB free (>= ${MIN_FREE_GB}GB required)"
  else
    record_fail "disk_space" "Only ${avail_gb}GB free on \$HOME; need >= ${MIN_FREE_GB}GB"
  fi
}

# -----------------------------------------------------------------------------
# Check 2: brew doctor (soft warn)
# -----------------------------------------------------------------------------
check_brew_doctor() {
  if ! command -v brew >/dev/null 2>&1; then
    record_warn "brew_doctor" "brew not installed; Lane A will be skipped"
    return
  fi
  local out
  out=$(brew doctor 2>&1 || true)
  if printf '%s' "$out" | grep -q "Your system is ready to brew"; then
    record_pass "brew_doctor" "clean"
  else
    local warn_count
    warn_count=$(printf '%s' "$out" | grep -c '^Warning:' || true)
    record_warn "brew_doctor" "${warn_count} warnings (run 'brew doctor' to review)"
  fi
}

# -----------------------------------------------------------------------------
# Check 3: Mac App Store signed in (hard fail)
# -----------------------------------------------------------------------------
check_mas_signed_in() {
  if ! command -v mas >/dev/null 2>&1; then
    record_fail "mas_signed_in" "mas-cli not installed (brew install mas)"
    return
  fi
  if mas account >/dev/null 2>&1; then
    local acct
    acct=$(mas account 2>/dev/null | head -1)
    record_pass "mas_signed_in" "signed in as $acct"
  else
    record_fail "mas_signed_in" "Open App Store, sign in with Apple ID, retry"
  fi
}

# -----------------------------------------------------------------------------
# Check 4: mise installed (hard fail)
# -----------------------------------------------------------------------------
check_mise_installed() {
  if command -v mise >/dev/null 2>&1; then
    local ver
    ver=$(mise --version 2>/dev/null | head -1)
    record_pass "mise" "$ver"
  else
    record_fail "mise" "mise not installed (brew install mise); Lane C1 cannot proceed"
  fi
}

# -----------------------------------------------------------------------------
# Check 5: chezmoi repo pushed (soft warn)
# -----------------------------------------------------------------------------
check_chezmoi_pushed() {
  if ! command -v chezmoi >/dev/null 2>&1; then
    record_warn "chezmoi" "chezmoi not installed; dotfiles will fall back to raw copy"
    return
  fi
  local source
  source=$(chezmoi source-path 2>/dev/null || echo "")
  if [ -z "$source" ] || [ ! -d "$source" ]; then
    record_warn "chezmoi" "no chezmoi source path; dotfiles fall back to raw copy"
    return
  fi
  # Check unpushed commits
  local unpushed
  unpushed=$(cd "$source" && git log '@{u}..' --oneline 2>/dev/null | wc -l | tr -d ' ' || echo 0)
  if [ "$unpushed" = "0" ]; then
    record_pass "chezmoi" "repo at $source, fully pushed to origin"
  else
    record_warn "chezmoi" "$unpushed local commits not pushed; new Mac will lag"
  fi
}

# -----------------------------------------------------------------------------
# Check 6: Full Disk Access on /bin/bash (hard fail)
# -----------------------------------------------------------------------------
check_fda() {
  # Probe by reading the TCC.db (FDA-gated). If the read succeeds, FDA is granted
  # to the process that invoked this script (Terminal, iTerm2, etc).
  local tcc_db="$HOME/Library/Application Support/com.apple.TCC/TCC.db"
  if [ ! -f "$tcc_db" ]; then
    record_warn "fda" "TCC.db not present (rare); skipping FDA probe"
    return
  fi
  if sqlite3 "$tcc_db" ".tables" >/dev/null 2>&1; then
    record_pass "fda" "Full Disk Access verified (read TCC.db succeeded)"
  else
    record_fail "fda" "Open System Settings > Privacy & Security > Full Disk Access, add your terminal app, reboot the terminal session"
  fi
}

# -----------------------------------------------------------------------------
# Check 7: GPG key present (hard fail)
# -----------------------------------------------------------------------------
check_gpg_key() {
  if ! command -v gpg >/dev/null 2>&1; then
    record_fail "gpg_key" "gpg not installed (brew install gnupg); Lane I encryption needs a key"
    return
  fi
  local secret_count
  secret_count=$(gpg --list-secret-keys --with-colons 2>/dev/null | grep -c '^sec:' || true)
  if [ "$secret_count" -gt 0 ]; then
    local first_id
    first_id=$(gpg --list-secret-keys --with-colons 2>/dev/null | awk -F: '/^sec:/ {print $5; exit}')
    record_pass "gpg_key" "$secret_count secret key(s); first ID: $first_id"
  else
    record_fail "gpg_key" "No GPG secret key found. Run: gpg --full-generate-key"
  fi
}

# -----------------------------------------------------------------------------
# Check 8: GPG key sideband export (hard fail) -- prevents the lockout trap.
#
# THE TRAP: Lane I encrypts the bundle WITH the user's GPG key, and the key
# itself (~/.gnupg/) is captured INSIDE Lane I. On a fresh Mac with no key,
# you cannot decrypt the bundle to retrieve the key you need to decrypt it.
# Permanent lockout, silent until restore day.
#
# THE GUARD: export the secret key NOW to a file OUTSIDE the bundle, named so
# the user cannot miss it. They must carry THIS file to the new Mac via a
# separate channel (USB / password manager) and import it BEFORE restore.
# Passphrase-protected keys stay passphrase-locked in the export, so the file
# is no more sensitive than the key already is.
# -----------------------------------------------------------------------------
check_gpg_sideband_export() {
  # Only run if a key exists (Check 7 handles the no-key case).
  command -v gpg >/dev/null 2>&1 || return
  local secret_count
  secret_count=$(gpg --list-secret-keys --with-colons 2>/dev/null | grep -c '^sec:' || true)
  [ "${secret_count:-0}" -gt 0 ] || return

  # Export OUTSIDE $BUNDLE so it is never packaged + encrypted into the bundle.
  local export_dir="$HOME"
  case "$BUNDLE" in
    "$HOME") export_dir="$HOME/.." ;;   # paranoid: if BUNDLE==HOME, step out
  esac
  local key_file="$export_dir/migration-gpg-key-BRING-SEPARATELY.asc"
  local trust_file="$export_dir/migration-gpg-ownertrust-BRING-SEPARATELY.txt"

  if gpg --batch --yes --export-secret-keys --armor > "$key_file" 2>/dev/null \
     && [ -s "$key_file" ]; then
    chmod 600 "$key_file" 2>/dev/null || true
    gpg --export-ownertrust > "$trust_file" 2>/dev/null || true
    chmod 600 "$trust_file" 2>/dev/null || true
    record_pass "gpg_sideband" "exported to $key_file -- CARRY THIS SEPARATELY (USB / password manager), NOT inside the bundle"
    # Also drop a loud, unmissable warning file at the bundle root.
    cat > "$BUNDLE/GPG-KEY-WARNING.txt" <<EOF
CRITICAL -- READ BEFORE WIPING THE OLD MAC
==========================================

Your migration bundle's credentials (Lane I) are GPG-encrypted with your key.
Your GPG key itself is INSIDE that encrypted bundle. That means:

  On the new Mac, you CANNOT decrypt the bundle until your GPG key is imported,
  and the only copy is locked inside the bundle you're trying to open.

To avoid permanent lockout, your key was exported here (OUTSIDE the bundle):

  $key_file
  $trust_file

DO THIS NOW, before wiping the old Mac:
  1. Copy both files above to a USB stick OR your password manager.
  2. Do NOT put them in the migration bundle.
  3. On the new Mac, BEFORE running restore:
       gpg --import "migration-gpg-key-BRING-SEPARATELY.asc"
       gpg --import-ownertrust "migration-gpg-ownertrust-BRING-SEPARATELY.txt"
  4. Then run restore. Lane I will decrypt.

If you use a YubiKey / smartcard for GPG, you don't need these files -- just
bring the YubiKey. But verify 'gpg --card-status' works on the new Mac first.
EOF
  else
    rm -f "$key_file" 2>/dev/null || true
    record_fail "gpg_sideband" "Could not export GPG secret key. Export manually: gpg --export-secret-keys -a > ~/migration-gpg-key.asc and carry it to the new Mac separately, or you will be locked out of the encrypted bundle."
  fi
}

# -----------------------------------------------------------------------------
# Run all checks
# -----------------------------------------------------------------------------
check_disk_space
check_brew_doctor
check_mas_signed_in
check_mise_installed
# -----------------------------------------------------------------------------
# Check 9: bundle size estimate (informational) -- "know before you AirDrop it"
# -----------------------------------------------------------------------------
check_bundle_size_estimate() {
  # Rough heads-up only. The heavy lanes are D (Application Support + fonts) and
  # G (database dumps). Sum the big sources in MB; report GB.
  local total_mb=0 mb
  for d in "$HOME/Library/Application Support" "$HOME/Library/Fonts"; do
    if [ -d "$d" ]; then
      mb=$(du -sm "$d" 2>/dev/null | awk '{print $1}')
      total_mb=$((total_mb + ${mb:-0}))
    fi
  done
  # Postgres data dir (a proxy for dump size) if present.
  for pg in /opt/homebrew/var/postgresql@* /usr/local/var/postgresql@*; do
    if [ -d "$pg" ]; then
      mb=$(du -sm "$pg" 2>/dev/null | awk '{print $1}')
      total_mb=$((total_mb + ${mb:-0}))
    fi
  done
  local gb=$(( total_mb / 1024 ))
  record_pass "bundle_estimate" "~${gb}GB (rough; caches excluded at capture time). Have a USB / transfer channel ready for at least this much."
}

check_chezmoi_pushed
check_fda
check_gpg_key
check_gpg_sideband_export
check_bundle_size_estimate

# -----------------------------------------------------------------------------
# Render results to stdout
# -----------------------------------------------------------------------------
echo "Pre-flight check (Phase 1 gate)"
echo "================================="

if [ ${#PASS[@]} -gt 0 ]; then
  echo
  echo "PASS:"
  for p in "${PASS[@]}"; do
    echo "  [+] $p"
  done
fi

if [ ${#WARN[@]} -gt 0 ]; then
  echo
  echo "WARN (continuing):"
  for w in "${WARN[@]}"; do
    echo "  [!] $w"
  done
fi

if [ ${#FAIL[@]} -gt 0 ]; then
  echo
  echo "FAIL (blockers):"
  for f in "${FAIL[@]}"; do
    echo "  [x] $f"
  done
  echo
  echo "Fix the blockers above and re-run."
fi

# -----------------------------------------------------------------------------
# Render JSON summary to stderr
# -----------------------------------------------------------------------------
{
  printf '{"ts":"%s","pass":[' "$(iso_ts)"
  first=1
  for p in "${PASS[@]:-}"; do
    [ -z "$p" ] && continue
    [ $first -eq 0 ] && printf ','
    printf '"%s"' "$p"
    first=0
  done
  printf '],"warn":['
  first=1
  for w in "${WARN[@]:-}"; do
    [ -z "$w" ] && continue
    [ $first -eq 0 ] && printf ','
    printf '"%s"' "$(printf '%s' "$w" | sed 's/"/\\"/g')"
    first=0
  done
  printf '],"fail":['
  first=1
  for f in "${FAIL[@]:-}"; do
    [ -z "$f" ] && continue
    [ $first -eq 0 ] && printf ','
    printf '"%s"' "$(printf '%s' "$f" | sed 's/"/\\"/g')"
    first=0
  done
  printf ']}\n'
} >&2

# -----------------------------------------------------------------------------
# Exit
# -----------------------------------------------------------------------------
if [ ${#FAIL[@]} -gt 0 ]; then
  exit 1
fi
exit 0
