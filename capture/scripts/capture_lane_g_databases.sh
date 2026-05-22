#!/usr/bin/env bash
# capture_lane_g_databases.sh
# Lane G -- Databases + Containers
#
# Sub-modules (each gated on tool availability):
#   G1  Postgres - pg_dumpall (portable). See ../references/per-app/postgres.md.
#   G2  MySQL - mysqldump --all-databases
#   G3  Redis - copy dump.rdb
#   G4  Mongo - mongodump
#   G5  Docker - ~/.docker/ ONLY (Group Containers explicitly excluded -- see ../references/per-app/docker.md)
#   G6  Kubernetes - ~/.kube/config + krew plugin list
#   G7  Helm - helm repo list
#
# Opt-out keys:
#   opt_outs.lane_g
#   opt_outs.lane_g.{postgres,mysql,redis,mongo,docker,k8s,helm}

set -euo pipefail

BUNDLE="${BUNDLE:-$HOME/migration-bundle}"
DRY_RUN="${DRY_RUN:-0}"
FORCE="${FORCE:-0}"

for arg in "$@"; do
  case "$arg" in
    --force)   FORCE=1 ;;
    --dry-run) DRY_RUN=1 ;;
    *) echo "capture_lane_g_databases.sh: unknown arg: $arg" >&2; exit 2 ;;
  esac
done

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SUB_SKILL_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
SKILL_DIR="$(cd "$SUB_SKILL_DIR/.." && pwd)"
AUDIT="$SCRIPT_DIR/audit_log.sh"
DONE_HELPER="$SKILL_DIR/scripts/lane_done_marker.sh"
LANE_ID="lane-g-databases"
MANIFEST="$BUNDLE/manifest.json"

if [ ! -f "$MANIFEST" ]; then
  echo "capture_lane_g_databases.sh: $MANIFEST not found -- run inventory first." >&2
  exit 3
fi

mkdir -p "$BUNDLE/databases" "$BUNDLE/docker" "$BUNDLE/manifests" "$BUNDLE/.done" "$BUNDLE/dry-run-report"

opt_out_lane() { jq -e ".opt_outs.lane_g == true" "$MANIFEST" >/dev/null 2>&1; }
opt_out_sub()  { jq -e ".opt_outs.lane_g.$1 == true" "$MANIFEST" >/dev/null 2>&1; }

if opt_out_lane; then
  "$AUDIT" "$LANE_ID" lane skip "manifest.json opts out of entire Lane G"
  [ "$DRY_RUN" != "1" ] && bash "$DONE_HELPER" write "$LANE_ID"
  exit 0
fi

if [ "$FORCE" != "1" ] && bash "$DONE_HELPER" check "$LANE_ID" >/dev/null 2>&1; then
  "$AUDIT" "$LANE_ID" lane skip "Already done -- use --force to re-capture"
  exit 0
fi

"$AUDIT" "$LANE_ID" lane start "Lane G -- Databases + Containers (dry_run=$DRY_RUN, force=$FORCE)"

# --- G1. Postgres -------------------------------------------------------

if ! opt_out_sub postgres; then
  if command -v pg_dumpall >/dev/null 2>&1; then
    if [ "$DRY_RUN" = "1" ]; then
      "$AUDIT" "$LANE_ID" postgres info "Would run pg_dumpall (portable mode). Cross-major: see per-app/postgres.md"
    else
      "$AUDIT" "$LANE_ID" postgres start "Running pg_dumpall (portable mode)"
      if pg_dumpall -U postgres > "$BUNDLE/databases/postgres-all.sql" 2>"$BUNDLE/databases/postgres-dump.err"; then
        size_mb="$(du -sm "$BUNDLE/databases/postgres-all.sql" 2>/dev/null | awk '{print $1}' || echo 0)"
        "$AUDIT" "$LANE_ID" postgres ok "Wrote databases/postgres-all.sql (~${size_mb} MB)"
        "$AUDIT" "$LANE_ID" postgres info "Restore: psql -U postgres -f postgres-all.sql. Extensions (pgvector, postgis) need brew reinstall."
      else
        "$AUDIT" "$LANE_ID" postgres fail "pg_dumpall failed -- see databases/postgres-dump.err (postgres may not be running?)"
        exit 30
      fi
    fi
  else
    "$AUDIT" "$LANE_ID" postgres skip "pg_dumpall not installed"
  fi
else
  "$AUDIT" "$LANE_ID" postgres skip "Opted out via manifest"
fi

# --- G2. MySQL ----------------------------------------------------------

if ! opt_out_sub mysql; then
  if command -v mysqldump >/dev/null 2>&1; then
    if [ "$DRY_RUN" = "1" ]; then
      "$AUDIT" "$LANE_ID" mysql info "Would run mysqldump --all-databases"
    else
      "$AUDIT" "$LANE_ID" mysql start "Running mysqldump --all-databases"
      if mysqldump --all-databases > "$BUNDLE/databases/mysql-all.sql" 2>"$BUNDLE/databases/mysql-dump.err"; then
        size_mb="$(du -sm "$BUNDLE/databases/mysql-all.sql" 2>/dev/null | awk '{print $1}' || echo 0)"
        "$AUDIT" "$LANE_ID" mysql ok "Wrote databases/mysql-all.sql (~${size_mb} MB)"
      else
        "$AUDIT" "$LANE_ID" mysql fail "mysqldump failed -- see databases/mysql-dump.err"
        exit 31
      fi
    fi
  else
    "$AUDIT" "$LANE_ID" mysql skip "mysqldump not installed"
  fi
else
  "$AUDIT" "$LANE_ID" mysql skip "Opted out via manifest"
fi

# --- G3. Redis ----------------------------------------------------------

if ! opt_out_sub redis; then
  redis_dump=/opt/homebrew/var/db/redis/dump.rdb
  redis_dump_intel=/usr/local/var/db/redis/dump.rdb
  src=""
  [ -f "$redis_dump" ]       && src="$redis_dump"
  [ -f "$redis_dump_intel" ] && src="$redis_dump_intel"
  if [ -n "$src" ]; then
    if [ "$DRY_RUN" = "1" ]; then
      "$AUDIT" "$LANE_ID" redis info "Would copy $src"
    else
      cp -p "$src" "$BUNDLE/databases/redis-dump.rdb" \
        && "$AUDIT" "$LANE_ID" redis ok "Wrote databases/redis-dump.rdb" \
        || "$AUDIT" "$LANE_ID" redis warn "Redis dump copy failed (may be locked by running redis-server)"
    fi
  else
    "$AUDIT" "$LANE_ID" redis skip "No redis dump.rdb found"
  fi
else
  "$AUDIT" "$LANE_ID" redis skip "Opted out via manifest"
fi

# --- G4. MongoDB --------------------------------------------------------

if ! opt_out_sub mongo; then
  if command -v mongodump >/dev/null 2>&1; then
    if [ "$DRY_RUN" = "1" ]; then
      "$AUDIT" "$LANE_ID" mongo info "Would run mongodump"
    else
      "$AUDIT" "$LANE_ID" mongo start "Running mongodump"
      mkdir -p "$BUNDLE/databases/mongodb-dump"
      if mongodump --out "$BUNDLE/databases/mongodb-dump/" >"$BUNDLE/databases/mongodb-dump.log" 2>&1; then
        "$AUDIT" "$LANE_ID" mongo ok "Wrote databases/mongodb-dump/"
      else
        "$AUDIT" "$LANE_ID" mongo fail "mongodump failed -- see databases/mongodb-dump.log"
        exit 32
      fi
    fi
  else
    "$AUDIT" "$LANE_ID" mongo skip "mongodump not installed"
  fi
else
  "$AUDIT" "$LANE_ID" mongo skip "Opted out via manifest"
fi

# --- G5. Docker (~/.docker/ ONLY -- never Group Containers) ---------------

if ! opt_out_sub docker; then
  if [ -d ~/.docker ]; then
    if [ "$DRY_RUN" = "1" ]; then
      "$AUDIT" "$LANE_ID" docker info "Would rsync ~/.docker/ (Group Containers intentionally excluded)"
    else
      "$AUDIT" "$LANE_ID" docker start "Rsync ~/.docker/"
      if rsync -a ~/.docker/ "$BUNDLE/docker/" 2>/dev/null; then
        "$AUDIT" "$LANE_ID" docker ok "Wrote docker/ (contexts + credentials + daemon.json)"
        "$AUDIT" "$LANE_ID" docker info "DELIBERATE: Group Containers NOT copied. Migration Assistant doing this kills Docker on new Mac. See per-app/docker.md."
      else
        "$AUDIT" "$LANE_ID" docker warn "Docker rsync returned non-zero"
      fi
    fi
  else
    "$AUDIT" "$LANE_ID" docker skip "No ~/.docker directory"
  fi
else
  "$AUDIT" "$LANE_ID" docker skip "Opted out via manifest"
fi

# --- G6. Kubernetes -----------------------------------------------------

if ! opt_out_sub k8s; then
  if [ -f ~/.kube/config ]; then
    if [ "$DRY_RUN" = "1" ]; then
      "$AUDIT" "$LANE_ID" k8s info "Would copy ~/.kube/config"
    else
      cp -p ~/.kube/config "$BUNDLE/manifests/kubeconfig" \
        && "$AUDIT" "$LANE_ID" k8s ok "Wrote manifests/kubeconfig" \
        || "$AUDIT" "$LANE_ID" k8s warn "kubeconfig copy failed"
    fi
  fi
  if command -v kubectl >/dev/null 2>&1; then
    if [ "$DRY_RUN" != "1" ]; then
      kubectl krew list > "$BUNDLE/manifests/krew-plugins.txt" 2>/dev/null \
        && "$AUDIT" "$LANE_ID" k8s ok "Wrote manifests/krew-plugins.txt" \
        || "$AUDIT" "$LANE_ID" k8s info "kubectl krew not installed or no plugins"
      "$AUDIT" "$LANE_ID" k8s info "krew binaries are platform-specific -- reinstall on new Mac, don't copy"
    fi
  fi
else
  "$AUDIT" "$LANE_ID" k8s skip "Opted out via manifest"
fi

# --- G7. Helm -----------------------------------------------------------

if ! opt_out_sub helm; then
  if command -v helm >/dev/null 2>&1; then
    if [ "$DRY_RUN" = "1" ]; then
      "$AUDIT" "$LANE_ID" helm info "Would record helm repos"
    else
      helm repo list > "$BUNDLE/manifests/helm-repos.txt" 2>/dev/null \
        && "$AUDIT" "$LANE_ID" helm ok "Wrote manifests/helm-repos.txt" \
        || "$AUDIT" "$LANE_ID" helm info "helm has no repos configured"
    fi
  else
    "$AUDIT" "$LANE_ID" helm skip "helm not installed"
  fi
else
  "$AUDIT" "$LANE_ID" helm skip "Opted out via manifest"
fi

# --- done marker --------------------------------------------------------

if [ "$DRY_RUN" = "1" ]; then
  "$AUDIT" "$LANE_ID" lane info "Dry-run complete; no .done marker written"
else
  bash "$DONE_HELPER" write "$LANE_ID"
  "$AUDIT" "$LANE_ID" lane ok "Lane G capture complete"
fi
