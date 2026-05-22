#!/usr/bin/env bash
#
# brewfile_prune_suggest.sh
#
# Phase 1 hygiene pass. Dumps the current Brewfile, walks each formula/cask,
# and surfaces prune candidates - formulae nothing depends on, casks that are
# rarely run. NEVER actually prunes. User reviews and decides.
#
# Heuristics:
#   1. Formula has zero reverse-dependencies AND is not in brew leaves -> candidate
#      (Note: `brew leaves` already filters to top-level packages, so any formula
#       in leaves is a deliberate install. Anything NOT in leaves AND with no
#       reverse-deps is a dangling library - usually safe to prune.)
#   2. Cask is installed but the .app under /Applications hasn't been opened in 90d
#      (uses `mdls -name kMDItemLastUsedDate`)
#
# Output:
#   stdout  Prune candidates with reason
#   log     $BUNDLE/migration.log.jsonl appended
#
# Env overrides:
#   BUNDLE   Default ~/migration-bundle
#
# Cron-rerunnable: yes.

set -euo pipefail

BUNDLE="${BUNDLE:-$HOME/migration-bundle}"
LOG="$BUNDLE/migration.log.jsonl"
DUMP_FILE="/tmp/Brewfile.current.$$"

mkdir -p "$BUNDLE"
touch "$LOG"

iso_ts() { date -u +"%Y-%m-%dT%H:%M:%SZ"; }

log_entry() {
  local action="$1" status="$2" detail="$3"
  printf '{"ts":"%s","lane":"A","action":"%s","status":"%s","detail":"%s"}\n' \
    "$(iso_ts)" "$action" "$status" "$(printf '%s' "$detail" | sed 's/"/\\"/g')" \
    >> "$LOG"
}

cleanup() { rm -f "$DUMP_FILE"; }
trap cleanup EXIT

if ! command -v brew >/dev/null 2>&1; then
  echo "brew not installed; nothing to prune." >&2
  log_entry "brewfile_prune" "skip" "brew not installed"
  exit 0
fi

echo "Dumping current Brewfile to $DUMP_FILE..."
brew bundle dump --force --describe --file="$DUMP_FILE" 2>/dev/null

# -----------------------------------------------------------------------------
# Formulae - candidates: installed-but-not-in-leaves AND no reverse-deps
# -----------------------------------------------------------------------------
echo
echo "Formula prune candidates"
echo "========================"
echo "(Installed but no top-level use and no reverse-deps. Review before pruning.)"
echo

leaves_file=$(mktemp -t brew-leaves.XXXXXX)
brew leaves > "$leaves_file" 2>/dev/null

formula_candidates=()
while IFS= read -r formula; do
  [ -z "$formula" ] && continue
  if grep -qxF "$formula" "$leaves_file"; then
    continue  # top-level - explicit install
  fi
  uses_count=$(brew uses --installed "$formula" 2>/dev/null | wc -l | tr -d ' ' || echo 0)
  if [ "$uses_count" = "0" ]; then
    formula_candidates+=("$formula")
    echo "  $formula  (no reverse-deps, not in brew leaves)"
  fi
done < <(brew list --formula 2>/dev/null)

if [ ${#formula_candidates[@]} -eq 0 ]; then
  echo "  (none - every installed formula is either top-level or a live dependency)"
fi

rm -f "$leaves_file"

# -----------------------------------------------------------------------------
# Casks - candidates: app not opened in 90 days
# -----------------------------------------------------------------------------
echo
echo "Cask prune candidates"
echo "====================="
echo "(GUI apps with last-used timestamp >90 days ago. Review before pruning.)"
echo

cask_candidates=()
ninety_days_ago=$(($(date -u +%s) - 90 * 86400))

while IFS= read -r cask; do
  [ -z "$cask" ] && continue

  # Resolve cask's .app artifact name(s)
  app_names=$(brew info --cask "$cask" --json=v2 2>/dev/null | \
    jq -r '.casks[0].artifacts[]?.app[]? // empty' 2>/dev/null)

  if [ -z "$app_names" ]; then
    continue
  fi

  for app in $app_names; do
    app_path="/Applications/$app"
    [ ! -d "$app_path" ] && continue

    last_used=$(mdls -name kMDItemLastUsedDate -raw "$app_path" 2>/dev/null || echo "")
    if [ -z "$last_used" ] || [ "$last_used" = "(null)" ]; then
      cask_candidates+=("$cask")
      echo "  $cask  ($app - never opened or no usage tracking)"
      continue
    fi

    # Parse the macOS ISO date and compare
    last_used_epoch=$(date -j -f "%Y-%m-%d %H:%M:%S %z" "$last_used" +%s 2>/dev/null || echo 0)
    if [ "$last_used_epoch" -lt "$ninety_days_ago" ] && [ "$last_used_epoch" != "0" ]; then
      cask_candidates+=("$cask")
      days_ago=$(( ( $(date -u +%s) - last_used_epoch ) / 86400 ))
      echo "  $cask  ($app - last used $days_ago days ago)"
    fi
  done
done < <(brew list --cask 2>/dev/null)

if [ ${#cask_candidates[@]} -eq 0 ]; then
  echo "  (none - every cask app has been opened within the last 90 days)"
fi

# -----------------------------------------------------------------------------
# Summary
# -----------------------------------------------------------------------------
echo
echo "Summary"
echo "-------"
echo "  Formula candidates: ${#formula_candidates[@]}"
echo "  Cask candidates:    ${#cask_candidates[@]}"
echo
echo "This script only SUGGESTS. To actually prune, run:"
echo "  brew uninstall <name>     # formula"
echo "  brew uninstall --cask <name>"
echo
echo "Or edit your Brewfile directly and re-run 'brew bundle cleanup --force'."

log_entry "brewfile_prune" "ok" "formula:${#formula_candidates[@]} cask:${#cask_candidates[@]} candidates"

exit 0
