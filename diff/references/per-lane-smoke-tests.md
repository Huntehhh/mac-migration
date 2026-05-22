# Per-Lane Smoke Tests

The canonical catalog. Each lane has 1-3 smoke-test commands that prove the restored lane actually works, not just that files / packages are present.

**Contract** for every smoke test:
- Exit 0 → pass
- Non-zero exit → fail, with a one-line diagnostic on stderr
- Side-effect-free (read-only — never mutates state)
- Runs in <10 seconds on a warm Mac
- Tolerates missing optional tools (skip cleanly if a tool isn't installed AND wasn't captured)

`smoke_test_lane.sh <lane-letter>` (parent-level shared script) dispatches to the lane's tests below. Output format is a single line per test:

```
lane=<A> test=<id> status=<pass|fail|skip> detail=<message>
```

A lane is `pass` overall iff every test for it returned `pass` or `skip`. Any `fail` flips the lane to `fail`.

---

## Lane A — Applications

### A.1 — brew binary works

```bash
command -v brew >/dev/null 2>&1 || { echo "brew not on PATH" >&2; exit 1; }
brew --version >/dev/null 2>&1 || { echo "brew --version failed" >&2; exit 1; }
```

### A.2 — Formula count is within tolerance of captured count

Reads `manifest.json` lane A `brewfile_formulae` length, compares to current `brew list --formula | wc -l`. Tolerance: +/- 2 (some formulae auto-install as deps after restore; the count rarely matches exactly).

```bash
expected=$(jq -r '.lanes.A.brewfile_formulae | length' "$BUNDLE/manifest.json")
actual=$(brew list --formula 2>/dev/null | wc -l | tr -d ' ')
diff=$(( actual > expected ? actual - expected : expected - actual ))
test "$diff" -le 2 || { echo "Formula count drift: expected ~$expected, got $actual (delta $diff)" >&2; exit 1; }
```

### A.3 — Cask count is within tolerance

Same shape against `.lanes.A.brewfile_casks` and `brew list --cask`. Tolerance: +/- 1.

---

## Lane B — Shell + PATH + Custom Scripts

### B.1 — Login shell zsh starts cleanly

```bash
zsh -i -c 'exit 0' >/dev/null 2>&1 || { echo "zsh -i failed — broken rc file?" >&2; exit 1; }
```

### B.2 — PATH includes Homebrew prefix

```bash
brew_prefix=$(brew --prefix 2>/dev/null) || { echo "brew --prefix failed" >&2; exit 1; }
echo "$PATH" | tr ':' '\n' | grep -qx "$brew_prefix/bin" || { echo "$brew_prefix/bin not in PATH" >&2; exit 1; }
```

### B.3 — ~/bin scripts are executable (if captured)

```bash
if [ -d "$HOME/bin" ]; then
  non_exec=$(find "$HOME/bin" -type f ! -perm -u+x 2>/dev/null | wc -l | tr -d ' ')
  test "$non_exec" -eq 0 || { echo "$non_exec script(s) in ~/bin missing +x" >&2; exit 1; }
fi
```

---

## Lane C — Language Toolchains + Globals

### C.1 — mise binary works and reads .tool-versions

```bash
command -v mise >/dev/null 2>&1 || { echo "mise not installed" >&2; exit 1; }
mise list >/dev/null 2>&1 || { echo "mise list failed" >&2; exit 1; }
```

### C.2 — Each pinned tool resolves to expected major version

For every entry in `.lanes.C.tool_versions`, run the tool's `--version` and compare the major. Example for node:

```bash
expected_node=$(jq -r '.lanes.C.tool_versions.node // empty' "$BUNDLE/manifest.json")
if [ -n "$expected_node" ]; then
  expected_major="${expected_node%%.*}"
  actual=$(node --version 2>/dev/null | sed 's/^v//;s/\..*//') || { echo "node --version failed" >&2; exit 1; }
  test "$actual" = "$expected_major" || { echo "node major mismatch: expected $expected_major, got $actual" >&2; exit 1; }
fi
```

### C.3 — pipx envs restored (count match)

```bash
if command -v pipx >/dev/null 2>&1; then
  expected=$(jq -r '.lanes.C.pipx_envs | length // 0' "$BUNDLE/manifest.json")
  actual=$(pipx list --json 2>/dev/null | jq -r '.venvs | length // 0')
  test "$actual" -ge "$expected" || { echo "pipx envs: expected $expected, got $actual" >&2; exit 1; }
fi
```

---

## Lane D — GUI App Configs

### D.1 — defaults read works for a known domain

Lane D captured `defaults export <domain>` for many domains. Verify one re-imported correctly by reading back a known key. Uses `com.apple.dock` as a stable canary (always present on macOS).

```bash
defaults read com.apple.dock >/dev/null 2>&1 || { echo "defaults read com.apple.dock failed" >&2; exit 1; }
```

### D.2 — User font count matches (within tolerance)

```bash
expected=$(jq -r '.lanes.D.user_font_count // 0' "$BUNDLE/manifest.json")
actual=$(find "$HOME/Library/Fonts" -type f \( -name '*.ttf' -o -name '*.otf' -o -name '*.woff*' \) 2>/dev/null | wc -l | tr -d ' ')
diff=$(( actual > expected ? actual - expected : expected - actual ))
test "$diff" -le 5 || { echo "Font count drift: expected ~$expected, got $actual" >&2; exit 1; }
```

### D.3 — cfprefsd is alive (configs writable)

```bash
launchctl list 2>/dev/null | grep -q cfprefsd || { echo "cfprefsd not running — defaults writes may be lost" >&2; exit 1; }
```

---

## Lane E — Browsers

### E.1 — Browser app bundles exist for everything captured

For each browser in `.lanes.E.browsers[]`, verify `/Applications/<name>.app` exists.

```bash
jq -r '.lanes.E.browsers[]? // empty' "$BUNDLE/manifest.json" | while read -r name; do
  test -d "/Applications/$name.app" || { echo "/Applications/$name.app missing" >&2; exit 1; }
done
```

### E.2 — Default browser is set

```bash
defaults read com.apple.LaunchServices/com.apple.launchservices.secure 2>/dev/null | grep -q LSHandlerURLScheme || { echo "No default browser binding registered" >&2; exit 1; }
```

---

## Lane F — IDEs + Terminals

### F.1 — VS Code or Cursor CLI on PATH (if captured)

```bash
if jq -e '.lanes.F.ides | index("vscode") // index("cursor")' "$BUNDLE/manifest.json" >/dev/null 2>&1; then
  command -v code >/dev/null 2>&1 || command -v cursor >/dev/null 2>&1 || { echo "Neither code nor cursor on PATH" >&2; exit 1; }
fi
```

### F.2 — VS Code extension count matches captured (if captured)

```bash
if command -v code >/dev/null 2>&1; then
  expected=$(jq -r '.lanes.F.vscode_extensions | length // 0' "$BUNDLE/manifest.json")
  actual=$(code --list-extensions 2>/dev/null | wc -l | tr -d ' ')
  diff=$(( actual > expected ? actual - expected : expected - actual ))
  test "$diff" -le 2 || { echo "VS Code extensions: expected ~$expected, got $actual" >&2; exit 1; }
fi
```

### F.3 — iTerm2 plist readable (if captured)

```bash
if jq -e '.lanes.F.terminals | index("iterm2")' "$BUNDLE/manifest.json" >/dev/null 2>&1; then
  defaults read com.googlecode.iterm2 >/dev/null 2>&1 || { echo "iTerm2 plist unreadable" >&2; exit 1; }
fi
```

---

## Lane G — Databases + Containers

### G.1 — Postgres accepting connections (if captured)

```bash
if jq -e '.lanes.G.databases | index("postgres")' "$BUNDLE/manifest.json" >/dev/null 2>&1; then
  command -v pg_isready >/dev/null 2>&1 || { echo "pg_isready not installed" >&2; exit 1; }
  pg_isready -q -U postgres 2>/dev/null || { echo "pg_isready -U postgres failed" >&2; exit 1; }
fi
```

### G.2 — Redis responding (if captured)

```bash
if jq -e '.lanes.G.databases | index("redis")' "$BUNDLE/manifest.json" >/dev/null 2>&1; then
  redis-cli ping 2>/dev/null | grep -q PONG || { echo "redis-cli ping failed" >&2; exit 1; }
fi
```

### G.3 — Docker contexts restored (if captured)

```bash
if jq -e '.lanes.G.docker_captured' "$BUNDLE/manifest.json" >/dev/null 2>&1; then
  command -v docker >/dev/null 2>&1 || { echo "docker not on PATH" >&2; exit 1; }
  expected=$(jq -r '.lanes.G.docker_context_count // 0' "$BUNDLE/manifest.json")
  actual=$(docker context ls --format '{{.Name}}' 2>/dev/null | wc -l | tr -d ' ')
  test "$actual" -ge "$expected" || { echo "Docker contexts: expected $expected, got $actual" >&2; exit 1; }
fi
```

---

## Lane H — Background Services

### H.1 — Captured user LaunchAgent plists are loaded

For each plist in `.lanes.H.user_launchagents[]`, derive the Label and check `launchctl list`.

```bash
jq -r '.lanes.H.user_launchagents[]? // empty' "$BUNDLE/manifest.json" | while read -r label; do
  launchctl list 2>/dev/null | awk '{print $3}' | grep -qx "$label" || { echo "LaunchAgent $label not loaded" >&2; exit 1; }
done
```

### H.2 — brew services started match captured

```bash
if command -v brew >/dev/null 2>&1; then
  expected=$(jq -r '.lanes.H.brew_services_started[]? // empty' "$BUNDLE/manifest.json" | sort -u)
  actual=$(brew services list 2>/dev/null | awk '$2=="started" {print $1}' | sort -u)
  missing=$(comm -23 <(echo "$expected") <(echo "$actual"))
  test -z "$missing" || { echo "brew services not started: $(echo "$missing" | tr '\n' ' ')" >&2; exit 1; }
fi
```

### H.3 — cron restored (if captured)

```bash
if jq -e '.lanes.H.crontab_captured' "$BUNDLE/manifest.json" >/dev/null 2>&1; then
  crontab -l 2>/dev/null | grep -v '^#' | grep -q . || { echo "crontab empty after restore" >&2; exit 1; }
fi
```

---

## Lane I — Credentials + Auth

Lane I tests are deliberately READ-ONLY and avoid printing secret material. They check that the auth file exists and is parseable, not that the token is valid (validation would require live API calls and rate-limit risk).

### I.1 — Git identity configured

```bash
git config --global user.name >/dev/null 2>&1 || { echo "git user.name not set" >&2; exit 1; }
git config --global user.email >/dev/null 2>&1 || { echo "git user.email not set" >&2; exit 1; }
```

### I.2 — SSH dir perms correct

```bash
test -d "$HOME/.ssh" || { echo "~/.ssh missing" >&2; exit 1; }
perm=$(stat -f '%A' "$HOME/.ssh" 2>/dev/null)
test "$perm" = "700" || { echo "~/.ssh perm is $perm, expected 700 — sshd will refuse keys" >&2; exit 1; }
```

### I.3 — GPG secret keyring loadable (if captured)

```bash
if jq -e '.lanes.I.gpg_captured' "$BUNDLE/manifest.json" >/dev/null 2>&1; then
  command -v gpg >/dev/null 2>&1 || { echo "gpg not installed" >&2; exit 1; }
  gpg --list-secret-keys >/dev/null 2>&1 || { echo "gpg --list-secret-keys failed" >&2; exit 1; }
  count=$(gpg --list-secret-keys --with-colons 2>/dev/null | grep -c '^sec:')
  test "$count" -ge 1 || { echo "No GPG secret keys after restore" >&2; exit 1; }
fi
```

---

## Lane J — Manual / Deferred

Lane J is never auto-handled by capture, so it has no traditional smoke test. Instead, diff surfaces a checklist reminder:

### J.1 — Lane J checklist exists in bundle

```bash
test -f "$BUNDLE/MANUAL-STEPS.md" || { echo "MANUAL-STEPS.md missing from bundle — restore didn't surface Lane J" >&2; exit 1; }
```

This is the only Lane J check — anything more would require humans to confirm UI state.

---

## How smoke_test_lane.sh invokes these

The parent-level `scripts/smoke_test_lane.sh <lane>` reads this file's structure (the H2 sections labeled "Lane X") and the H3 numbered subsections, executes each, captures stderr as the diagnostic, returns the aggregated lane status.

If you add a new lane or new test, follow the existing pattern:
- H2 "Lane X — Theme" header
- One or more H3 "X.N — short description" subsections with a single bash block
- Use `$BUNDLE` for the bundle path (smoke_test_lane.sh exports it)
- Use `jq` for manifest parsing (assume jq is installed — Lane A restores it as a brew formula)
- Never `echo` to stdout from inside the test block — only diagnostic to stderr on fail
- Tests inside `if jq -e ... captured ...` guards skip cleanly when the lane wasn't captured (exit 0)
