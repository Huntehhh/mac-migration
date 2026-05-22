# Per-App Playbook — Postgres

**Lane:** G1
**Risk level:** Medium (data loss if you copy data dir cross-major)
**Recovery difficulty:** Hard if you skip `pg_dumpall`

---

## Overview

Postgres on macOS is most commonly installed via Homebrew (`postgresql@17`, `postgresql@16`, etc.). Each major version owns its own data directory at `/opt/homebrew/var/postgresql@<N>/`. Homebrew NEVER touches the data directory on `brew upgrade` — so the data survives in place across formula updates within the same major. Across majors, you need `pg_upgrade` or a dump/restore cycle.

Two migration flows:

- **Portable (recommended):** `pg_dumpall` produces SQL text. Version-agnostic; works across majors and across platforms (Intel → Apple Silicon, macOS → Linux). Slower for large databases. Always works.
- **Fast (same-major only):** rsync the data directory. Bit-for-bit copy. Only works when source and destination Postgres are the same major version (17 → 17, not 16 → 17). Fastest by an order of magnitude.

Default to portable unless the database is large (>50 GB) and the user is confirmed same-major.

---

## Detect installed versions

```bash
# Find installed Postgres formulae.
brew list --formula | grep '^postgresql'
# Expected output:
#   postgresql@17
#   postgresql@16
#   postgresql@15

# Find which is the default (no @ suffix in PATH).
which psql
psql --version

# Check which versions have actual data directories.
ls -d /opt/homebrew/var/postgresql@*
```

The capture lane records every version that has BOTH a Homebrew install AND a data dir — those are the migration targets.

---

## Capture (portable flow)

```bash
# For each installed major version:
for ver in 15 16 17; do
    if [ -d "/opt/homebrew/var/postgresql@${ver}" ]; then
        echo "Capturing Postgres ${ver}..."
        # Start service so we can dump.
        brew services start "postgresql@${ver}"
        sleep 3

        # Dump all databases + roles + tablespaces into one SQL file.
        /opt/homebrew/opt/postgresql@${ver}/bin/pg_dumpall \
            -U "$(whoami)" \
            -f ~/migration-bundle/databases/pg${ver}-all.sql

        # Record the version for restore.
        echo "${ver}" >> ~/migration-bundle/databases/pg-versions.txt
    fi
done

# Also capture the list of extensions per database (pg_dumpall captures CREATE EXTENSION,
# but the extension binaries themselves come from Homebrew formulas — they need separate install).
psql -U "$(whoami)" -c "SELECT extname FROM pg_extension;" -At \
    > ~/migration-bundle/databases/pg-extensions.txt
```

`pg_dumpall` requires the server to be running and the user to be a superuser. Using `$(whoami)` works when the OS user is also a Postgres superuser (Homebrew's default setup).

## Capture (fast flow, same-major only)

```bash
# Stop the service FIRST. Copying a live data dir produces a corrupt copy.
brew services stop postgresql@17

# rsync the data dir.
rsync -av --info=progress2 \
    /opt/homebrew/var/postgresql@17/ \
    ~/migration-bundle/databases/pg17-datadir/

# Restart on the old Mac.
brew services start postgresql@17
```

Note the trailing slash on both paths in rsync — that copies the contents of `postgresql@17/` into `pg17-datadir/` rather than nesting another level.

---

## Restore (portable flow)

```bash
# 1. Install Postgres at the target major.
brew install postgresql@17

# 2. Start the service. First start initializes an empty data dir.
brew services start postgresql@17
sleep 5

# 3. Reinstall extensions (these are formula-managed; pg_dumpall references them
#    but does not include the binaries).
while read ext; do
    case "$ext" in
        plpgsql) ;;  # built-in, skip
        pgvector) brew install pgvector ;;
        postgis) brew install postgis ;;
        *)        echo "MANUAL: install extension '$ext' before restore" ;;
    esac
done < ~/migration-bundle/databases/pg-extensions.txt

# 4. Restore the SQL dump.
/opt/homebrew/opt/postgresql@17/bin/psql -U "$(whoami)" -d postgres \
    -f ~/migration-bundle/databases/pg17-all.sql

# 5. Verify.
psql -U "$(whoami)" -c '\l'   # lists databases — should match old Mac
```

## Restore (fast flow)

```bash
# 1. Install matching major version.
brew install postgresql@17

# 2. DO NOT start the service yet. Replace the data dir first.
rm -rf /opt/homebrew/var/postgresql@17
rsync -av ~/migration-bundle/databases/pg17-datadir/ /opt/homebrew/var/postgresql@17/

# 3. Fix ownership — Postgres refuses to start if the data dir isn't owned by
#    the correct user. On macOS Homebrew Postgres runs as the current user,
#    not as `_postgres` like a system install.
chown -R "$(whoami)":staff /opt/homebrew/var/postgresql@17
chmod 700 /opt/homebrew/var/postgresql@17

# 4. Start the service.
brew services start postgresql@17

# 5. Verify.
psql -U "$(whoami)" -c '\l'
```

---

## Cross-major upgrade with `pg_upgrade`

If the user is on Postgres 15 on the old Mac and wants 17 on the new one, and the database is large enough that pg_dumpall is impractical, use `pg_upgrade`:

```bash
# On the new Mac, install BOTH the old and new major.
brew install postgresql@15 postgresql@17

# Initialize the new (17) data dir without starting service.
/opt/homebrew/opt/postgresql@17/bin/initdb -D /opt/homebrew/var/postgresql@17

# Restore the OLD (15) data dir from the bundle.
rsync -av ~/migration-bundle/databases/pg15-datadir/ /opt/homebrew/var/postgresql@15/
chown -R "$(whoami)":staff /opt/homebrew/var/postgresql@15
chmod 700 /opt/homebrew/var/postgresql@15

# Run pg_upgrade.
/opt/homebrew/opt/postgresql@17/bin/pg_upgrade \
    -b /opt/homebrew/opt/postgresql@15/bin \
    -B /opt/homebrew/opt/postgresql@17/bin \
    -d /opt/homebrew/var/postgresql@15 \
    -D /opt/homebrew/var/postgresql@17

# pg_upgrade emits two cleanup scripts: analyze_new_cluster.sh and delete_old_cluster.sh.
# Run analyze, verify, THEN delete.
./analyze_new_cluster.sh
brew services start postgresql@17
psql -U "$(whoami)" -c '\l'    # verify before deleting old
./delete_old_cluster.sh
brew uninstall postgresql@15
```

---

## Gotchas

- **Extension reinstall is mandatory across majors.** Even with `pg_dumpall`, the dump references `CREATE EXTENSION` but the binary `.so` files come from Homebrew formulae. `pgvector`, `postgis`, `timescaledb`, `pg_stat_statements`, `uuid-ossp` all need explicit `brew install <formula>` before the dump restore runs.
- **Same-major rsync still requires service-stopped state.** Copying a live data dir produces a corrupt copy that Postgres will detect and refuse to start. Stop service → rsync → start service.
- **Data dir ownership.** Homebrew Postgres on macOS runs as the current user (typically `hunter:staff`), unlike system Postgres on Linux which runs as `_postgres:_postgres`. After rsync, `chown` to match the destination user. If you accidentally chown to `_postgres` (because old habit), Postgres refuses to start with "data directory has invalid permissions".
- **`postgresql` vs `postgresql@N` — the unversioned formula moves.** Homebrew's bare `postgresql` formula always points at the latest major. If the user installed via the unversioned name on the old Mac (now on 16), and runs `brew install postgresql` on the new Mac (now 17), they've silently upgraded majors. Always pin to `postgresql@N`.
- **`pg_dumpall` does not include large objects by default.** If the database uses `lo_create`/`lo_export` blobs, add `--blobs` to the dumpall call (Postgres 15+) or use `pg_dump --large-objects` per database.

---

## Recovery

If restore breaks:

```bash
# Check service status.
brew services info postgresql@17

# Check logs.
tail -100 /opt/homebrew/var/log/postgresql@17.log

# Common: "could not access directory: Permission denied"
# Fix:    chown -R "$(whoami)":staff /opt/homebrew/var/postgresql@17

# Common: "database files are incompatible with server"
# Cause:  cross-major rsync (e.g., 15 data with 17 binary)
# Fix:    use pg_upgrade or pg_dumpall

# Nuclear option: drop and re-init.
brew services stop postgresql@17
rm -rf /opt/homebrew/var/postgresql@17
/opt/homebrew/opt/postgresql@17/bin/initdb -D /opt/homebrew/var/postgresql@17
brew services start postgresql@17
# Then psql restore from the SQL dump.
```

---

## Sources

- [Postgres docs — pg_dumpall](https://www.postgresql.org/docs/current/app-pg-dumpall.html)
- [Postgres docs — pg_upgrade](https://www.postgresql.org/docs/current/pgupgrade.html)
- [Homebrew formula — postgresql@17](https://formulae.brew.sh/formula/postgresql@17)
- [pgvector — README](https://github.com/pgvector/pgvector) (extension install pattern)
- Empirical: Hunter's own multi-major Postgres rebuilds across 3 Macs
