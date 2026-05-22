# Per-App Playbook — Docker Desktop

**Lane:** G5
**Risk level:** High (one wrong directory = dead daemon)
**Recovery difficulty:** Hard — Docker Desktop's failure modes are silent

---

## Overview

Docker on macOS means Docker Desktop, which runs a Linux VM (HyperKit, then Virtualization.framework on Apple Silicon) under the GUI. The interesting state lives in two places:

- **`~/.docker/`** — user config: contexts, daemon.json, credentials helper config, plugin metadata. Safe to copy.
- **`~/Library/Group Containers/group.com.docker/` + `~/Library/Containers/com.docker.docker/`** — the VM disk image, internal sockets, app sandbox. **NEVER copy these.** This is the well-known failure mode that breaks Docker Desktop after Migration Assistant moves them.

The right pattern: install Docker Desktop fresh on the new Mac, copy `~/.docker/` over, let the daemon recreate the VM from scratch, then pull images back from registries.

---

## Detect installed state

```bash
# Is Docker Desktop installed?
[ -d /Applications/Docker.app ] && echo "Docker Desktop installed"

# What's the daemon status?
docker info 2>&1 | head -5

# What contexts exist?
docker context ls

# What images are currently on disk?
docker images --format '{{.Repository}}:{{.Tag}}' > /tmp/current-images.txt

# What's the VM disk size (the big number we're choosing not to migrate)?
ls -lh ~/Library/Containers/com.docker.docker/Data/vms/0/data/Docker.raw 2>/dev/null
```

---

## Capture

```bash
# 1. Copy ~/.docker/ — contexts, credentials, daemon config.
mkdir -p ~/migration-bundle/docker/
rsync -av --exclude='*.log' --exclude='cache/' \
    ~/.docker/ ~/migration-bundle/docker/dot-docker/

# 2. List images so we can re-pull on the new Mac.
docker images --format '{{.Repository}}:{{.Tag}}' \
    | grep -v '^<none>' \
    > ~/migration-bundle/docker/images-to-pull.txt

# 3. List compose stacks (if any are running).
docker compose ls --format json \
    > ~/migration-bundle/docker/compose-stacks.json 2>/dev/null

# 4. Capture Docker Desktop settings (GUI prefs, resource limits).
[ -f ~/Library/Group\ Containers/group.com.docker/settings-store.json ] \
    && cp ~/Library/Group\ Containers/group.com.docker/settings-store.json \
       ~/migration-bundle/docker/settings-store.json
[ -f ~/Library/Group\ Containers/group.com.docker/settings.json ] \
    && cp ~/Library/Group\ Containers/group.com.docker/settings.json \
       ~/migration-bundle/docker/settings.json
```

`settings.json` and `settings-store.json` are JSON config files, NOT the broken container directory. They're safe to copy individually — the issue is copying the whole container directory wholesale.

**Explicitly NOT captured:**
- `~/Library/Containers/com.docker.docker/` — the app sandbox
- `~/Library/Group Containers/group.com.docker/Data/` — the VM disk + internal state
- `Docker.raw` (the VM disk image, often 20-100 GB)

---

## Restore

```bash
# 1. Install Docker Desktop via cask.
brew install --cask docker

# 2. Launch it ONCE to trigger first-run wizard. Wait for the daemon to come up.
open /Applications/Docker.app
echo "Waiting for Docker daemon..."
while ! docker info >/dev/null 2>&1; do
    sleep 2
done
echo "Docker is up."

# 3. Quit Docker Desktop before we touch its config.
osascript -e 'quit app "Docker"'
sleep 3

# 4. Restore ~/.docker/ config.
mkdir -p ~/.docker
rsync -av ~/migration-bundle/docker/dot-docker/ ~/.docker/

# 5. Restore GUI settings (optional; user can also re-configure manually).
mkdir -p ~/Library/Group\ Containers/group.com.docker/
[ -f ~/migration-bundle/docker/settings-store.json ] \
    && cp ~/migration-bundle/docker/settings-store.json \
       ~/Library/Group\ Containers/group.com.docker/settings-store.json
[ -f ~/migration-bundle/docker/settings.json ] \
    && cp ~/migration-bundle/docker/settings.json \
       ~/Library/Group\ Containers/group.com.docker/settings.json

# 6. Re-launch Docker Desktop.
open /Applications/Docker.app
while ! docker info >/dev/null 2>&1; do sleep 2; done

# 7. Re-authenticate to private registries (each one separately).
docker login   # Docker Hub
# docker login ghcr.io
# docker login <private-registry>

# 8. Pull images back from registries.
while read img; do
    echo "Pulling $img..."
    docker pull "$img" || echo "FAILED: $img (skipping)"
done < ~/migration-bundle/docker/images-to-pull.txt

# 9. Verify.
docker context ls
docker images
docker info | grep -E 'Server Version|Architecture|OS'
```

---

## Gotchas

- **The killer gotcha: `~/Library/Group Containers/group.com.docker/Data/` will kill the daemon if copied.** This is documented in [Docker Desktop issue #6164](https://github.com/docker/for-mac/issues/6164). Migration Assistant copies it by default and produces a daemon that hangs at startup with no useful error. The fix is to delete the directory and let Docker recreate it. The migration skill's whole reason for handling Docker explicitly is to dodge this trap.

- **Settings JSON files vs the broken directory.** `settings.json` and `settings-store.json` are individual config files inside the Group Container path — those ARE safe to copy. The unsafe items are the whole subdirectories: `Data/`, `_logs/`, `pki/`. Copy by-file, never by-tree.

- **Don't try to copy the VM disk.** `Docker.raw` is the VM's entire disk — gigabytes, sometimes hundreds. Even if you could copy it without corruption (you can't reliably, since Docker holds it open via mmap), the receiving Docker Desktop would refuse it because the VM identity tokens don't match. Pull images from registries instead.

- **Apple Silicon ↔ Intel image compatibility.** If migrating Intel → Apple Silicon, any pulled image that's amd64-only will run via Rosetta inside the VM (slow but works). For native arm64 performance, the user needs to re-pull with `docker pull --platform linux/arm64 <image>`. The migration skill should surface this when the source Mac is Intel and the target is Apple Silicon.

- **Credential helpers.** `~/.docker/config.json` references credsStore (e.g., `"credsStore": "desktop"`). The actual credentials live in Keychain on the OLD Mac and are NOT migrated. Every `docker login` needs to be re-run.

- **Compose stacks need `docker compose pull` after credentials restore.** Stacks that depend on private images will fail to start until you've re-logged into each registry and re-pulled.

---

## Recovery

If Docker Desktop hangs at startup after restore (the classic broken-directory symptom):

```bash
# 1. Quit Docker fully.
osascript -e 'quit app "Docker"'
killall Docker 2>/dev/null

# 2. Nuke the broken state.
rm -rf ~/Library/Group\ Containers/group.com.docker/Data
rm -rf ~/Library/Containers/com.docker.docker/Data

# 3. Re-launch Docker Desktop.
open /Applications/Docker.app

# Docker will recreate the VM from scratch. This takes 30-90 seconds on first
# launch. All your ~/.docker/ context + credential config is preserved.
```

If `docker info` still returns "Cannot connect to the Docker daemon" after 2 minutes:

```bash
# Last resort — full factory reset via Docker Desktop GUI:
# Docker menu -> Troubleshoot -> Clean / Purge data -> Reset to factory defaults
# Then re-apply ~/.docker/ config from the bundle.
```

---

## Verify

```bash
# All three should succeed.
docker info                # daemon up
docker context ls          # contexts present
docker pull alpine:latest  # registry connectivity
docker run --rm alpine:latest echo "OK"   # daemon can actually start containers
```

---

## Sources

- [docker/for-mac issue #6164 — Migration Assistant breaks Docker Desktop](https://github.com/docker/for-mac/issues/6164) — the canonical reference for why the Group Container directory must not be copied
- [Docker Desktop — Settings and preferences on Mac](https://docs.docker.com/desktop/settings/mac/)
- [Docker docs — Docker context](https://docs.docker.com/engine/manage-resources/contexts/)
- [Docker docs — Credential stores](https://docs.docker.com/reference/cli/docker/login/#credential-stores)
