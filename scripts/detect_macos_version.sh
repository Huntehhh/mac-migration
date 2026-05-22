#!/usr/bin/env bash
# detect_macos_version.sh — returns the running macOS major version + codename.
#
# Usage:
#   detect_macos_version.sh                  -> "26 Tahoe"
#   detect_macos_version.sh --json           -> {"major":26,"codename":"Tahoe","raw":"26.0.1"}
#   detect_macos_version.sh --major-only     -> "26"
#   detect_macos_version.sh --codename-only  -> "Tahoe"
#
# Used by restore to trigger Tahoe SIP advisory and by diff for the report header.
#
# Exit codes:
#   0  detection succeeded
#   1  sw_vers failed (not running on macOS)
#   3  invalid invocation

set -euo pipefail

FORMAT="default"  # default | json | major-only | codename-only

while [ $# -gt 0 ]; do
  case "$1" in
    --json)          FORMAT="json"; shift ;;
    --major-only)    FORMAT="major-only"; shift ;;
    --codename-only) FORMAT="codename-only"; shift ;;
    -h|--help)
      sed -n '2,15p' "$0"
      exit 0
      ;;
    *)
      echo "detect_macos_version.sh: unknown flag: $1" >&2
      exit 3
      ;;
  esac
done

command -v sw_vers >/dev/null 2>&1 || { echo "detect_macos_version.sh: sw_vers not found — not macOS?" >&2; exit 1; }

raw=$(sw_vers -productVersion 2>/dev/null) || { echo "detect_macos_version.sh: sw_vers -productVersion failed" >&2; exit 1; }
major="${raw%%.*}"

# Major-to-codename map.
# - 10.x special-cased (Sierra .. Catalina; 10.0 .. 10.9 omitted as ancient).
# - 11..15 follow the macOS 11+ naming convention.
# - 26 is Tahoe (the major version jumped from 15 to 26 in 2025 to align with calendar year).
# - "future" placeholder for anything newer so callers don't have to crash on unknown.
case "$major" in
  10)
    minor="${raw#10.}"
    minor="${minor%%.*}"
    case "$minor" in
      12) codename="Sierra" ;;
      13) codename="High Sierra" ;;
      14) codename="Mojave" ;;
      15) codename="Catalina" ;;
      *)  codename="macOS 10.$minor" ;;
    esac
    ;;
  11) codename="Big Sur" ;;
  12) codename="Monterey" ;;
  13) codename="Ventura" ;;
  14) codename="Sonoma" ;;
  15) codename="Sequoia" ;;
  26) codename="Tahoe" ;;
  27) codename="future" ;;
  *)  codename="unknown" ;;
esac

case "$FORMAT" in
  default)
    echo "$major $codename"
    ;;
  json)
    # Quote-escape codename in case future names contain a quote (defensive).
    cn_esc=${codename//\\/\\\\}
    cn_esc=${cn_esc//\"/\\\"}
    printf '{"major":%s,"codename":"%s","raw":"%s"}\n' "$major" "$cn_esc" "$raw"
    ;;
  major-only)
    echo "$major"
    ;;
  codename-only)
    echo "$codename"
    ;;
esac
