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
# Run all checks
# -----------------------------------------------------------------------------
check_disk_space
check_brew_doctor
check_mas_signed_in
check_mise_installed
check_chezmoi_pushed
check_fda
check_gpg_key

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
