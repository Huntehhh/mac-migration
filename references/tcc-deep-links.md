# System Settings Deep Links for TCC Re-Grant

**Audience:** The `mac-migration` skill (restore + diff sub-skills). Used to surface clickable URLs in the diff report so the user can re-grant TCC permissions in two clicks instead of hunting through System Settings menus.
**Purpose:** TCC (Transparency, Consent, and Control) is the Apple subsystem that gates app access to Full Disk Access, Accessibility, Camera, Mic, Screen Recording, etc. The TCC database is per-machine and cannot be migrated programmatically without MDM. This doc is the canonical table of `x-apple.systempreferences:` URL schemes the skill emits.

---

## Why TCC permissions don't migrate

The TCC database lives at `~/Library/Application Support/com.apple.TCC/TCC.db` (user-scope) and `/Library/Application Support/com.apple.TCC/TCC.db` (system-scope). Both are SQLite, both are sealed behind SIP, and both contain hashes tied to:

- The granting Mac's hardware identifier
- The granted app's code signature + bundle ID
- The exact path the app was granted from at the time

Copying the `TCC.db` to a new Mac fails three different ways: SIP blocks the write, the hardware ID hash doesn't match, and any app reinstalled from Brewfile gets a fresh code-signature inode that doesn't match the captured hash. Apple intentionally designed it this way — TCC grants are a user act of consent, not a configuration value.

MDM (Mobile Device Management) can pre-grant TCC via PPPC profile (Privacy Preferences Policy Control), but that requires a paid Apple Business Manager + MDM server. For an individual power user, MDM is overkill.

**The realistic path:** capture the LIST of apps that had TCC grants on the old Mac (sanity reference), then on the new Mac emit deep-link URLs to the right System Settings panel so the user can re-toggle each app with one click.

---

## Capture (sanity reference, requires Full Disk Access on the OLD Mac)

```bash
sqlite3 ~/Library/Application\ Support/com.apple.TCC/TCC.db \
  "SELECT service, client, auth_value FROM access WHERE auth_value > 0;" \
  > ~/migration-bundle/manifests/tcc-grants-user.txt

sudo sqlite3 /Library/Application\ Support/com.apple.TCC/TCC.db \
  "SELECT service, client, auth_value FROM access WHERE auth_value > 0;" \
  > ~/migration-bundle/manifests/tcc-grants-system.txt
```

`auth_value` semantics:
- `0` — denied
- `1` — unknown (legacy)
- `2` — allowed (the rows the skill cares about)
- `3` — limited (Photos: "Limited Access")
- `4` — added but not yet prompted

`service` is the TCC service constant (e.g., `kTCCServiceSystemPolicyAllFiles` for Full Disk Access).
`client` is the bundle ID of the app that holds the grant.

---

## The URL scheme table

These `x-apple.systempreferences:` URLs open System Settings directly to the named privacy panel on Sonoma, Sequoia, and Tahoe. Earlier macOS versions (Monterey, Ventura) use the same scheme but the panel locations differ slightly — the skill should branch on `detect_macos_version.sh` if supporting pre-Sonoma.

| Privacy panel | TCC service constant | URL |
|---------------|---------------------|-----|
| Full Disk Access | `kTCCServiceSystemPolicyAllFiles` | `x-apple.systempreferences:com.apple.preference.security?Privacy_AllFiles` |
| Accessibility | `kTCCServiceAccessibility` | `x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility` |
| Camera | `kTCCServiceCamera` | `x-apple.systempreferences:com.apple.preference.security?Privacy_Camera` |
| Microphone | `kTCCServiceMicrophone` | `x-apple.systempreferences:com.apple.preference.security?Privacy_Microphone` |
| Screen Recording | `kTCCServiceScreenCapture` | `x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture` |
| Input Monitoring | `kTCCServiceListenEvent` | `x-apple.systempreferences:com.apple.preference.security?Privacy_ListenEvent` |
| Automation (Apple Events) | `kTCCServiceAppleEvents` | `x-apple.systempreferences:com.apple.preference.security?Privacy_Automation` |
| Files and Folders | `kTCCServiceSystemPolicyDocumentsFolder` (and Desktop/Downloads/Removable variants) | `x-apple.systempreferences:com.apple.preference.security?Privacy_FilesAndFolders` |
| Developer Tools | `kTCCServiceDeveloperTool` | `x-apple.systempreferences:com.apple.preference.security?Privacy_DevTools` |
| General Privacy (landing page) | n/a | `x-apple.systempreferences:Privacy` |
| Location Services | `kTCCServiceLocation` | `x-apple.systempreferences:com.apple.preference.security?Privacy_LocationServices` |
| Photos | `kTCCServicePhotos` | `x-apple.systempreferences:com.apple.preference.security?Privacy_Photos` |
| Calendars | `kTCCServiceCalendar` | `x-apple.systempreferences:com.apple.preference.security?Privacy_Calendars` |
| Contacts | `kTCCServiceAddressBook` | `x-apple.systempreferences:com.apple.preference.security?Privacy_Contacts` |
| Reminders | `kTCCServiceReminders` | `x-apple.systempreferences:com.apple.preference.security?Privacy_Reminders` |

---

## How `tcc_deep_link.sh` consumes this table

The script accepts a short name (`fda`, `accessibility`, `mic`, etc.) and resolves to the URL via lookup, then calls `open <url>`:

```bash
#!/bin/bash
# scripts/tcc_deep_link.sh <panel-short-name>

case "$1" in
  fda|full-disk|all-files)        URL="x-apple.systempreferences:com.apple.preference.security?Privacy_AllFiles" ;;
  accessibility|a11y)              URL="x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility" ;;
  camera)                          URL="x-apple.systempreferences:com.apple.preference.security?Privacy_Camera" ;;
  mic|microphone)                  URL="x-apple.systempreferences:com.apple.preference.security?Privacy_Microphone" ;;
  screen|screen-recording)         URL="x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture" ;;
  input|input-monitoring)          URL="x-apple.systempreferences:com.apple.preference.security?Privacy_ListenEvent" ;;
  automation|apple-events)         URL="x-apple.systempreferences:com.apple.preference.security?Privacy_Automation" ;;
  files-folders|ff)                URL="x-apple.systempreferences:com.apple.preference.security?Privacy_FilesAndFolders" ;;
  dev|devtools|developer-tools)    URL="x-apple.systempreferences:com.apple.preference.security?Privacy_DevTools" ;;
  privacy)                         URL="x-apple.systempreferences:Privacy" ;;
  *) echo "Unknown panel: $1"; exit 1 ;;
esac

open "$URL"
```

The skill maps each captured TCC service constant (from `tcc-grants-user.txt`) to a panel short name when emitting the diff report.

---

## End-user workflow

After restore completes, the diff sub-skill produces a section like this in the report:

```
LANE J — Manual steps required

TCC permissions (15 apps held grants on old Mac, manual re-grant required):

  Full Disk Access (4 apps):
    - Visual Studio Code     -> open: x-apple.systempreferences:com.apple.preference.security?Privacy_AllFiles
    - iTerm.app              -> open: x-apple.systempreferences:com.apple.preference.security?Privacy_AllFiles
    - Raycast.app            -> open: x-apple.systempreferences:com.apple.preference.security?Privacy_AllFiles
    - Backblaze.app          -> open: x-apple.systempreferences:com.apple.preference.security?Privacy_AllFiles

  Accessibility (3 apps):
    - Raycast.app            -> open: x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility
    - Rectangle.app          -> open: x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility
    - Karabiner-Elements     -> open: x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility

  Screen Recording (2 apps):
    - Loom.app               -> open: x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture
    - CleanShot X            -> open: x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture

Click each URL above to jump directly to the right System Settings panel, then toggle the app on.
```

In a terminal emulator that supports clickable URLs (iTerm2, Warp, Ghostty, Kitty, Alacritty with the right config), the user clicks each `x-apple.systempreferences:` URL → System Settings opens directly to that panel → they flip the toggle for the named app → done.

In a non-clickable terminal, the user copy-pastes the URL into `open <url>` manually.

---

## Edge cases

- **Apps installed in different paths between old and new Mac.** TCC binds grants to the exact path. If `Visual Studio Code` was at `/Applications/Visual Studio Code.app` on the old Mac but `~/Applications/Visual Studio Code.app` on the new Mac, the panel will show the OLD path entry as an unresolved orphan — clear it manually, then drag the app in fresh.
- **Apps registered as Login Items via SMAppService.** These show up under **General > Login Items & Extensions**, not under **Privacy & Security**. URL: `x-apple.systempreferences:com.apple.LoginItems-Settings.extension`.
- **MDM-managed Macs.** If the new Mac is enrolled in MDM, TCC grants may be pre-applied via PPPC profile. Check `profiles -P` for active profiles before assuming the user needs to re-grant manually.
- **System Settings vs System Preferences.** Sonoma+ uses "System Settings" (the new redesigned panel). The URL scheme is the same — the panel routing is transparent. Older docs may reference "System Preferences"; treat the names as interchangeable for URL purposes.

---

## References

- [Apple — Manage Privacy & Security settings on Mac](https://support.apple.com/guide/mac-help/change-privacy-security-settings-mh11785/mac)
- [Howard Oakley — Privacy: a guide to TCC](https://eclecticlight.co/2024/02/12/privacy-a-guide-to-tcc/) — best independent reference on TCC internals
- [rtrouton/rtrouton_scripts — set_privacy_preference scripts](https://github.com/rtrouton/rtrouton_scripts) — MDM PPPC profile examples (out of scope for personal migration but useful reference)
- macOS man pages: `tccutil(1)` (can reset TCC for a bundle ID but cannot grant)
