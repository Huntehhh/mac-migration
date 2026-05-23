#!/usr/bin/env bash
# lane_done_marker.sh -- manage .done/<lane> markers for idempotent re-runs.
#
# Usage:
#   lane_done_marker.sh set    <lane> [status]  # write marker (status default: done)
#   lane_done_marker.sh check  <lane>   # exit 0 if marker exists, 1 otherwise
#   lane_done_marker.sh status <lane>   # print the marker's status (or "absent")
#   lane_done_marker.sh clear  <lane>   # remove the marker (for --force re-runs)
#   lane_done_marker.sh list            # print every marker: lane\tstatus\ttimestamp
#   lane_done_marker.sh clear-all       # nuke all markers (re-run everything)
#
# Status enum (2nd arg to `set`; default "done" for backward compatibility):
#   populated    -- lane ran and captured 1+ items
#   empty        -- lane ran, captured 0 items (e.g. no Postgres installed)
#   tool_missing -- lane skipped because a required tool was absent
#   opted_out    -- user opted this lane out in manifest.json
#   failed       -- lane ran but errored (marker still written for diagnosis)
#   done         -- generic completion (legacy default)
# Any lane with a marker counts as "not pending" for package_bundle.sh verify.
#
# Environment:
#   BUNDLE  default: $HOME/migration-bundle
#
# Lane name discipline:
#   - Letters allowed: a-z A-Z 0-9 - _
#   - Slashes / dots rejected (no path traversal)
#   - Empty lane name rejected
#
# Exit codes:
#   0  command succeeded (or check returned "marker present")
#   1  check returned "no marker"; or set/clear failed
#   3  invalid invocation

set -euo pipefail

BUNDLE="${BUNDLE:-$HOME/migration-bundle}"
DONE_DIR="$BUNDLE/.done"

# --- Helpers --------------------------------------------------------------
validate_lane() {
  local lane="${1:-}"
  [ -n "$lane" ] || { echo "lane_done_marker.sh: lane name required" >&2; exit 3; }
  case "$lane" in
    */*|.*|*..*)
      echo "lane_done_marker.sh: invalid lane name: $lane (no slashes or dot-segments)" >&2
      exit 3
      ;;
  esac
  case "$lane" in
    *[!a-zA-Z0-9_-]*)
      echo "lane_done_marker.sh: invalid lane name: $lane (only alnum, -, _)" >&2
      exit 3
      ;;
  esac
}

now_iso() { date -u +"%Y-%m-%dT%H:%M:%SZ"; }

# --- Dispatch -------------------------------------------------------------
cmd="${1:-}"; [ $# -gt 0 ] && shift || true

case "$cmd" in
  set)
    validate_lane "${1:-}"
    status="${2:-done}"
    case "$status" in
      populated|empty|tool_missing|opted_out|failed|done) ;;
      *) echo "lane_done_marker.sh: invalid status: $status" >&2; exit 3 ;;
    esac
    mkdir -p "$DONE_DIR"
    # Line 1 = timestamp (keeps `list` head-1 reads working); line 2 = status.
    printf '%s\nstatus=%s\n' "$(now_iso)" "$status" > "$DONE_DIR/$1"
    ;;

  check)
    validate_lane "${1:-}"
    if [ -f "$DONE_DIR/$1" ]; then
      exit 0
    else
      exit 1
    fi
    ;;

  status)
    validate_lane "${1:-}"
    if [ -f "$DONE_DIR/$1" ]; then
      # Extract status= line; default to "done" for legacy markers without it.
      st=$(grep -m1 '^status=' "$DONE_DIR/$1" 2>/dev/null | cut -d= -f2)
      printf '%s\n' "${st:-done}"
    else
      printf 'absent\n'
      exit 1
    fi
    ;;

  clear)
    validate_lane "${1:-}"
    rm -f "$DONE_DIR/$1"
    ;;

  list)
    if [ ! -d "$DONE_DIR" ]; then
      exit 0
    fi
    # Format: <lane>\t<status>\t<timestamp>
    find "$DONE_DIR" -maxdepth 1 -type f 2>/dev/null | sort | while IFS= read -r f; do
      lane=$(basename "$f")
      ts=$(head -1 "$f" 2>/dev/null || echo "unknown")
      st=$(grep -m1 '^status=' "$f" 2>/dev/null | cut -d= -f2)
      printf '%s\t%s\t%s\n' "$lane" "${st:-done}" "$ts"
    done
    ;;

  clear-all)
    [ -d "$DONE_DIR" ] && rm -f "$DONE_DIR"/*
    ;;

  -h|--help|"")
    sed -n '2,18p' "$0"
    [ -z "$cmd" ] && exit 3
    exit 0
    ;;

  *)
    echo "lane_done_marker.sh: unknown command: $cmd" >&2
    echo "Try: set | check | status | clear | list | clear-all" >&2
    exit 3
    ;;
esac
