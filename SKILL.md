---
name: mac-migration
description: >
  Mac-to-Mac migration toolchain — inventory, capture, restore, verify everything power users carry between Macs.
  Composable parent with 4 sub-skills: inventory (Phase 1 scan + choose-your-own-adventure opt-in/opt-out menu),
  capture (Phase 2 build ~/migration-bundle with apps, dotfiles, language toolchains, GUI configs, browsers, IDEs,
  databases, services, GPG-encrypted credentials), restore (Phase 3 consume bundle on new Mac with idempotent .done
  markers, Tahoe SIP detection, TCC deep links), diff (Phase 4 post-restore verification + smoke tests). 10 lanes
  A-J covering 40+ sub-modules. Per-app playbooks for Postgres, Docker, 1Password, Photos, Music, Messages, Mail.
  Also supports drift detection on current Mac. Triggers on "migrate my Mac", "new Mac setup", "Mac to Mac
  migration", "moving to new Mac", "rebuild Mac from scratch", "Mac drift detection", "Mac migration toolchain",
  "restore from migration bundle", "back up Mac for migration", "audit my Mac state".
metadata:
  compatibility: macos
---

# Mac Migration

Composable parent for migrating a power user's entire Mac environment to a new machine. Skip Apple's Migration Assistant — it breaks Homebrew, Docker, launchd, and inherits Rosetta state. Use this skill instead: read the old Mac, build an encrypted bundle, restore to a fresh install, verify the result.

## Phase flow

```
   OLD MAC                                          NEW MAC
   ---------                                        ---------
   [1] inventory  --+                          +--  [3] restore
       Scan + ask    |       transit            |       Consume bundle
       what to keep  v                          v       lane-by-lane
   [2] capture    --> migration-bundle.tar.zst -->  [4] diff
       Build bundle  (encrypted Lane I creds)        Verify + smoke test
```

Each phase is an atomic sub-skill. Each lane within a phase is an atomic script. The user can re-run any single lane via cron without Claude in the loop.

## Routing — match user intent to a sub-skill

Load only the matching sub-skill body. The parent does not duplicate sub-skill content.

| Sub-skill | When to route here |
|-----------|--------------------|
| **[inventory](inventory/SKILL.md)** | User says "I'm about to migrate", "what's on my Mac", "show me what would be captured", "audit my setup", "drift check". Phase 1 — scan, summarize, ask opt-in/opt-out. |
| **[capture](capture/SKILL.md)** | User says "build the migration bundle", "capture my Mac", "snapshot to ~/migration-bundle", or has already finished inventory and is ready to write bytes. Phase 2 — produce the bundle. |
| **[restore](restore/SKILL.md)** | User says "I'm on the new Mac", "restore from the bundle", "rehydrate this machine", or is running on the target. Phase 3 — consume the bundle. |
| **[diff](diff/SKILL.md)** | User says "did it all transfer", "verify the migration", "what's missing", "drift since last baseline". Phase 4 — compare manifests + smoke test each lane. |

**Default entry point** when the user starts cold ("I'm migrating Macs"): route to **inventory** first, then walk forward. The inventory sub-skill is the choose-your-own-adventure menu.

## Choose-your-own-adventure UX (Phase 1)

The inventory sub-skill opens like this. Always.

```
USER:    "I'm about to move everything to a new Mac."

SKILL:   [Phase 1 — quick scan, ~60s]
         Found:
           Lane A.  87 brew formulae + 24 casks + 6 App Store apps + 3 orphan apps
           Lane B.  5 dotfile dirs + 3 PATH entries in /etc/paths.d + 12 scripts in ~/bin
           Lane C.  mise (.tool-versions: node 22, python 3.13, ruby 3.4, go 1.24)
                   pipx (14 envs), npm globals (8), cargo (6), gem (4), go bin (3)
           Lane D.  234 defaults domains, 89 dirs in Application Support, 47 Containers
                   219 user fonts
           Lane E.  Chrome (signed in), Safari (iCloud), Firefox (profile), Arc
           Lane F.  VS Code (47 extensions), Cursor, Zed, iTerm2, Warp
           Lane G.  Postgres 16 (4 DBs, 3.2 GB), Redis (12 MB), Docker (47 contexts)
           Lane H.  8 user LaunchAgents, 2 brew services running, 0 cron, 3 PM2 services,
                   12 Login Items
           Lane I.  AWS (2 profiles), GCP (1 acct), git config, 6 CLI tokens

         All of the above will be migrated. Anything you do NOT want me to handle?

USER:    "Skip Launchpad layout, skip Stickies, skip Notes - I'll redo TCC manually."

SKILL:   Logged opt-outs. Proceed to capture? [y/N]
```

The user's opt-outs translate to lane / sub-module flags written to `~/migration-bundle/manifest.json` so capture and restore both honor them.

## The 10 lanes — full spec

See [references/inventory-lanes.md](references/inventory-lanes.md) for every path, capture command, restore command, gotcha, and per-lane open-source tool. Summary:

| Lane | Theme | Examples |
|------|-------|----------|
| **A** | Applications | Brewfile (formulae + casks), Mac App Store via mas, orphan apps |
| **B** | Shell + PATH + custom scripts | dotfiles via chezmoi, `/etc/paths.d`, `~/bin`, `/etc/hosts`, sudoers.d |
| **C** | Language toolchains + globals | mise, pipx, npm, cargo (via cargo-binstall), gem, go, composer |
| **D** | GUI app configs | defaults plists, ~/Library/Application Support, Containers, fonts, Stickies, Notes, Mail |
| **E** | Browsers | Chrome, Brave, Firefox, Safari, Arc, Edge |
| **F** | IDEs + Terminals | VS Code/Cursor, Zed, JetBrains, Nvim, Emacs, iTerm2, Warp, Ghostty, Alacritty, Kitty |
| **G** | Databases + containers | Postgres, MySQL, Redis, Mongo, Docker, Kubernetes, krew, Helm |
| **H** | Background services | LaunchAgents, LaunchDaemons, brew services, PM2, cron, Login Items, Launchpad |
| **I** | Credentials + auth | git/gh, AWS/GCP/Azure/CF/DO, CLI tokens, SSH, GPG, WireGuard |
| **J** | Manual / deferred | iCloud Keychain, app licenses, TCC permissions, Time Machine, Spotlight |

Lanes A-I are auto-handled. Lane J surfaces a checklist for the user to walk after restore — these cannot migrate programmatically.

## Cross-cutting features (in v1)

These behaviors apply across capture + restore + diff. Inheritable defaults; each sub-skill picks them up.

| Feature | Where implemented | Behavior |
|---------|-------------------|----------|
| **Pre-flight validation** | inventory | Before capture starts: check disk space, brew doctor, MAS signed in, mise present, chezmoi pushed, Full Disk Access on `/bin/bash`. Refuse to start if blockers exist. |
| **Encrypted credentials (Lane I)** | capture + restore | `scripts/encrypt_creds.sh` GPG-seals `migration-bundle/credentials/` using the user's GPG key. restore decrypts. See [references/encryption-flow.md](references/encryption-flow.md). |
| **Idempotent + resume-from-failure** | capture + restore | Each lane writes `migration-bundle/.done/<lane>` on success. Re-runs skip completed lanes unless `--force`. Helper: `scripts/lane_done_marker.sh`. |
| **Dry-run mode** | capture | `capture --dry-run` produces a manifest of what WOULD be captured (sizes, file counts, per-lane summary) without copying bytes. |
| **Bundle integrity SHA256** | capture + restore | capture writes `manifest.sha256` with hashes of every file. restore verifies before unpacking. Catches USB/AirDrop/iCloud corruption. |
| **Audit log (JSONL)** | capture + restore | Every action appended to `migration.log.jsonl` (lane, action, target, return code, timestamp). |
| **Target-Mac OS detection** | restore | `scripts/detect_macos_version.sh` returns Sequoia / Tahoe / etc. Tahoe triggers SMAppService advisory. See [references/tahoe-sip-advisory.md](references/tahoe-sip-advisory.md). |
| **TCC deep links** | restore + diff | `scripts/tcc_deep_link.sh` opens `x-apple.systempreferences:` URLs directly to FDA / Accessibility / Camera / Mic panels. See [references/tcc-deep-links.md](references/tcc-deep-links.md). |
| **Single-archive output** | capture | `capture --tarball` rolls `~/migration-bundle/` into `migration-bundle.tar.zst` for transit. |
| **Brewfile prune + orphan-to-Brewfile** | inventory | Before capture: surface unused casks/formulae (suggest prune). For orphan apps: `brew search` each and offer to add to Brewfile. |
| **Cleanup-old-Mac advisory** | diff | After successful diff verify on new Mac: emit a checklist of what's safe to wipe on the OLD Mac (deactivate licenses, sign out of iCloud, secure-erase guidance). |
| **Drift detection** | inventory + diff | `mac-migration baseline` writes a snapshot to `~/.mac-migration/baseline.json`. Later `inventory --diff-baseline` reports what's changed on the current Mac. |

## Per-app playbooks

Seven apps have non-obvious migration flows. Their playbooks live at [references/per-app/](references/per-app/) and are referenced by capture + restore at the relevant lane.

- **[Postgres](references/per-app/postgres.md)** — `pg_dumpall` (portable) vs raw data-dir rsync (same-major-version only). Cross-major upgrade uses `pg_upgrade`. Extensions must be reinstalled.
- **[Docker](references/per-app/docker.md)** — **NEVER** copy `~/Library/Group Containers/group.com.docker/` (kills the daemon on the new Mac). Copy `~/.docker/` (contexts) only; let Docker Desktop recreate the VM.
- **[1Password](references/per-app/one-password.md)** — Account sign-in only. Do NOT copy the container — code-signature ACL will reject it. App reconstructs vaults from server.
- **[Photos](references/per-app/photos.md)** — Photos Library is a `.photoslibrary` bundle. NEVER raw rsync — use iCloud Photo Library OR the `Photos > File > Export Original` flow.
- **[Music / Apple Music](references/per-app/music.md)** — Similar pattern to Photos. iCloud Music Library handles cloud copies. Local library + smart playlists need the iTunes library copy flow.
- **[Messages](references/per-app/messages.md)** — Never copy `~/Library/Messages/chat.db`. Apple ID sign-in + iCloud Messages restores history. Local-only conversations require a separate export.
- **[Mail](references/per-app/mail.md)** — `~/Library/Mail/V<n>/` — version number bumps with macOS. IMAP messages re-sync from server; rules + signatures + smart mailboxes need the V-dir copy.

## Bundle layout

```
~/migration-bundle/
  manifest.json                   (user opt-outs + target-Mac version + bundle metadata)
  manifest.sha256                 (integrity hashes)
  migration.log.jsonl             (audit log)
  .done/                          (idempotency markers)
    lane-a-apps
    lane-b-shell
    ...
  Brewfile                        (Lane A)
  manifests/                      (Lane A2, C, H exported lists)
    mas-installed.txt
    system-apps.json
    .tool-versions
    pipx.json
    npm-globals.json
    cargo-installs.txt
    brew-services-running.txt
    user-crontab.txt
    pm2-dump.pm2
  dotfiles-refs/                  (Lane B for chezmoi-not-yet users)
  home-bin/                       (Lane B4)
  defaults/                       (Lane D1)
  AppSupport/                     (Lane D2 selective)
  fonts/                          (Lane D4)
  browsers/                       (Lane E)
  ides/                           (Lane F)
  databases/                      (Lane G pg_dumpall.sql, redis-dump.rdb, etc.)
  docker/                         (Lane G5 .docker/ only)
  launchd/                        (Lane H user + system plists)
  credentials/                    (Lane I GPG-encrypted)
    credentials.tar.gz.gpg
  MANUAL-STEPS.md                 (Lane J checklist for the user)
```

## Reference index

- [references/inventory-lanes.md](references/inventory-lanes.md) — full spec of 10 lanes / 40+ sub-modules
- [references/per-app/](references/per-app/) — 7 sensitive-app playbooks
- [references/tahoe-sip-advisory.md](references/tahoe-sip-advisory.md) — macOS 26 LaunchDaemon + SMAppService rules
- [references/tcc-deep-links.md](references/tcc-deep-links.md) — System Settings URL schemes for permission panels
- [references/encryption-flow.md](references/encryption-flow.md) — GPG encrypt/decrypt for Lane I
- [references/launchd-reasoner.md](references/launchd-reasoner.md) — read + explain plists, flag Tahoe issues

## Shared scripts

These atomic scripts are invoked by multiple sub-skills. Each one is cron-rerunnable in isolation.

- [scripts/detect_macos_version.sh](scripts/detect_macos_version.sh) — return major macOS version + codename
- [scripts/lane_done_marker.sh](scripts/lane_done_marker.sh) — write/check `.done/<lane>` markers
- [scripts/encrypt_creds.sh](scripts/encrypt_creds.sh) — GPG seal/unseal Lane I
- [scripts/smoke_test_lane.sh](scripts/smoke_test_lane.sh) — per-lane verification helper
- [scripts/tcc_deep_link.sh](scripts/tcc_deep_link.sh) — open System Settings panel by name

## Tier registration

Tier 1. Auto-triggers on Mac-migration intent. Specific trigger surface so it doesn't fire on unrelated tasks — only when the user explicitly signals migration, new-Mac-setup, or drift-check intent.

## Provenance

Built fresh — no merge candidates. The Feb 2026 Hacker News thread *"It's 2026 and setting up a Mac for development is still mass googling"* confirmed no AI-driven Mac migration tool existed when this skill was created. The 5-lane research and 17 cloned reference repositories informed the toolchain choices: chezmoi over Mackup (Mackup broken on Sonoma+), mise as the single version manager, mas-cli with `get` fallback (npm-style `install` fails on fresh Apple IDs), and skip Apple's Migration Assistant for any developer setup.
