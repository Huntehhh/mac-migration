#!/usr/bin/env bash
#
# orphan_to_brewfile.sh
#
# Phase 1 hygiene pass. For each .app in /Applications NOT covered by Brewfile
# or `mas list`, search brew cask catalog and MAS catalog to see if it's
# available. Suggest one-liner the user can paste into their Brewfile.
#
# NEVER edits the Brewfile. User reviews + manually appends.
#
# Inputs:
#   $BUNDLE/manifests/system-apps.json         (output of system_profiler SPApplicationsDataType -json)
#   $BUNDLE/manifests/brew-casks.txt           (output of brew list --cask)
#   $BUNDLE/manifests/mas-installed.txt        (output of mas list)
#   $BUNDLE/manifests/orphan-apps.txt          (precomputed orphan list from scan_inventory.sh)
#
# Output:
#   stdout    Candidate brew/mas one-liners per orphan
#   $BUNDLE/manifests/orphan-suggestions.txt    Same content, persisted
#
# Env overrides:
#   BUNDLE   Default ~/migration-bundle
#
# Cron-rerunnable: yes.

set -euo pipefail

BUNDLE="${BUNDLE:-$HOME/migration-bundle}"
LOG="$BUNDLE/migration.log.jsonl"
ORPHANS_FILE="$BUNDLE/manifests/orphan-apps.txt"
SUGGESTIONS_FILE="$BUNDLE/manifests/orphan-suggestions.txt"

mkdir -p "$BUNDLE/manifests"
touch "$LOG"

iso_ts() { date -u +"%Y-%m-%dT%H:%M:%SZ"; }

log_entry() {
  local action="$1" status="$2" detail="$3"
  printf '{"ts":"%s","lane":"A","action":"%s","status":"%s","detail":"%s"}\n' \
    "$(iso_ts)" "$action" "$status" "$(printf '%s' "$detail" | sed 's/"/\\"/g')" \
    >> "$LOG"
}

if [ ! -f "$ORPHANS_FILE" ]; then
  echo "Orphan list not found at $ORPHANS_FILE." >&2
  echo "Run scan_inventory.sh first to generate it." >&2
  log_entry "orphan_to_brewfile" "skip" "no orphan list"
  exit 0
fi

orphan_count=$(wc -l < "$ORPHANS_FILE" | tr -d ' ')
if [ "$orphan_count" = "0" ]; then
  echo "No orphan apps detected. Nothing to suggest."
  log_entry "orphan_to_brewfile" "ok" "no orphans"
  : > "$SUGGESTIONS_FILE"
  exit 0
fi

if ! command -v brew >/dev/null 2>&1; then
  echo "brew not installed. Cannot search cask catalog." >&2
  log_entry "orphan_to_brewfile" "skip" "no brew"
  exit 0
fi

echo "Orphan apps -> Brewfile candidates"
echo "==================================="
echo "$orphan_count apps in /Applications are not covered by Brewfile or mas list."
echo "For each, searching brew cask + MAS catalog. Review and paste the lines"
echo "you want into your Brewfile."
echo
echo "# Generated $(iso_ts)" > "$SUGGESTIONS_FILE"

while IFS= read -r app_name; do
  [ -z "$app_name" ] && continue

  # Strip .app suffix if present
  app_clean=$(printf '%s' "$app_name" | sed -E 's/\.app$//')

  # Normalize for search: lowercase, replace spaces with hyphens
  app_query=$(printf '%s' "$app_clean" | tr '[:upper:]' '[:lower:]' | tr ' ' '-')

  echo "[$app_clean]"

  # Try brew cask search first
  cask_match=""
  if brew search --cask "$app_query" 2>/dev/null | grep -qx "$app_query"; then
    cask_match="$app_query"
  else
    # Fuzzy: first token-match in brew search output
    cask_match=$(brew search --cask "$app_query" 2>/dev/null | head -3 | tr ',' '\n' | sed 's/^ *//; s/ *$//' | head -1 || echo "")
  fi

  if [ -n "$cask_match" ] && [ "$cask_match" != "No formulae or casks found." ]; then
    line="cask \"$cask_match\""
    echo "  brew cask candidate: $line"
    echo "$line  # was: $app_clean" >> "$SUGGESTIONS_FILE"
  fi

  # Try Mac App Store
  if command -v mas >/dev/null 2>&1; then
    mas_result=$(mas search "$app_clean" 2>/dev/null | head -3 || echo "")
    if [ -n "$mas_result" ]; then
      first=$(printf '%s' "$mas_result" | head -1)
      mas_id=$(printf '%s' "$first" | awk '{print $1}')
      mas_name=$(printf '%s' "$first" | sed -E 's/^[0-9]+ +//; s/ +\([^)]*\)$//')
      if [ -n "$mas_id" ] && [ "$mas_id" -gt 0 ] 2>/dev/null; then
        line="mas \"$mas_name\", id: $mas_id"
        echo "  mas candidate:       $line"
        echo "$line  # was: $app_clean" >> "$SUGGESTIONS_FILE"
      fi
    fi
  fi

  # If nothing found
  if [ -z "$cask_match" ]; then
    echo "  (no automatic match - manual install or DMG drop-in)"
    echo "# $app_clean  -- no auto match, manual install" >> "$SUGGESTIONS_FILE"
  fi
  echo

done < "$ORPHANS_FILE"

echo "Suggestions written to $SUGGESTIONS_FILE"
echo "Review, then append the lines you want to your Brewfile by hand."

log_entry "orphan_to_brewfile" "ok" "$orphan_count orphans processed; suggestions at $SUGGESTIONS_FILE"

exit 0
