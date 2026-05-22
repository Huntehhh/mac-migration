# Mac Migration -- Audit Summary

**Skill:** mac-migration
**Last audited:** 2026-05-22
**Verdict:** pass

## Catalog Entry

- **Purpose:** Mac-to-Mac migration toolchain — inventory, capture, restore, verify everything a power user carries between Macs. Replaces Apple's Migration Assistant for developer setups.
- **Triggers:** "migrate my Mac", "new Mac setup", "moving to new Mac", "rebuild Mac from scratch", "Mac drift detection", "restore from migration bundle", "back up Mac for migration", "audit my Mac state"
- **Dependencies / chains:** Standalone. Optional chains: deep-research (when user wants to investigate a specific app's migration flow during inventory), agent-teams (when capture/restore needs parallelization for many lanes).
- **Line count (SKILL.md):** ~200 lines parent + ~200-300 per sub-skill SKILL.md
- **Frontmatter quality:** Name kebab-case + valid. Description comprehensive (~950 chars, under 1024 limit), includes 8 trigger phrases, declares `metadata.compatibility: macos` for platform-lock.

## Composability

Composable parent with 4 atomic sub-skills (`inventory`, `capture`, `restore`, `diff`). Parent SKILL.md routing table dispatches based on user intent. Sub-skills load on-demand when parent body references them. Shared infrastructure at parent level: 5 atomic scripts (`detect_macos_version`, `lane_done_marker`, `encrypt_creds`, `smoke_test_lane`, `tcc_deep_link`) and 5 shared references (`inventory-lanes`, `tahoe-sip-advisory`, `tcc-deep-links`, `encryption-flow`, `launchd-reasoner`) + 7 per-app playbooks (`per-app/postgres.md`, etc.).

## Coverage

10 lanes (A-J) covering 40+ sub-modules:
- A: applications (Brewfile + mas + orphan apps)
- B: shell + PATH + custom scripts
- C: language toolchains + global packages
- D: GUI app configs (defaults plists + AppSupport + Containers + fonts)
- E: browsers (6 supported)
- F: IDEs + terminals
- G: databases + containers (Postgres + MySQL + Redis + Mongo + Docker + k8s + Helm)
- H: background services (LaunchAgents + brew services + PM2 + cron + Login Items + Launchpad)
- I: credentials + auth (SSH + GPG + cloud CLIs + CLI tokens + WireGuard) — GPG-encrypted in bundle
- J: manual / deferred (iCloud Keychain + app licenses + TCC + Time Machine + Spotlight)

## Cross-cutting features (v1)

Pre-flight validation, GPG-encrypt-by-default for Lane I, idempotent `.done` markers, dry-run mode, SHA256 integrity, audit-log JSONL, target-Mac OS detection (Tahoe SIP advisory), TCC deep links, single-archive .tar.zst output, Brewfile prune + orphan-to-Brewfile, cleanup-old-Mac advisory, drift-detection / baseline-snapshot mode.

## Validation

- `quick_validate.py`: parent + diff sub-skill pass clean. inventory/capture/restore hit known false-positive on cross-skill `../references/...` references (validator's regex matches substring regardless of `../` prefix). Same false-positive affects `skill-create-and-ship/create` — known validator limitation, paths resolve correctly at runtime.
- All 38 `.sh` scripts pass `bash -n` syntax check.
- All files ASCII-only.
- Cross-platform gate: PASS via `metadata.compatibility: macos` (explicit platform-lock exit per skill-create-and-ship Step 11.6).
- File count: 52 deliverable files + 5 init_skill.py-generated `_audit/SUMMARY.md` placeholders.
- Total line count: ~12,150 lines.

## Notes

Built fresh — no merge candidates. The Feb 2026 Hacker News thread "It's 2026 and setting up a Mac for development is still mass googling" confirmed no AI-driven Mac migration tool existed at the time. Building blocks that informed the architecture: `jeannier/homebrew-mcp` (Claude MCP for live brew control — pattern reference for AI-in-the-loop), `jazmy/genai-macstudiosetup` (phased-doc-to-Claude-Code pattern). 17 reference repositories studied for code patterns (chezmoi, mise, mas-cli, pipx, cargo-binstall, pm2, lporg, macprefs, yadm, dotbot, geerlingguy/mac-dev-playbook, thoughtbot/laptop, topgrade).

Tier 1 registration. Tier choice rationale: replaces Apple's Migration Assistant as the default flow when user signals migration intent. Trigger surface is specific enough that it won't fire on unrelated tasks.
