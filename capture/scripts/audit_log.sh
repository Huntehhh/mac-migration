#!/usr/bin/env bash
# audit_log.sh
# Append a single-line JSON entry to $BUNDLE/migration.log.jsonl.
#
# Usage:
#   audit_log.sh <lane> <action> <status> [detail...]
#
# Args:
#   lane     short tag (lane-a, lane-b, ..., package)
#   action   what was attempted (e.g., brewfile, postgres, gpg-seal)
#   status   start | ok | warn | fail | skip | info
#   detail   free-form trailing text (joined with spaces)
#
# Example:
#   audit_log.sh lane-g postgres start "Running pg_dumpall"
#   audit_log.sh lane-g postgres ok "Captured 4 databases, 3.2 GB"
#
# Emits to $BUNDLE/migration.log.jsonl (one JSON object per line, ISO8601 timestamp).
# Stdout also gets a human-readable one-liner so capture logs to terminal too.

set -euo pipefail

BUNDLE="${BUNDLE:-$HOME/migration-bundle}"
LOG_FILE="$BUNDLE/migration.log.jsonl"

if [ "$#" -lt 3 ]; then
  echo "audit_log.sh: usage: <lane> <action> <status> [detail...]" >&2
  exit 2
fi

lane="$1"
action="$2"
status="$3"
shift 3
detail="$*"

# Ensure bundle dir exists (the first lane script may invoke us before any mkdir)
mkdir -p "$BUNDLE"

# ISO8601 timestamp with timezone (BSD date on macOS)
ts="$(date -u +%Y-%m-%dT%H:%M:%SZ)"

# Escape detail for JSON: replace backslashes, double-quotes, control chars
# BSD-flavored sed; keep it simple -- strip newlines/tabs to spaces, escape quotes/backslashes
escape_json() {
  printf '%s' "$1" \
    | tr '\n\r\t' '   ' \
    | sed 's/\\/\\\\/g; s/"/\\"/g'
}

detail_esc="$(escape_json "$detail")"
lane_esc="$(escape_json "$lane")"
action_esc="$(escape_json "$action")"
status_esc="$(escape_json "$status")"

line="{\"ts\":\"${ts}\",\"lane\":\"${lane_esc}\",\"action\":\"${action_esc}\",\"status\":\"${status_esc}\",\"detail\":\"${detail_esc}\"}"

printf '%s\n' "$line" >> "$LOG_FILE"

# Human-readable echo for terminal feedback
printf '[%s] %s/%s %s -- %s\n' "$ts" "$lane" "$action" "$status" "$detail"
