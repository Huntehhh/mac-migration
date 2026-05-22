---
name: inventory
description: >
  Phase 1 of the Mac migration toolchain. Scans the current Mac across all 10 lanes (apps, shell,
  toolchains, GUI configs, browsers, IDEs, databases, services, credentials, manual items), runs
  pre-flight validation (disk space, brew doctor, MAS sign-in, mise, chezmoi, Full Disk Access,
  GPG key), surfaces a choose-your-own-adventure summary of what would be migrated, and accepts
  opt-outs. Writes the user's decisions to manifest.json so capture + restore honor them downstream.
  Also handles drift detection via --diff-baseline against a saved snapshot. Use when the user
  says "I'm about to migrate", "what's on my Mac", "audit my setup", "show me what would be
  captured", "drift check", "snapshot my Mac state", or starts the migration flow cold without a
  bundle yet. Reads but never writes anything outside ~/migration-bundle/ and ~/.mac-migration/.
metadata:
  compatibility: macos
---

# Inventory (Phase 1)

Scan the old Mac, validate pre-flight conditions, summarize what would be migrated, ask the user what to skip, write the opt-outs to `manifest.json`. No bytes get copied in Phase 1 — this is read-only discovery plus the conversation that calibrates Phase 2.

## When to use

Route here when the user is starting the migration flow cold. Triggers: "I'm about to migrate", "what's on my Mac", "show me what would be captured", "audit my setup", "drift check", "snapshot my Mac state", "what's changed since my baseline". If the user has already finished inventory and is ready to write bytes, route to `capture` instead.

## The choose-your-own-adventure UX

Phase 1 always opens with a scan, then a summary, then a single question: *"Anything you do NOT want me to handle?"* The user replies in plain English. Their opt-outs translate to lane/sub-module flags in `manifest.json`. Capture and restore both honor those flags. The flow:

```
1. Pre-flight gate.   scripts/preflight_check.sh
                      Blockers (disk space, brew doctor red, no GPG key, etc.)
                      surface before any scan runs. If anything fails, stop and
                      ask the user to fix or override.

2. Scan all lanes.    scripts/scan_inventory.sh
                      Writes ~/migration-bundle/manifest.json with per-lane
                      counts, sizes, highlights. Idempotent — merges with
                      existing manifest if one exists, preserving prior opt-outs.

3. Summary + ask.     Print the lane-by-lane summary (see references/scan-protocol.md
                      for the template). Ask the user what to skip.

4. Record opt-outs.   Parse the user's reply. Write lane / sub-module flags to
                      manifest.json under "opt_outs". Echo back the recorded
                      flags. Confirm before proceeding to Phase 2.

5. Brewfile hygiene.  scripts/brewfile_prune_suggest.sh + scripts/orphan_to_brewfile.sh
                      Optional second pass — surface unused formulae/casks
                      (suggest prune) and orphan apps in /Applications that
                      could be added to Brewfile. User reviews; skill never
                      auto-edits the Brewfile.
```

The user does NOT have to opt out of anything. The default is *capture everything*. The skill's job is to make sure the user knows what *everything* is.

## Pre-flight gate

Before any scan runs, [scripts/preflight_check.sh](scripts/preflight_check.sh) probes for blockers:

| Check | Why it matters | Failure mode |
|-------|----------------|--------------|
| Disk space `>=20GB` free | Bundle for a power user typically runs 5-15GB; need headroom | Hard fail |
| `brew doctor` clean | Warnings here surface restore-time breakage | Soft warn (show summary, continue) |
| `mas account` signed in | Lane A2 needs an Apple ID logged in to list/export MAS apps | Hard fail |
| `mise` installed | Lane C1 spec assumes mise is the version manager. If absent, suggest install before continuing | Hard fail |
| `chezmoi` repo pushed | If local commits exist that aren't on origin, the dotfile state on the new Mac will lag. Warn the user. | Soft warn |
| Full Disk Access on `/bin/bash` | Lane D needs to read `~/Library/Mail/`, `~/Library/Containers/`, TCC.db. Without FDA, half the scan returns empty. | Hard fail with deep link |
| GPG key present | Lane I encryption needs at least one secret key. `gpg --list-secret-keys` returns empty -> blocker | Hard fail |

Hard fails refuse to run the scan. Soft warns surface but continue. Output: human-readable PASS/FAIL list to stdout, structured JSON to stderr so the calling sub-skill can parse programmatically.

## Scan protocol

[scripts/scan_inventory.sh](scripts/scan_inventory.sh) walks lanes A through J in order. For each lane, it runs the discovery commands documented in [references/scan-protocol.md](references/scan-protocol.md), emits a JSON object with item counts + total size + notable highlights, and appends a one-line audit entry to `~/migration-bundle/migration.log.jsonl`.

Key behaviors:

- **Idempotent.** Re-runs replace the per-lane scan blocks but PRESERVE `opt_outs` from the previous run. The user never loses opt-out decisions because a scan re-ran.
- **Read-only.** Scan never modifies the source Mac. Worst case it writes to `~/migration-bundle/manifest.json` and `~/migration-bundle/migration.log.jsonl`.
- **Lane J manual.** Lanes A-I run automated discovery. Lane J writes a pre-formatted checklist into manifest (iCloud Keychain, TCC, Time Machine, app licenses) for the user to walk manually after restore.
- **Highlights, not contents.** The scan doesn't read file contents. It counts, sizes, lists names. Browser history, document text, image bytes never leave the source machine during inventory.

See [references/scan-protocol.md](references/scan-protocol.md) for the per-lane commands and the JSON schema.

## Brewfile hygiene passes

Two optional passes run after the main scan:

**Prune suggestions** ([scripts/brewfile_prune_suggest.sh](scripts/brewfile_prune_suggest.sh)) — dumps the current Brewfile, walks each formula/cask, checks `brew uses --installed <name>`. If nothing depends on a formula AND it's not directly invoked anywhere reachable, surface it as a prune candidate. Print the list. Never auto-edit. User reviews and decides.

**Orphan-to-Brewfile** ([scripts/orphan_to_brewfile.sh](scripts/orphan_to_brewfile.sh)) — reads `~/migration-bundle/manifests/system-apps.json` (output of `system_profiler SPApplicationsDataType -json`). For each `.app` in `/Applications` not covered by Brewfile or `mas list`, runs `brew search --cask <name>` and `mas search <name>`. Surfaces candidate one-liners the user can append to Brewfile. The user pastes; the skill never edits Brewfile directly during Phase 1.

Both passes are optional. The user can skip the hygiene passes and go straight from scan to opt-out to Phase 2 if they want.

## How opt-outs propagate

The user's natural-language reply ("skip Launchpad, skip Stickies, skip Notes, I'll redo TCC manually") gets translated into structured flags:

```json
{
  "opt_outs": {
    "lane_h": ["H7.launchpad"],
    "lane_d": ["D5.stickies", "D5.notes_local"],
    "lane_j": ["J3.tcc_manual"]
  }
}
```

The structured form goes into `~/migration-bundle/manifest.json`. Capture and restore both read this file at startup. If a lane or sub-module is opted out, those phases skip it. The user can re-edit the JSON by hand if they change their mind — the file is documented in [references/scan-protocol.md](references/scan-protocol.md).

## Drift-baseline mode

`scripts/scan_inventory.sh --diff-baseline` compares the current Mac state against a previously saved snapshot at `~/.mac-migration/baseline.json`. Use when the user wants to know what's changed on their current Mac without migrating yet.

```bash
# First time — save the baseline
scripts/scan_inventory.sh --save-baseline

# Later — see what changed
scripts/scan_inventory.sh --diff-baseline
```

The diff output highlights:
- **Added** — new brew formulae/casks, new LaunchAgents, new MAS apps, new fonts, new pipx envs
- **Removed** — packages uninstalled since baseline
- **Changed** — mise `.tool-versions` deltas, brew formula version bumps, new dotfile paths
- **Unchanged** — silenced unless `--verbose`

This is also how the `diff` sub-skill (Phase 4) compares old-Mac and new-Mac states post-restore. Same script, different inputs.

## Output artifacts

After a successful Phase 1 run, expect to see:

```
~/migration-bundle/
  manifest.json                    Per-lane scan + opt-outs + bundle metadata
  migration.log.jsonl              Audit log (append-only)
  manifests/
    system-apps.json               Lane A3 raw output
    mas-installed.txt              Lane A2 raw output
    brew-leaves.txt                Lane A1 helper (brew leaves)
    .tool-versions                 Lane C1 snapshot
    pipx.json                      Lane C2 snapshot
    npm-globals.json               Lane C3 snapshot
    cargo-installs.txt             Lane C4 snapshot
    brew-services-running.txt      Lane H3 snapshot
    user-crontab.txt               Lane H5 snapshot
```

No app bundles, dotfile contents, or credential bytes are copied in Phase 1. Those happen in `capture`.

## Failure modes + recovery

| Failure | Likely cause | Fix |
|---------|--------------|-----|
| `preflight_check.sh` blocks on FDA | `/bin/bash` doesn't have Full Disk Access | Open System Settings > Privacy & Security > Full Disk Access, add Terminal (and the script's interpreter if different), reboot the terminal session, re-run |
| `preflight_check.sh` blocks on GPG | No secret key exists | `gpg --full-generate-key`, store the passphrase in a password manager, then re-run |
| `scan_inventory.sh` empty Lane D | FDA blocker passed but the user is running through SSH | TCC is per-process — FDA on Terminal does not transfer to sshd. Run interactively from the GUI Terminal |
| Manifest schema mismatch on re-run | Old manifest.json from a prior skill version | Move `manifest.json` aside; re-run scan; manually re-enter opt-outs |
| Lane A3 zero orphans on a clearly-orphan-heavy Mac | `system_profiler` ran but `mas list` failed silently | Re-run `mas account` to confirm sign-in; orphan calc subtracts mas list and Brewfile from system-apps |

## Cross-cutting features honored

This sub-skill participates in the parent's cross-cutting features:

- **Audit log**: every action (preflight check pass/fail, lane scan, opt-out record) appends to `~/migration-bundle/migration.log.jsonl`
- **Resume-safe**: re-running `scan_inventory.sh` preserves opt-outs and merges new lane data
- **No encrypted creds yet**: encryption happens in `capture` (Lane I). Inventory only counts credentials — it doesn't open or read them
- **Shared scripts**: uses `../scripts/lane_done_marker.sh` and `../scripts/detect_macos_version.sh` — do NOT duplicate at this level

## Reference

- [references/scan-protocol.md](references/scan-protocol.md) — per-lane scan commands + manifest schema + summary template + drift-baseline workflow
- [../references/inventory-lanes.md](../references/inventory-lanes.md) — the canonical 10-lane spec (parent-level)
- [../references/tcc-deep-links.md](../references/tcc-deep-links.md) — System Settings URL schemes used by the FDA blocker error message
