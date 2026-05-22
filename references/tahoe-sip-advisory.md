# macOS 26 Tahoe — SIP and SMAppService Advisory

**Audience:** The `mac-migration` skill (capture + restore + diff). Triggered when `detect_macos_version.sh` returns `Tahoe` (major 26) on the target Mac.
**Purpose:** Tell the user — for every captured LaunchAgent / LaunchDaemon — whether it will run as-is on Tahoe, whether it needs an `SMAppService` rewrite, or whether it should be dropped.

---

## What changed in Tahoe

System Integrity Protection (SIP) tightened on `/Library/LaunchDaemons/` starting in macOS 26:

- **Root-owned LaunchDaemons that point at unsigned binaries are blocked at load time.** `launchctl bootstrap system /Library/LaunchDaemons/com.example.thing.plist` returns success, but the job never executes. No console errors — silent.
- **`/Library/LaunchAgents/` (system-wide user agents) is still permitted** but Apple now strongly recommends `SMAppService` registration from inside a signed app bundle.
- **User LaunchAgents (`~/Library/LaunchAgents/`) still work** without code-signing requirements — but the file owner must be the user, and any binary they invoke needs Full Disk Access if it touches protected paths.
- **Sandboxed apps can no longer install non-sandboxed daemons** (this constraint shipped in macOS 14.2 Sonoma; Tahoe enforces it more aggressively).

The shift is part of Apple's multi-year push from `launchd`-as-system to `SMAppService`-from-app-bundle. Reference: [Apple "What's new for enterprise in macOS Tahoe 26"](https://support.apple.com/guide/deployment/whats-new-tahoe-dep5b8e0f7eb/web) and [SMAppService developer docs](https://developer.apple.com/documentation/servicemanagement/smappservice).

---

## SMAppService is the modern replacement

`SMAppService` (Service Management framework) is how Apple wants launchd jobs registered on Tahoe and beyond. The pattern:

1. A signed `.app` bundle ships with embedded helper executables and a plist inside `Contents/Library/LaunchDaemons/` or `Contents/Library/LaunchAgents/`.
2. On first launch, the parent app calls `SMAppService.daemon(plistName: "com.example.helper.plist").register()`.
3. macOS reads the embedded plist, verifies the code signature chain matches the parent app, and registers the job.
4. The user sees and approves the registration in **System Settings > General > Login Items & Extensions**.

The plist on disk doesn't need to be in `/Library/LaunchDaemons/` — it lives inside the app bundle and macOS tracks it via the Service Management database.

### Minimal Swift registration snippet

```swift
import ServiceManagement

let service = SMAppService.daemon(plistName: "com.example.helper.plist")
do {
    try service.register()
    print("Registered. Status: \(service.status)")
} catch {
    print("Registration failed: \(error)")
}

// To unregister:
// try? service.unregister()
```

The embedded plist looks like a standard launchd plist with one extra constraint — `BundleProgram` (relative to the app bundle root) instead of `Program` (absolute path):

```xml
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN"
  "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>Label</key>
    <string>com.example.helper</string>
    <key>BundleProgram</key>
    <string>Contents/MacOS/HelperBinary</string>
    <key>RunAtLoad</key>
    <true/>
    <key>KeepAlive</key>
    <true/>
</dict>
</plist>
```

### The simpler path — wrap an unsigned binary in a minimal AppleScript app

For custom shell scripts the user wrote (not a full Xcode project), the migration skill can suggest the lightweight path:

1. Create `MyHelper.app` via Script Editor or Automator (saves as an app bundle).
2. Put the script in `MyHelper.app/Contents/Resources/script.sh`.
3. Add a launchd plist inside `MyHelper.app/Contents/Library/LaunchAgents/com.user.helper.plist`.
4. Codesign with the user's Developer ID (or ad-hoc sign for personal use): `codesign --force --deep --sign - MyHelper.app`.
5. Drop the app in `/Applications/` and double-click once to trigger `SMAppService.register()` (you'll need a tiny launcher script that calls it — or use `launchctl` for ad-hoc-signed agents which still work).

Ad-hoc signing (`--sign -`) is sufficient for personal use on Tahoe — Apple only blocks unsigned root daemons, not ad-hoc-signed user agents.

---

## Decision tree — keep as-is vs rewrite

When capture processes a plist, classify it:

| Source location | Owner | Binary path pattern | Tahoe verdict |
|-----------------|-------|---------------------|---------------|
| `~/Library/LaunchAgents/` | user | Any path under `$HOME`, `/opt/homebrew/`, `/Applications/` | **Keep as-is** — user agents are unaffected by the SIP tightening |
| `~/Library/LaunchAgents/` | user | Touches protected paths (`~/Documents`, `~/Desktop`, `~/Downloads`, Mail, Messages, Calendar, Contacts) | **Keep, but flag TCC** — emit a Full Disk Access deep link in the diff report |
| `/Library/LaunchAgents/` | root | Apple-signed binary or `/opt/homebrew/` formula | **Keep as-is** — system agents still load |
| `/Library/LaunchAgents/` | root | Custom unsigned script in `/usr/local/` or `/opt/` | **Rewrite as `SMAppService` agent** or move to user-scope (`~/Library/LaunchAgents/`) |
| `/Library/LaunchDaemons/` | root | Apple-signed binary (e.g., `com.apple.*` already there from OS) | **Skip — restore is destructive** — never replace Apple's own daemons |
| `/Library/LaunchDaemons/` | root | Homebrew formula's daemon (e.g., `homebrew.mxcl.postgresql@17`) | **Skip — re-run `brew services start <name>`** on the new Mac instead |
| `/Library/LaunchDaemons/` | root | Custom unsigned executable (user's own script in `/usr/local/bin/`) | **Rewrite as `SMAppService` daemon** — this is the case that silently fails on Tahoe |

---

## Detection — flagging a plist as Tahoe-incompatible

The reasoner reads each plist and flags any of these red signals:

1. **Plist lives in `/Library/LaunchDaemons/`** (root scope, not user scope).
2. **`Program` or `ProgramArguments[0]` is in `/usr/local/`, `/opt/`, `~/`, or any path NOT under `/System/`, `/Library/Apple/`, or `/opt/homebrew/`.**
3. **The referenced executable is NOT code-signed by Apple or a Developer ID** — verify with `codesign --verify --verbose <path>`. Exit code 0 = signed. Exit code 1 = unsigned or invalid.
4. **No `BundleProgram` key** — Apple's `SMAppService`-aware plists always use `BundleProgram` relative to a bundle root; legacy plists use `Program` with an absolute path.
5. **Owner is root and group is wheel**, but plist content references user-scoped paths like `$HOME` (smell test — the user wrote this as a quick fix, not via Apple's tooling).

If 1 + 2 + 3 all hit, the plist will silently fail on Tahoe. The skill surfaces a clear warning in the diff report.

---

## What the skill emits

For each Tahoe-incompatible plist, the restore lane H output includes:

```
LANE H — Background services
  WARN: /Library/LaunchDaemons/com.user.backup.plist
        Program: /usr/local/bin/backup.sh (unsigned, owner root)
        Status:  Will silently fail on Tahoe (SIP tightening).
        Options:
          (a) Move to ~/Library/LaunchAgents/ (recommended if no root privileges needed)
          (b) Rewrite as SMAppService daemon inside a signed app bundle
                See: ~/.claude/skills/mac-migration/references/tahoe-sip-advisory.md
          (c) Skip (drop the plist; lose the automation)

  KEEP: ~/Library/LaunchAgents/com.user.dotfile-sync.plist
        Program: /opt/homebrew/bin/chezmoi
        Status:  Compatible — user-scope, Homebrew-managed binary.
```

---

## References

- [Apple — SMAppService developer documentation](https://developer.apple.com/documentation/servicemanagement/smappservice)
- [Apple — What's new for enterprise in macOS Tahoe 26](https://support.apple.com/guide/deployment/whats-new-tahoe-dep5b8e0f7eb/web)
- [Eclectic Light Company — How macOS Login Items work](https://eclecticlight.co/2023/03/27/how-do-i-control-the-login-items-on-my-mac/) (covers the SMAppService migration arc through Ventura)
- [Apple — Updating helper executables from earlier versions of macOS](https://developer.apple.com/documentation/servicemanagement/updating-helper-executables-from-earlier-versions-of-macos)
- [WWDC22 Session 10116 — What's new in privacy](https://developer.apple.com/videos/play/wwdc2022/10116/) (sandbox + daemon constraints)
