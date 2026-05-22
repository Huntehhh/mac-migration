# launchd Plist Reasoner

**Audience:** Claude, when running capture / restore / diff for Lane H (background services). The reasoner is a markdown reference — not a script. Claude reads this doc while reasoning about each plist and produces a human-readable explanation + portability flags for the user.
**Purpose:** Power users typically have 5-30 launchd plists across `~/Library/LaunchAgents/`, `/Library/LaunchAgents/`, and `/Library/LaunchDaemons/`. Most are opaque. The reasoner explains each one in plain English and flags anything that will break on the new Mac.

---

## Plist schema cheat-sheet

Every launchd plist is XML with a flat `<dict>` of keys. The ones that matter for reasoning:

| Key | Type | What it does |
|-----|------|--------------|
| `Label` | string | Unique reverse-DNS identifier (e.g., `com.user.backup`). Must match filename minus `.plist`. |
| `Program` | string | Single absolute path to the executable. Mutually exclusive with `BundleProgram`. |
| `ProgramArguments` | array of strings | `[program, arg1, arg2, ...]`. If `Program` is absent, `ProgramArguments[0]` is the executable. |
| `BundleProgram` | string | Path relative to a containing app bundle. Used by `SMAppService`-registered plists. |
| `RunAtLoad` | bool | If true, runs immediately when launchd loads the job (boot for daemons, login for agents). |
| `KeepAlive` | bool OR dict | If true, restart whenever the process exits. If dict, conditional restart (e.g., `SuccessfulExit: false` means restart only on crash). |
| `StartInterval` | integer | Run every N seconds. Anchored to job-load time, not wall clock. |
| `StartCalendarInterval` | dict or array of dicts | Cron-style schedule. Keys: `Minute`, `Hour`, `Day`, `Weekday`, `Month`. Missing key = wildcard. |
| `WatchPaths` | array of strings | Run when any path in the list is modified. |
| `QueueDirectories` | array of strings | Run when any of these directories transitions from empty -> non-empty. |
| `EnvironmentVariables` | dict | Key-value env vars passed to the program. PATH usually needed here. |
| `WorkingDirectory` | string | `cd` here before running. |
| `StandardOutPath` | string | Redirect stdout to this file. |
| `StandardErrorPath` | string | Redirect stderr to this file. |
| `UserName` | string | Run as this user (LaunchDaemons only). |
| `GroupName` | string | Run as this group (LaunchDaemons only). |
| `ThrottleInterval` | integer | Minimum seconds between restarts (default 10). |
| `ProcessType` | string | `Background` / `Standard` / `Adaptive` / `Interactive`. Influences scheduling priority. |
| `Disabled` | bool | If true, job is registered but won't run until enabled. |
| `LimitLoadToSessionType` | string or array | `Aqua` (login session), `Background`, `LoginWindow`, `System`. |

Apple reference: [`man launchd.plist`](https://www.manpagez.com/man/5/launchd.plist/) and [Apple — Creating launchd Daemons](https://developer.apple.com/library/archive/documentation/MacOSX/Conceptual/BPSystemStartup/Chapters/CreatingLaunchdJobs.html).

---

## Common patterns the reasoner names

When Claude reads a plist, classify it into one of these patterns to produce a one-line explanation. If it matches more than one, name the primary purpose first.

### Pattern: time-based cron-replacement

```xml
<key>StartCalendarInterval</key>
<dict>
    <key>Hour</key>    <integer>3</integer>
    <key>Minute</key>  <integer>0</integer>
</dict>
```

**Explanation:** Runs at 3:00 AM every day. Like a cron `0 3 * * *` entry.

### Pattern: keep-alive daemon

```xml
<key>RunAtLoad</key> <true/>
<key>KeepAlive</key> <true/>
```

**Explanation:** Long-running service. Starts at login/boot and restarts every time it exits.

### Pattern: keep-alive conditional

```xml
<key>KeepAlive</key>
<dict>
    <key>SuccessfulExit</key> <false/>
</dict>
```

**Explanation:** Restart only on crash (non-zero exit). Lets the program shut itself down cleanly without an immediate restart loop.

### Pattern: watch-file trigger

```xml
<key>WatchPaths</key>
<array>
    <string>/Users/hunter/Dropbox/.dropbox-cache</string>
</array>
```

**Explanation:** Runs whenever the named file or directory is modified. Common for sync watchers and dotfile-auto-apply jobs.

### Pattern: interval timer

```xml
<key>StartInterval</key> <integer>300</integer>
```

**Explanation:** Runs every 300 seconds (5 minutes), measured from job-load time.

### Pattern: queue worker

```xml
<key>QueueDirectories</key>
<array>
    <string>/Users/hunter/inbox/process-queue</string>
</array>
```

**Explanation:** Runs when this directory transitions from empty to non-empty — a producer-consumer queue.

### Pattern: on-demand only (rare)

No `RunAtLoad`, no `KeepAlive`, no `StartInterval`, no `WatchPaths`. Job only runs when something else triggers it via `launchctl kickstart`.

**Explanation:** Manual / externally-triggered. Won't run on its own.

---

## Red flags — what the reasoner surfaces

For each plist, run through this checklist and emit a portability warning to the user if any hit. These are the actual reasons plists break after a migration.

### 1. Hardcoded `/usr/local/bin/...` paths on an Apple Silicon Mac

```xml
<key>ProgramArguments</key>
<array>
    <string>/usr/local/bin/my-tool</string>
</array>
```

**Why it breaks:** Apple Silicon Macs install Homebrew to `/opt/homebrew/`, not `/usr/local/`. If the user is migrating from Intel → Apple Silicon (or to a fresh Apple Silicon install), the path is dead.

**Surface:**
```
PORT WARNING: /Users/hunter/Library/LaunchAgents/com.user.tool.plist
  References /usr/local/bin/my-tool — this path will not exist on Apple Silicon.
  Suggested fix: change to /opt/homebrew/bin/my-tool, OR use $(brew --prefix)/bin/my-tool
  with EnvironmentVariables.PATH set.
```

### 2. Reference to a binary that won't exist after Brewfile install

```xml
<key>Program</key>
<string>/opt/homebrew/bin/some-tool</string>
```

If `some-tool` is NOT in the captured Brewfile, the plist will fail to run on the new Mac. Cross-check `ProgramArguments` against `~/migration-bundle/Brewfile`.

**Surface:**
```
PORT WARNING: ~/Library/LaunchAgents/com.user.thing.plist
  References /opt/homebrew/bin/some-tool but no Brewfile entry for 'some-tool'.
  Options:
    (a) Add `brew "some-tool"` to Brewfile and re-capture.
    (b) Install the tool manually on the new Mac before restoring Lane H.
    (c) Drop the plist (skip restore for this entry).
```

### 3. Reference to a path inside a moved/renamed home dir

```xml
<key>StandardOutPath</key>
<string>/Users/old-username/logs/job.log</string>
```

**Why it breaks:** If the new Mac's `whoami` is `hunter` but the captured plist references `/Users/old-username/`, the log path doesn't exist and the job may silently fail (or write to a directory it can't, then crash).

**Surface:**
```
PORT WARNING: ~/Library/LaunchAgents/com.user.thing.plist
  Hardcoded username '/Users/old-username/' but current user is '/Users/hunter/'.
  Suggested fix: parameterize via $HOME or $(echo ~) — though launchd does NOT
  expand $HOME in plists by default. Use the literal path or wrap in a shell script
  that does the expansion at runtime.
```

(Note: launchd does NOT expand `$HOME` inside `<string>` values. Use `EnvironmentVariables` + a script wrapper if path-portability matters.)

### 4. Tahoe-incompatible LaunchDaemon

If running on macOS 26 Tahoe, and the plist:
- Lives in `/Library/LaunchDaemons/`,
- Owner is root,
- `Program` is an unsigned binary in `/usr/local/`, `/opt/`, or `~/`,

then the job will silently fail to load on Tahoe due to SIP tightening. See [tahoe-sip-advisory.md](tahoe-sip-advisory.md) for the SMAppService rewrite path.

**Surface:**
```
TAHOE WARNING: /Library/LaunchDaemons/com.user.backup.plist
  Will not load on Tahoe — unsigned executable in /usr/local/bin/.
  See: ~/.claude/skills/mac-migration/references/tahoe-sip-advisory.md
  Options:
    (a) Move to ~/Library/LaunchAgents/ (user-scope is unaffected).
    (b) Rewrite as SMAppService-registered daemon inside a signed app bundle.
    (c) Skip.
```

### 5. User-owned plist that needs Full Disk Access or Accessibility

If `Program` touches:
- `~/Documents`, `~/Desktop`, `~/Downloads` (Files and Folders TCC)
- `~/Library/Mail/`, `~/Library/Messages/` (FDA)
- `~/Library/Calendars/`, `~/Library/Address Book/` (per-domain TCC)
- Sends Apple Events to other apps (Automation TCC)
- Reads input from the keyboard (Input Monitoring or Accessibility)

then the new Mac will silently deny access until the user grants TCC. Surface a deep link from [tcc-deep-links.md](tcc-deep-links.md):

**Surface:**
```
TCC WARNING: ~/Library/LaunchAgents/com.user.mail-classifier.plist
  Program reads from ~/Library/Mail/ — requires Full Disk Access.
  After restore, grant FDA to:  /opt/homebrew/bin/python3
  Click: x-apple.systempreferences:com.apple.preference.security?Privacy_AllFiles
```

### 6. Missing `Label` or filename / Label mismatch

`Label` must match the filename minus `.plist`. If filename is `com.user.backup.plist`, Label must be `com.user.backup`. Mismatch = `launchctl bootstrap` fails with an unhelpful error.

**Surface:**
```
SCHEMA WARNING: ~/Library/LaunchAgents/com.user.backup.plist
  Filename: com.user.backup.plist
  Label:    com.user.daily-backup    <-- mismatch
  Fix:      Either rename the file to com.user.daily-backup.plist
            OR change the Label key inside to com.user.backup.
```

### 7. `StartCalendarInterval` with day-of-month + day-of-week both set

```xml
<key>StartCalendarInterval</key>
<dict>
    <key>Day</key>     <integer>1</integer>
    <key>Weekday</key> <integer>1</integer>
</dict>
```

launchd interprets this as "Day-of-month = 1 OR Weekday = Monday", not AND. Easy to miss; surface the actual schedule the user will get.

**Surface:**
```
SCHEDULE NOTE: ~/Library/LaunchAgents/com.user.weekly.plist
  Day=1 AND Weekday=1 — launchd interprets as OR, not AND.
  Actual schedule: runs on the 1st of every month OR every Monday.
  If you meant only-on-Monday-the-1st-of-the-month, this needs a wrapper script
  that checks the date and exits if both conditions aren't true.
```

### 8. `KeepAlive: true` on a job that exits successfully on first run

This is the throttle-loop pattern. `RunAtLoad: true` + `KeepAlive: true` + a program that exits-zero = launchd restarts immediately = throttled after a few iterations = job is now broken AND filling syslog.

**Surface:**
```
ANTI-PATTERN: ~/Library/LaunchAgents/com.user.one-shot.plist
  RunAtLoad: true + KeepAlive: true + program looks like a one-shot script.
  This will throttle within seconds and stop running.
  Fix: change KeepAlive to:
       <dict><key>SuccessfulExit</key><false/></dict>
       (restart only on crash, not on clean exit)
  Or remove KeepAlive entirely if the job should only run once per login.
```

---

## How the reasoner is invoked

This file is a reference, not a script. Claude reads it while reasoning about a captured plist and emits a structured explanation. Typical flow:

1. Capture writes plists to `~/migration-bundle/launchd/user-LaunchAgents/`, `system-LaunchAgents/`, `system-LaunchDaemons/`.
2. Restore (or diff, or inventory in `--explain` mode) iterates each plist.
3. For each, Claude parses the XML, names the dominant pattern, then runs the red-flag checklist.
4. Output a per-plist block in the audit log:

```
~/Library/LaunchAgents/com.user.dotfile-sync.plist
  Label:    com.user.dotfile-sync
  Pattern:  WATCH (WatchPaths → /Users/hunter/.local/share/chezmoi/)
  Program:  /opt/homebrew/bin/chezmoi apply
  Schedule: runs when chezmoi source dir is modified
  Status:   COMPATIBLE — user-scope, Brewfile-installed binary, no TCC required.

/Library/LaunchDaemons/com.user.backup.plist
  Label:    com.user.backup
  Pattern:  TIME (StartCalendarInterval → 03:00 daily)
  Program:  /usr/local/bin/backup.sh
  Status:   TAHOE WARNING — will not load on Tahoe.
            PORT WARNING — /usr/local/bin not present on Apple Silicon.
  See:      ~/.claude/skills/mac-migration/references/tahoe-sip-advisory.md
```

The user reads this, decides keep/rewrite/drop, and the skill records the decision in `manifest.json` for the restore pass.

---

## References

- [Apple — Creating launchd Daemons](https://developer.apple.com/library/archive/documentation/MacOSX/Conceptual/BPSystemStartup/Chapters/CreatingLaunchdJobs.html)
- [`launchd.plist(5)` manpage](https://www.manpagez.com/man/5/launchd.plist/)
- [LaunchControl](https://www.soma-zone.com/LaunchControl/) — commercial GUI editor for launchd plists; useful reference for the schema even if the user doesn't buy it
- [LaunchKit (open source)](https://github.com/zenangst/LaunchKit) — Swift wrapper around launchctl operations
- [Soma-Zone — launchd.info](https://launchd.info/) — community reference covering edge cases and undocumented keys
