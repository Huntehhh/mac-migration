# mac-migration

[![mac-migration CI](https://github.com/Huntehhh/mac-migration/actions/workflows/mac-migration-ci.yml/badge.svg)](https://github.com/Huntehhh/mac-migration/actions/workflows/mac-migration-ci.yml)

A [Claude Code](https://claude.com/claude-code) **skill** for migrating a power user's entire Mac to a new machine. Skip Apple's Migration Assistant — it breaks Homebrew, Docker, and launchd, and silently inherits Rosetta state. This skill reads the old Mac, builds an encrypted bundle, restores onto a fresh install, and verifies the result.

> **macOS only.** Validated by CI on `macos-15` (Sequoia) — full capture → restore round-trip, every push.

## Install

```bash
git clone https://github.com/Huntehhh/mac-migration ~/.claude/skills/mac-migration
```

Then, in any Claude Code session, say **"audit my Mac state"** or **"I'm migrating Macs."** The skill runs a ~60-second scan and shows exactly what it would capture before touching anything. You opt out of whatever you don't want.

## How it works

Composable parent skill + 4 atomic sub-skills, one per phase:

```
OLD MAC                                         NEW MAC
[1] inventory  ──┐                          ┌── [3] restore
    scan + ask    │      transit            │       consume bundle
    what to keep  ▼                         ▼       lane-by-lane
[2] capture    ──> migration-bundle.tar.zst ──> [4] diff
    build bundle  (Lane I creds GPG-encrypted)    verify + smoke test
```

- **inventory** — pre-flight checks + a choose-your-own-adventure scan of all 10 lanes; writes your opt-outs to `manifest.json`.
- **capture** — per-lane atomic scripts build `~/migration-bundle/`; credentials are GPG-encrypted; output is integrity-hashed and optionally tarballed.
- **restore** — verifies the bundle, decrypts credentials, restores lane-by-lane with idempotent `.done` markers; detects macOS Tahoe and surfaces SMAppService advisories.
- **diff** — compares old-Mac manifest to new-Mac state, runs per-lane smoke tests, and doubles as a drift detector on your current Mac.

## The 10 lanes

| Lane | What it covers |
|------|----------------|
| A | Applications — Homebrew formulae + casks, Mac App Store (`mas`), orphan apps |
| B | Shell + PATH + `~/bin` + `/etc/hosts` + sudoers, dotfiles via chezmoi |
| C | Language toolchains via `mise` + global packages (pipx, npm, cargo, gem, go, composer) |
| D | GUI app configs — `defaults` plists, Application Support, fonts, Stickies, Notes, Mail |
| E | Browsers — Chrome, Brave, Firefox, Safari, Arc, Edge |
| F | IDEs + terminals — VS Code/Cursor, Zed, JetBrains, Nvim, iTerm2, Warp, Ghostty |
| G | Databases + containers — Postgres, MySQL, Redis, Mongo, Docker, Kubernetes, Helm |
| H | Background services — LaunchAgents, LaunchDaemons, brew services, PM2, cron, Login Items |
| I | Credentials — SSH, GPG, AWS/GCP/Azure/CF/DO, CLI tokens, WireGuard (GPG-encrypted in the bundle) |
| J | Manual / deferred — iCloud Keychain, app licenses, TCC permissions, Time Machine, Spotlight |

## ⚠ The one thing that can lock you out

Lane I encrypts your credentials with your GPG key — and your GPG key is captured *inside* that encrypted bundle. On a fresh Mac with no key, you can't decrypt the bundle to reach the key. **Permanent lockout.**

The skill's pre-flight step guards against this: it exports your key to `~/migration-gpg-key-BRING-SEPARATELY.asc` (outside the bundle) and writes `GPG-KEY-WARNING.txt`. **Carry that file to the new Mac via a separate channel (USB / password manager) and `gpg --import` it before running restore.** See [`references/encryption-flow.md`](references/encryption-flow.md).

## Per-app playbooks

Seven apps where a naive file copy breaks things have dedicated playbooks in [`references/per-app/`](references/per-app/): **Postgres** (data-dir version lock), **Docker** (never copy `Group Containers/group.com.docker/` — it kills the daemon), **1Password** (account sign-in only), **Photos**, **Music**, **Messages**, **Mail** (the `V<n>` directory bumps with macOS).

## CI

Three jobs run on every push: syntax + ASCII + frontmatter + shellcheck (Ubuntu), capture smoke (macos-15), and a fresh-runner restore round-trip (macos-15). See [`.github/workflows/mac-migration-ci.yml`](.github/workflows/mac-migration-ci.yml).

## Status

v1 — capture/restore round-trip green on macOS 15. Roadmap for v2 (Linux sibling, broader lane CI coverage, `_lib` refactor) tracked privately. Issues and PRs welcome.
