#!/usr/bin/env bash
# restore_lane_g_databases.sh -- Lane G: Postgres + MySQL + Redis + Mongo + Docker + k8s + Helm.
# Per-app playbooks at ../../references/per-app/ are authoritative for cross-major upgrades.

set -euo pipefail

PARENT="$(cd "$(dirname "$0")/../.." && pwd)"
BUNDLE="${BUNDLE:-$HOME/migration-bundle}"
LANE="lane-g-databases"

audit_log() {
  printf '{"ts":"%s","lane":"G","action":"%s","target":"%s","rc":%d}\n' \
    "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$1" "$2" "$3" >> "$BUNDLE/migration.log.jsonl"
}

if [ -f "$BUNDLE/.done/$LANE" ] && [ "${1:-}" != "--force" ]; then
  echo "[lane-g] Already complete. Pass --force to re-run."
  exit 0
fi

if [ -f "$BUNDLE/manifest.json" ] && command -v jq > /dev/null; then
  if [ "$(jq -r '.lane_g.skip // false' "$BUNDLE/manifest.json")" = "true" ]; then
    echo "[lane-g] Skipped per manifest.json opt-out."
    echo "skipped=true" > "$BUNDLE/.done/$LANE"
    audit_log "skip" "manifest_opt_out" 0
    exit 0
  fi
fi

mkdir -p "$BUNDLE/.done"

# G1. Postgres
if [ -f "$BUNDLE/databases/postgres-all.sql" ]; then
  PG_MAJOR="17"
  if [ -f "$BUNDLE/manifest.json" ] && command -v jq > /dev/null; then
    PG_MAJOR=$(jq -r '.lane_g.postgres_major // "17"' "$BUNDLE/manifest.json")
  fi
  echo "[lane-g] Restoring Postgres $PG_MAJOR..."
  brew install "postgresql@$PG_MAJOR" 2>/dev/null || true
  brew services start "postgresql@$PG_MAJOR" 2>/dev/null || true
  sleep 3

  # Wait briefly for socket
  for i in 1 2 3 4 5; do
    if psql -U postgres -c '\q' 2>/dev/null; then break; fi
    sleep 2
  done

  if psql -U postgres -f "$BUNDLE/databases/postgres-all.sql" 2>/dev/null; then
    echo "[lane-g]   Postgres restored."
    audit_log "psql_restore" "$BUNDLE/databases/postgres-all.sql" 0
  else
    echo "[lane-g]   FAIL: psql restore had errors. Check service status."
    audit_log "psql_restore" "$BUNDLE/databases/postgres-all.sql" 1
  fi

  # Reinstall extensions
  if [ -f "$BUNDLE/manifests/postgres-extensions.txt" ]; then
    echo "[lane-g] Reinstalling Postgres extensions..."
    while IFS= read -r ext; do
      [ -z "$ext" ] && continue
      brew reinstall "$ext" 2>/dev/null || echo "[lane-g]   FAIL: $ext"
    done < "$BUNDLE/manifests/postgres-extensions.txt"
  fi
  echo "[lane-g]   ADVISORY: for cross-major upgrade, see $PARENT/references/per-app/postgres.md"
fi

# G2. MySQL
if [ -f "$BUNDLE/databases/mysql-all.sql" ]; then
  echo "[lane-g] Restoring MySQL..."
  brew install mysql 2>/dev/null || true
  brew services start mysql 2>/dev/null || true
  sleep 3
  mysql -u root < "$BUNDLE/databases/mysql-all.sql" 2>/dev/null \
    || echo "[lane-g]   FAIL: mysql restore had errors."
  audit_log "mysql_restore" "$BUNDLE/databases/mysql-all.sql" 0
fi

# G3. Redis
if [ -f "$BUNDLE/databases/redis-dump.rdb" ]; then
  echo "[lane-g] Restoring Redis dump..."
  brew install redis 2>/dev/null || true
  brew services stop redis 2>/dev/null || true
  REDIS_DIR="/opt/homebrew/var/db/redis"
  [ -d "/usr/local/var/db/redis" ] && REDIS_DIR="/usr/local/var/db/redis"
  mkdir -p "$REDIS_DIR"
  cp "$BUNDLE/databases/redis-dump.rdb" "$REDIS_DIR/dump.rdb"
  brew services start redis
  audit_log "redis_restore" "$REDIS_DIR/dump.rdb" 0
fi

# G4. MongoDB
if [ -d "$BUNDLE/databases/mongodb-dump" ] && command -v mongorestore > /dev/null; then
  echo "[lane-g] Restoring MongoDB dump..."
  brew tap mongodb/brew 2>/dev/null || true
  brew install mongodb-community 2>/dev/null || true
  brew services start mongodb-community 2>/dev/null || true
  sleep 3
  mongorestore "$BUNDLE/databases/mongodb-dump/" 2>/dev/null \
    || echo "[lane-g]   FAIL: mongorestore had errors."
  audit_log "mongorestore" "$BUNDLE/databases/mongodb-dump" 0
fi

# G5. Docker -- CRITICAL: refuse Group Containers
if [ -d "$BUNDLE/docker" ] || command -v docker > /dev/null; then
  echo "[lane-g] Docker -- installing Desktop + restoring ~/.docker/ only..."
  brew install --cask docker 2>/dev/null || true
  if [ -d "$BUNDLE/docker" ]; then
    mkdir -p "$HOME/.docker"
    rsync -av "$BUNDLE/docker/" "$HOME/.docker/"
  fi
  # Defensive refusal
  if [ -d "$BUNDLE/docker-group-containers" ]; then
    echo "[lane-g] REFUSING to restore docker-group-containers (kills Docker daemon)."
    echo "[lane-g]   See $PARENT/references/per-app/docker.md for explanation."
  fi
  echo "[lane-g]   Docker Desktop installed. Launch it manually; daemon recreates state."
  audit_log "docker_restore" "$HOME/.docker" 0
fi

# G6. Kubernetes
if [ -f "$BUNDLE/manifests/kubeconfig" ]; then
  echo "[lane-g] Restoring kubeconfig..."
  mkdir -p "$HOME/.kube"
  cp "$BUNDLE/manifests/kubeconfig" "$HOME/.kube/config"
  chmod 600 "$HOME/.kube/config"
  audit_log "kubeconfig" "$HOME/.kube/config" 0

  # krew + plugins
  if command -v kubectl > /dev/null && ! kubectl krew > /dev/null 2>&1; then
    echo "[lane-g] Installing krew..."
    (
      set -x
      tmpd=$(mktemp -d)
      cd "$tmpd"
      OS="$(uname | tr '[:upper:]' '[:lower:]')"
      ARCH="$(uname -m | sed 's/x86_64/amd64/' | sed 's/aarch64/arm64/')"
      KREW="krew-${OS}_${ARCH}"
      curl -fsSLO "https://github.com/kubernetes-sigs/krew/releases/latest/download/${KREW}.tar.gz"
      tar zxvf "${KREW}.tar.gz"
      "./${KREW}" install krew
    ) || echo "[lane-g]   krew install failed."
  fi

  if [ -f "$BUNDLE/manifests/krew-plugins.txt" ]; then
    echo "[lane-g] Reinstalling krew plugins..."
    while IFS= read -r plugin; do
      [ -z "$plugin" ] && continue
      kubectl krew install "$plugin" 2>/dev/null || echo "[lane-g]   FAIL: $plugin"
    done < "$BUNDLE/manifests/krew-plugins.txt"
  fi
fi

# G7. Helm
if [ -f "$BUNDLE/manifests/helm-repos.txt" ]; then
  echo "[lane-g] Restoring Helm repos..."
  brew install helm 2>/dev/null || true
  while IFS= read -r line; do
    [ -z "$line" ] && continue
    NAME=$(echo "$line" | awk '{print $1}')
    URL=$(echo "$line" | awk '{print $2}')
    [ -z "$NAME" ] || [ -z "$URL" ] && continue
    helm repo add "$NAME" "$URL" 2>/dev/null || echo "[lane-g]   FAIL: helm repo add $NAME"
  done < "$BUNDLE/manifests/helm-repos.txt"
  helm repo update 2>/dev/null || true
  audit_log "helm_repos" "$BUNDLE/manifests/helm-repos.txt" 0
fi

echo "$(date -u +%Y-%m-%dT%H:%M:%SZ)" > "$BUNDLE/.done/$LANE"
audit_log "complete" "$LANE" 0
echo "[lane-g] DONE."
exit 0
