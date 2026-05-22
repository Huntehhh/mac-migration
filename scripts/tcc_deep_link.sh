#!/usr/bin/env bash
# tcc_deep_link.sh — open System Settings to a TCC permission panel via URL scheme.
#
# Usage:
#   tcc_deep_link.sh <panel-name>          Open the panel in System Settings.
#   tcc_deep_link.sh --print-url <panel>   Print the x-apple.systempreferences: URL without opening it.
#   tcc_deep_link.sh --list                List every known panel-name -> URL mapping (for humans).
#
# Panel names (one per TCC category):
#   full-disk-access
#   accessibility
#   camera
#   microphone
#   screen-recording
#   automation
#   input-monitoring
#   contacts
#   calendars
#   reminders
#   photos
#   location
#   bluetooth
#   files-and-folders
#   developer-tools
#
# Note: URL schemes are stable across macOS 13+ (Ventura+). Some panel anchors may change in future
# major releases — verify after macOS upgrades. The base x-apple.systempreferences: scheme is documented
# Apple system behavior.
#
# Exit codes:
#   0  success
#   2  unknown panel name
#   3  invalid invocation

set -euo pipefail

# --- Panel -> URL map ----------------------------------------------------
# Each entry: panel-name|x-apple.systempreferences: URL
PANELS='full-disk-access|x-apple.systempreferences:com.apple.preference.security?Privacy_AllFiles
accessibility|x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility
camera|x-apple.systempreferences:com.apple.preference.security?Privacy_Camera
microphone|x-apple.systempreferences:com.apple.preference.security?Privacy_Microphone
screen-recording|x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture
automation|x-apple.systempreferences:com.apple.preference.security?Privacy_Automation
input-monitoring|x-apple.systempreferences:com.apple.preference.security?Privacy_ListenEvent
contacts|x-apple.systempreferences:com.apple.preference.security?Privacy_Contacts
calendars|x-apple.systempreferences:com.apple.preference.security?Privacy_Calendars
reminders|x-apple.systempreferences:com.apple.preference.security?Privacy_Reminders
photos|x-apple.systempreferences:com.apple.preference.security?Privacy_Photos
location|x-apple.systempreferences:com.apple.preference.security?Privacy_LocationServices
bluetooth|x-apple.systempreferences:com.apple.preference.security?Privacy_Bluetooth
files-and-folders|x-apple.systempreferences:com.apple.preference.security?Privacy_FilesAndFolders
developer-tools|x-apple.systempreferences:com.apple.preference.security?Privacy_DeveloperTools'

# --- Helpers -------------------------------------------------------------
lookup_url() {
  local panel="$1"
  echo "$PANELS" | awk -F'|' -v p="$panel" '$1 == p {print $2; found=1; exit} END {exit !found}'
}

list_panels() {
  printf '%-22s  %s\n' "PANEL" "URL"
  echo "$PANELS" | awk -F'|' '{printf "%-22s  %s\n", $1, $2}'
}

# --- Arg parse -----------------------------------------------------------
if [ $# -lt 1 ]; then
  sed -n '2,28p' "$0"
  exit 3
fi

case "$1" in
  --list)
    list_panels
    exit 0
    ;;
  --print-url)
    [ $# -eq 2 ] || { echo "tcc_deep_link.sh: --print-url requires a panel name" >&2; exit 3; }
    url=$(lookup_url "$2") || { echo "tcc_deep_link.sh: unknown panel: $2 (try --list)" >&2; exit 2; }
    echo "$url"
    exit 0
    ;;
  -h|--help)
    sed -n '2,28p' "$0"
    exit 0
    ;;
  --*)
    echo "tcc_deep_link.sh: unknown flag: $1" >&2
    exit 3
    ;;
  *)
    PANEL="$1"
    ;;
esac

# --- Open the panel -----------------------------------------------------
url=$(lookup_url "$PANEL") || { echo "tcc_deep_link.sh: unknown panel: $PANEL (try --list)" >&2; exit 2; }

command -v open >/dev/null 2>&1 || { echo "tcc_deep_link.sh: 'open' not found — not macOS?" >&2; exit 2; }
open "$url"
echo "tcc_deep_link.sh: opened $PANEL ($url)"
