---
name: capture
description: >
  Phase 2 of the mac-migration toolchain. Reads manifest.json from inventory and captures every opted-in lane
  to ~/migration-bundle/ as atomic per-lane scripts. Builds Brewfile + dotfile refs + language toolchain
  manifests + GUI configs + browser profiles + IDE configs + database dumps + launchd plists + GPG-encrypted
  credentials. Idempotent via .done markers (re-runs skip completed lanes unless --force). Supports --dry-run
  (manifest only, no bytes), --tarball (packages bundle into migration-bundle.tar.zst for transit), and per-file
  SHA256 integrity manifest. Routes Lane I through scripts/encrypt_creds.sh for GPG sealing. Use when the user
  has finished inventory and is ready to write bytes, or says "build the migration bundle", "capture my Mac",
  "snapshot to ~/migration-bundle", "back up my Mac for migration", "run capture phase".
metadata:
  compatibility: macos
---

# Capture

Phase 2 of the mac-migration flow. Read [manifest.json](../inventory/SKILL.md) from inventory, write `~/migration-bundle/` lane by lane. Each lane is an atomic script — re-runnable in isolation, idempotent via `.done` markers, cron-safe.

## Entry decision tree

```
USER: "Build the migration bundle" / "capture my Mac"

  -> Does ~/migration-bundle/manifest.json exist?
       NO  -> Route to inventory sub-skill first. Capture refuses to run without manifest.
       YES -> Proceed.

  -> Read manifest.json. Honor every opt_out flag.

  -> For each lane A through I:
       if opt_out: log skip, continue
       if .done/<lane> exists and not --force: log skip-already-done, continue
       else: invoke capture_lane_<x>_<name>.sh

  -> After all lanes done:
       invoke package_bundle.sh
         -> verify all opted-in lanes have .done markers
         -> compute manifest.sha256
         -> if --tarball: produce migration-bundle.tar.zst
         -> print final summary
```

## What this sub-skill produces

Bundle directory at `$BUNDLE` (default `~/migration-bundle/`) populated by one capture script per lane. Final layout:

```
~/migration-bundle/
  manifest.json                 (from inventory — read, never overwritten here)
  manifest.sha256               (written by package_bundle.sh)
  migration.log.jsonl           (appended to by every script via audit_log.sh)
  .done/                        (idempotency markers)
    lane-a-apps
    lane-b-shell
    lane-c-toolchains
    lane-d-gui-configs
    lane-e-browsers
    lane-f-ides
    lane-g-databases
    lane-h-services
    lane-i-creds
  Brewfile                      (Lane A)
  manifests/                    (all text/JSON exports across lanes)
  dotfiles-refs/                (Lane B - flat copies of rc files)
  home-bin/  home-local-bin/    (Lane B - personal scripts)
  defaults/                     (Lane D - per-domain plists)
  AppSupport/                   (Lane D - selective rsync, caches excluded)
  fonts/                        (Lane D)
  stickies/  mail/              (Lane D - Containers gotcha noted)
  browsers/                     (Lane E)
  ides/                         (Lane F)
  databases/                    (Lane G)
  docker/                       (Lane G - .docker/ ONLY; never Group Containers)
  launchd/                      (Lane H)
  credentials/                  (Lane I - GPG-sealed to credentials.tar.gz.gpg)
```

## Execution model — one script per lane

Each lane has a dedicated atomic script in `scripts/`. The scripts are:

| Script | Lane | Reads | Writes |
|--------|------|-------|--------|
| `capture_lane_a_apps.sh` | A | Homebrew, mas, system_profiler | Brewfile, manifests/{brew-services,mas,system-apps} |
| `capture_lane_b_shell.sh` | B | rc files, /etc/paths*, ~/bin, /etc/hosts, sudoers.d | dotfiles-refs/, home-bin/, manifests/etc-* |
| `capture_lane_c_toolchains.sh` | C | mise, pipx, npm, cargo, gem, go, composer | manifests/{tool-versions,pipx,npm,cargo,gem,go-bin,composer}.* |
| `capture_lane_d_gui_configs.sh` | D | defaults domains, AppSupport, Fonts, Stickies, Mail | defaults/, AppSupport/, fonts/, stickies/, mail/ |
| `capture_lane_e_browsers.sh` | E | Chrome/Firefox/Safari/Brave/Arc dirs | browsers/{chrome,firefox,safari,brave,arc}/ |
| `capture_lane_f_ides.sh` | F | VS Code/Cursor/Zed/JetBrains/Nvim/Emacs/terminals | ides/{vscode,cursor,zed,jetbrains,nvim,emacs,iterm2,warp}/ |
| `capture_lane_g_databases.sh` | G | pg, mysql, redis, mongo, docker, k8s, helm | databases/, docker/, manifests/{kubeconfig,krew,helm} |
| `capture_lane_h_services.sh` | H | LaunchAgents, LaunchDaemons, brew services, PM2, cron, login items | launchd/, manifests/{pm2,crontab,login-items} |
| `capture_lane_i_creds.sh` | I | SSH, GPG, AWS, GCP, Azure, CF, DO, git, CLI tokens, WG | credentials/ then GPG-sealed |

Each script:

- Starts with `#!/usr/bin/env bash` and `set -euo pipefail`
- Honors `BUNDLE=~/migration-bundle` env override
- Reads `$BUNDLE/manifest.json` and respects opt_outs for that lane (skip silently with audit log entry)
- Checks `$BUNDLE/.done/lane-<x>-<name>`; if present and `--force` absent, exits early
- Writes its outputs to `$BUNDLE/<subdir>/`
- Calls `audit_log.sh` for granular action logging
- Writes `.done/lane-<x>-<name>` on successful completion
- On any failure, exits non-zero WITHOUT writing the done marker (so re-run picks up)

See [references/lane-capture.md](references/lane-capture.md) for per-lane command detail and gotchas. See [../references/inventory-lanes.md](../references/inventory-lanes.md) for canonical lane spec.

## Idempotency — `.done` markers

After a lane completes successfully, its script writes `$BUNDLE/.done/lane-<x>-<name>` (zero-byte marker). Re-runs check this file first.

- `--force` flag: ignore `.done` markers and re-capture everything from scratch
- `--lane <X>` flag: only run the specified lane (e.g. `--lane g` runs G only)
- Default (no flags): skip any lane with a `.done` marker, run the rest

The done-marker pattern delegates to `../scripts/lane_done_marker.sh` for read/write/check operations.

## Dry-run mode

`capture --dry-run` produces a manifest of what WOULD be captured without copying any bytes.

Behavior per lane script when `DRY_RUN=1`:

- Probe every source (Brewfile dump, defaults domains, etc.) and count items / measure sizes
- Write a per-lane summary JSON to `$BUNDLE/dry-run-report/lane-<x>.json`: `{ "lane": "a", "items": 124, "estimated_size_mb": 47, "would_skip": [...], "would_capture": [...] }`
- NEVER write the `.done` marker (so a real capture still runs from scratch)
- Print a one-line per-lane summary to stdout

## Tarball mode

`capture --tarball` invokes `package_bundle.sh` with the tarball flag at the end. It:

1. Verifies every opted-in lane has `.done/<lane>` written
2. Computes SHA256 across every file → `manifest.sha256`
3. Wraps `~/migration-bundle/` into `migration-bundle.tar.zst` using zstd compression
4. Prints final size + transfer recommendation

Default (no `--tarball`): leaves bundle as directory, no tar. Useful when transfer is via rsync, USB, AirDrop without compression, or staging for another step.

## Integrity — `manifest.sha256`

`package_bundle.sh` walks every file under `$BUNDLE/` (excluding the manifest itself) and writes `manifest.sha256` in standard `sha256sum`-compatible format:

```
<hex-hash>  ./Brewfile
<hex-hash>  ./manifests/mas-installed.txt
<hex-hash>  ./credentials/credentials.tar.gz.gpg
...
```

Restore validates against this manifest before unpacking — catches USB / AirDrop / iCloud corruption before it cascades into half-rehydrated state on the new Mac.

## Lane I — GPG encryption flow

Lane I (credentials) is the only lane with mandatory encryption. After all credential paths copy into `$BUNDLE/credentials/`, the script invokes `../scripts/encrypt_creds.sh seal`:

1. Tar+gzip `$BUNDLE/credentials/` → `credentials.tar.gz`
2. GPG encrypt with the user's primary key → `credentials.tar.gz.gpg`
3. Shred the unencrypted `credentials.tar.gz` and the source `credentials/` subdir
4. Only the `.gpg` file lives in the bundle

On restore, `encrypt_creds.sh unseal` reverses the flow on the new Mac after the user imports their GPG key. Full mechanics in [../references/encryption-flow.md](../references/encryption-flow.md).

## Lane scripts at a glance

The lane scripts handle:

- **A** — Brewfile dump + brew services running snapshot + mas list + system_profiler orphan inventory
- **B** — Flat copy of zsh/bash rc files to `dotfiles-refs/`, system PATH files via sudo, `~/bin` + `~/.local/bin`, `/etc/hosts` + `/etc/sudoers.d`. Designed for users not yet on chezmoi; their dotfiles get caught here as a safety net
- **C** — Conditional captures (only if the tool exists): mise tool versions, pipx JSON, npm globals JSON, cargo install list, gem list, go bin contents, composer global JSON
- **D** — `defaults domains` loop → per-domain plist export, then rsync of AppSupport excluding caches, fonts, Stickies (Containers ACL gotcha flagged in audit log), Mail
- **E** — Chrome/Cursor/Brave/Edge: extension lists only (account sync handles the rest); Firefox: full `Profiles/` copy with running-warning; Safari: Bookmarks.plist before-first-launch
- **F** — VS Code, Cursor, Zed extension lists + settings/keybindings/snippets; JetBrains rsync; Nvim/Emacs config dirs; iTerm2 plist; Warp data dir (cache-excluded)
- **G** — Postgres `pg_dumpall`, MySQL `mysqldump`, Redis `dump.rdb`, Mongo `mongodump`, Docker `~/.docker/` only (NEVER Group Containers), `~/.kube/config`, krew list, helm repo list
- **H** — User + system LaunchAgents + LaunchDaemons, `launchctl list`, brew services list, PM2 dump, user + root crontab, login items via AppleScript, optional Launchpad layout via `lporg`
- **I** — SSH keys, GPG export, all cloud CLI configs, all language-package-manager auth, WireGuard, all collated then GPG-sealed

## Helper scripts — shared across lanes

This sub-skill ships one helper script of its own:

- `scripts/audit_log.sh` — append a JSONL line to `$BUNDLE/migration.log.jsonl`. Every lane script invokes this for fine-grained action logging.

It calls into the parent's shared scripts at `../scripts/`:

- `../scripts/lane_done_marker.sh` — read/write/check the `.done/<lane>` files
- `../scripts/encrypt_creds.sh` — GPG seal Lane I credentials
- `../scripts/detect_macos_version.sh` — used by package_bundle for surfacing Tahoe advisory

## Per-app playbook references

Several lanes have non-obvious gotchas that delegate to per-app playbooks:

- Lane G1 (Postgres) — `../references/per-app/postgres.md` covers same-major vs cross-major upgrades and extension reinstall
- Lane G5 (Docker) — `../references/per-app/docker.md` enforces the "never copy Group Containers" rule
- Lane D (1Password) — `../references/per-app/one-password.md` — don't capture, account sign-in only
- Lane D (Photos / Music / Messages / Mail) — separate playbooks for each

The lane scripts cite these files in their audit-log output so the user can trace why a particular path was skipped.

## Final command shape — what the user runs

```bash
# Standard capture, all lanes per manifest.json
bash scripts/capture_lane_a_apps.sh
bash scripts/capture_lane_b_shell.sh
bash scripts/capture_lane_c_toolchains.sh
bash scripts/capture_lane_d_gui_configs.sh
bash scripts/capture_lane_e_browsers.sh
bash scripts/capture_lane_f_ides.sh
bash scripts/capture_lane_g_databases.sh
bash scripts/capture_lane_h_services.sh
bash scripts/capture_lane_i_creds.sh
bash scripts/package_bundle.sh --tarball

# Or single-lane:
bash scripts/capture_lane_g_databases.sh --force

# Or dry-run:
DRY_RUN=1 bash scripts/capture_lane_d_gui_configs.sh
```

Most users invoke through Claude — Claude reads `manifest.json`, iterates lanes, and runs the scripts in order, surfacing progress and gotchas.

## Resume-from-failure

If lane G fails partway (e.g. Postgres dump hits a permission issue):

1. The script exits non-zero and does NOT write `.done/lane-g-databases`
2. The audit log records the failure with the specific step that broke
3. User fixes the underlying issue (e.g. `brew services start postgresql@17`)
4. Re-run `bash scripts/capture_lane_g_databases.sh` — it sees no `.done` marker, restarts from scratch
5. All earlier completed lanes (A through F) are skipped automatically

No state corruption. The done-marker discipline + the unified `BUNDLE` env override make every script idempotent and safely re-runnable.

## Reference index

- [references/lane-capture.md](references/lane-capture.md) — per-lane command detail and gotchas
- [../references/inventory-lanes.md](../references/inventory-lanes.md) — canonical 10-lane spec
- [../references/encryption-flow.md](../references/encryption-flow.md) — GPG seal/unseal mechanics for Lane I
- [../references/per-app/](../references/per-app/) — 7 sensitive-app playbooks (Postgres, Docker, 1Password, Photos, Music, Messages, Mail)
