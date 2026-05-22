---
name: diff
description: >
  Phase 4 of mac-migration — verifies a restored Mac against the captured bundle and smoke-tests each lane. Reads
  manifest.json from the migration bundle, walks current-Mac state, computes per-lane deltas (missing / extra /
  version mismatch), then runs the per-lane smoke tests defined in references/per-lane-smoke-tests.md. Emits
  DIFF-REPORT.md + SMOKE-TEST-RESULTS.json into the bundle. Also supports drift-detection mode against a baseline
  snapshot at ~/.mac-migration/baseline.json. After a clean pass on the new Mac, surfaces the cleanup-old-Mac
  advisory (deactivate licenses, sign out of iCloud, secure-erase guidance). Triggers on "did it all transfer",
  "verify the migration", "diff the migration", "what's missing", "smoke test the new Mac", "mac drift check",
  "compare to baseline", "verify my Mac restore", "what changed since baseline".
metadata:
  compatibility: macos
---

# Diff — Phase 4: Verify + Smoke Test

You are running diff on the **new Mac**, after restore has finished (or on the **current Mac** in drift-detection mode). Goal: prove the restore worked, surface anything missing, give the user a one-page report.

## When to load this body

Route here when the user is post-restore and asks any of:
- "Did it all transfer?"
- "Verify the migration."
- "What's missing on the new Mac?"
- "Smoke test it."
- "How does my current Mac compare to the baseline I saved last month?" (drift mode)

If the user has not yet run restore, send them to [restore](../restore/SKILL.md) first.

## Two modes

| Mode | Trigger | Inputs | Outputs |
|------|---------|--------|---------|
| **Migration verify** (default) | "verify the migration", "did it all transfer", "diff the new Mac" | `~/migration-bundle/manifest.json` (the old Mac's captured state) + current Mac state | `~/migration-bundle/DIFF-REPORT.md` + `SMOKE-TEST-RESULTS.json` + cleanup-old-Mac advisory at end |
| **Drift detection** | "drift check", "what changed since baseline", "compare to baseline" | `~/.mac-migration/baseline.json` (snapshot of any prior point in time on this Mac) + current Mac state | `~/.mac-migration/drift-report-YYYY-MM-DD.md` |

The two modes share the same diff engine and the same smoke tests — only the reference point differs.

## The manifest-diff model

A manifest is a JSON document the inventory + capture phases produce. It records what was on the old Mac (or what was on this Mac at baseline time), broken down by lane:

```json
{
  "captured_at": "2026-05-22T14:32:11Z",
  "macos_version": {"major": 14, "codename": "Sonoma", "raw": "14.6.1"},
  "lanes": {
    "A": {
      "captured": true,
      "brewfile_formulae": ["git", "jq", "ripgrep"],
      "brewfile_casks": ["docker", "rectangle"],
      "mas_apps": [{"id": 497799835, "name": "Xcode"}],
      "orphan_apps": ["Some.app"]
    },
    "B": { "captured": true, "dotfile_dirs": [], "paths_d_entries": [], "home_bin_count": 12 },
    "C": { "captured": true, "tool_versions": {"node": "22", "python": "3.13"}, "pipx_envs": [] }
  },
  "opt_outs": ["lane-d-stickies", "lane-j-tcc-manual"]
}
```

Diff walks the **same scan logic** against the current Mac, producing a fresh in-memory state object, then compares lane-by-lane.

Three delta types per lane:
- **Missing** — was on the old Mac, not on the new Mac (the failure mode users care about)
- **Extra** — on the new Mac, not on the old Mac (usually fine — fresh installs, new tools)
- **Mismatch** — present on both but at a different version (often fine if mise pinned a different patch level; sometimes a problem if a major version drifted)

## Per-lane smoke tests

Beyond raw delta counts, each lane has 1-3 **smoke tests** that prove the lane actually works on the new Mac, not just that the files exist. See [references/per-lane-smoke-tests.md](references/per-lane-smoke-tests.md) for the full catalog.

Examples:
- Lane A — `brew list --formula | wc -l` matches old count (within tolerance)
- Lane C — `node --version` matches `.tool-versions`
- Lane G — `pg_isready -U postgres` returns 0 (the daemon is alive)
- Lane H — `launchctl list | grep <key-job>` returns the expected lines

A smoke test returns:
- Exit 0 → pass
- Non-zero → fail, with a one-line diagnostic on stderr

## Workflow

### Step 1 — Locate the manifest

```bash
BUNDLE="${BUNDLE:-$HOME/migration-bundle}"
test -f "$BUNDLE/manifest.json" || { echo "No manifest at $BUNDLE/manifest.json — was capture run?"; exit 2; }
```

For drift mode: `BASELINE="${BASELINE:-$HOME/.mac-migration/baseline.json}"`.

### Step 2 — Run the diff

```bash
./scripts/diff_state.sh                   # migration verify mode (default)
./scripts/diff_state.sh --baseline        # drift detection vs ~/.mac-migration/baseline.json
./scripts/diff_state.sh --write-baseline  # snapshot CURRENT state to baseline (one-time setup)
```

Outputs:
- `~/migration-bundle/DIFF-REPORT.md` (verify mode)
- `~/.mac-migration/drift-report-YYYY-MM-DD.md` (drift mode)

### Step 3 — Run the smoke tests

```bash
./scripts/smoke_test_all.sh
```

Reads every lane in the manifest that has `captured: true`, invokes `../scripts/smoke_test_lane.sh <lane>` for each, aggregates results to `$BUNDLE/SMOKE-TEST-RESULTS.json`.

### Step 4 — Surface the report

Display `DIFF-REPORT.md` to the user. If all lanes pass and all smoke tests pass, append the **cleanup-old-Mac advisory**:

```
================================================================
ALL LANES VERIFIED. New Mac is ready.

Before wiping the old Mac:
  1. Deactivate offline machine licenses (Backblaze, Adobe, JetBrains, Setapp, Plex, 1Password)
  2. Sign out of iCloud (System Settings > [Your Name] > Sign Out)
  3. Sign out of App Store (App Store > Account > Sign Out)
  4. Sign out of Messages + FaceTime (per-app Preferences > Sign Out)
  5. Disable Find My Mac (System Settings > [Your Name] > iCloud > Find My Mac)
  6. Deauthorize the computer in Music app (Account > Authorizations > Deauthorize)
  7. Reset NVRAM + secure-erase:
       - Apple Silicon: Apple > Shut Down > hold power > Options > Disk Utility > erase Macintosh HD
       - Intel: Cmd+Option+P+R at boot for NVRAM, then Disk Utility from Recovery
  8. Reinstall macOS from Recovery (sells / hands off cleanly)
================================================================
```

If any lane FAILED or any smoke test FAILED:

```
================================================================
DIFF FOUND ISSUES. Do NOT wipe the old Mac yet.

Failures (see DIFF-REPORT.md for details):
  Lane <X>: <one-line summary>
  Smoke test <Y>: <one-line diagnostic>

Remediation:
  <per-lane suggestions printed by diff_state.sh>
================================================================
```

## Drift detection (advanced)

Same engine, different reference point. Use it to track your current Mac for slow erosion of state — packages installed and forgotten, dotfile drift, launchd jobs registered for a one-time experiment that never got cleaned up.

```bash
# One-time: snapshot current state
./scripts/diff_state.sh --write-baseline
# Stored at ~/.mac-migration/baseline.json with ISO timestamp

# Later (weeks / months): compare current state to that baseline
./scripts/diff_state.sh --baseline
# Outputs ~/.mac-migration/drift-report-YYYY-MM-DD.md
```

The drift report highlights:
- New brew formulae since baseline (intentional? cruft?)
- LaunchAgents added / removed
- mise tool-versions changes
- New dirs in `~/Library/Application Support` (which app added them?)
- Orphan apps that have appeared in /Applications

Same skill, same scripts. Just a different `--baseline` flag.

## How smoke tests differ from delta diff

Delta diff answers: "Are the files / packages / configs present?"
Smoke tests answer: "Do they actually work?"

A package can be installed (Brewfile says `git` is there, current `brew list` confirms it) but the binary won't execute because of a quarantine attribute, broken symlink, or PATH issue. Smoke tests catch this.

Both signals matter. DIFF-REPORT.md surfaces both side-by-side per lane.

## Manifest expectations

This sub-skill assumes capture has already produced a `manifest.json` matching the schema documented above. If capture changes the schema, update `scripts/diff_state.sh`'s parsing in the same change set.

If the manifest is missing or unreadable, diff exits non-zero with a clear message. Do not silently proceed against a partial state — the user needs to know.

## Resources

### scripts/
- [scripts/diff_state.sh](scripts/diff_state.sh) — main diff engine. Compares manifest to current state, emits DIFF-REPORT.md. Supports `--baseline` and `--write-baseline`.
- [scripts/smoke_test_all.sh](scripts/smoke_test_all.sh) — aggregator. Loops every captured lane and invokes the parent-level `smoke_test_lane.sh`. Writes SMOKE-TEST-RESULTS.json.

### references/
- [references/per-lane-smoke-tests.md](references/per-lane-smoke-tests.md) — the canonical catalog of per-lane smoke-test commands. Each lane has 1-3 commands that prove it works.

## Exit codes

| Code | Meaning |
|------|---------|
| 0 | All lanes verified, all smoke tests passed |
| 1 | One or more lanes have missing items OR one or more smoke tests failed |
| 2 | Manifest not found or unparseable (no diff possible) |
| 3 | Invalid invocation (bad flag, missing required arg) |

Callers (the parent skill, restore's post-step hook, cron drift jobs) can branch on these.

## Parent linkage

This is Phase 4 of [mac-migration](../SKILL.md). Phases 1-3 are [inventory](../inventory/SKILL.md), [capture](../capture/SKILL.md), [restore](../restore/SKILL.md). Shared scripts (`detect_macos_version.sh`, `lane_done_marker.sh`, `encrypt_creds.sh`, `smoke_test_lane.sh`, `tcc_deep_link.sh`) live at `../scripts/` and are invoked by every sub-skill — including this one for the actual smoke-test execution.
