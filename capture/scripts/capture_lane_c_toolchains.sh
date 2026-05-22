#!/usr/bin/env bash
# capture_lane_c_toolchains.sh
# Lane C -- Language toolchains + global packages
#
# Sub-modules (each gated on `command -v <tool>`):
#   C1  mise (.tool-versions + config.toml)
#   C2  pipx list --json
#   C3  npm/pnpm/yarn global listings
#   C4  cargo install --list
#   C5  gem list
#   C6  go bin contents
#   C7  composer global show --json
#
# Opt-out keys:
#   opt_outs.lane_c
#   opt_outs.lane_c.{mise,pipx,node_globals,cargo,gem,go,composer}

set -euo pipefail

BUNDLE="${BUNDLE:-$HOME/migration-bundle}"
DRY_RUN="${DRY_RUN:-0}"
FORCE="${FORCE:-0}"

for arg in "$@"; do
  case "$arg" in
    --force)   FORCE=1 ;;
    --dry-run) DRY_RUN=1 ;;
    *) echo "capture_lane_c_toolchains.sh: unknown arg: $arg" >&2; exit 2 ;;
  esac
done

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SUB_SKILL_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
SKILL_DIR="$(cd "$SUB_SKILL_DIR/.." && pwd)"
AUDIT="$SCRIPT_DIR/audit_log.sh"
DONE_HELPER="$SKILL_DIR/scripts/lane_done_marker.sh"
LANE_ID="lane-c-toolchains"
MANIFEST="$BUNDLE/manifest.json"

if [ ! -f "$MANIFEST" ]; then
  echo "capture_lane_c_toolchains.sh: $MANIFEST not found -- run inventory first." >&2
  exit 3
fi

mkdir -p "$BUNDLE/manifests" "$BUNDLE/.done" "$BUNDLE/dry-run-report"

opt_out_lane() { jq -e ".opt_outs.lane_c == true" "$MANIFEST" >/dev/null 2>&1; }
opt_out_sub()  { jq -e ".opt_outs.lane_c.$1 == true" "$MANIFEST" >/dev/null 2>&1; }

if opt_out_lane; then
  "$AUDIT" "$LANE_ID" lane skip "manifest.json opts out of entire Lane C"
  [ "$DRY_RUN" != "1" ] && bash "$DONE_HELPER" write "$LANE_ID"
  exit 0
fi

if [ "$FORCE" != "1" ] && bash "$DONE_HELPER" check "$LANE_ID" >/dev/null 2>&1; then
  "$AUDIT" "$LANE_ID" lane skip "Already done -- use --force to re-capture"
  exit 0
fi

"$AUDIT" "$LANE_ID" lane start "Lane C -- Toolchains (dry_run=$DRY_RUN, force=$FORCE)"

# --- C1. mise -----------------------------------------------------------

if ! opt_out_sub mise; then
  copied=0
  if [ -f ~/.tool-versions ]; then
    if [ "$DRY_RUN" = "1" ]; then
      "$AUDIT" "$LANE_ID" mise info "Would copy ~/.tool-versions"
    else
      cp -p ~/.tool-versions "$BUNDLE/manifests/.tool-versions"
      copied=$((copied + 1))
    fi
  fi
  if [ -f ~/.config/mise/config.toml ]; then
    if [ "$DRY_RUN" = "1" ]; then
      "$AUDIT" "$LANE_ID" mise info "Would copy mise/config.toml"
    else
      cp -p ~/.config/mise/config.toml "$BUNDLE/manifests/mise-config.toml"
      copied=$((copied + 1))
    fi
  fi
  if [ "$DRY_RUN" != "1" ]; then
    "$AUDIT" "$LANE_ID" mise ok "Copied $copied mise file(s)"
  fi
  if [ "$copied" -eq 0 ] && [ "$DRY_RUN" != "1" ]; then
    "$AUDIT" "$LANE_ID" mise info "No mise config found -- install mise on new Mac if desired"
  fi
else
  "$AUDIT" "$LANE_ID" mise skip "Opted out via manifest"
fi

# --- C2. pipx -----------------------------------------------------------

if ! opt_out_sub pipx; then
  if command -v pipx >/dev/null 2>&1; then
    if [ "$DRY_RUN" = "1" ]; then
      env_count="$(pipx list --short 2>/dev/null | wc -l | tr -d ' ' || echo 0)"
      "$AUDIT" "$LANE_ID" pipx info "Would record $env_count pipx envs"
    else
      "$AUDIT" "$LANE_ID" pipx start "Recording pipx envs"
      if pipx list --json > "$BUNDLE/manifests/pipx.json" 2>/dev/null; then
        "$AUDIT" "$LANE_ID" pipx ok "Wrote manifests/pipx.json"
      else
        "$AUDIT" "$LANE_ID" pipx warn "pipx list --json returned non-zero"
      fi
    fi
  else
    "$AUDIT" "$LANE_ID" pipx skip "pipx not installed"
  fi
else
  "$AUDIT" "$LANE_ID" pipx skip "Opted out via manifest"
fi

# --- C3. npm / pnpm / yarn globals --------------------------------------

if ! opt_out_sub node_globals; then
  for tool in npm pnpm yarn; do
    if command -v "$tool" >/dev/null 2>&1; then
      out="$BUNDLE/manifests/${tool}-globals.json"
      if [ "$DRY_RUN" = "1" ]; then
        "$AUDIT" "$LANE_ID" node_globals info "Would record $tool globals"
      else
        case "$tool" in
          npm)  npm list -g --depth=0 --json > "$out" 2>/dev/null || "$AUDIT" "$LANE_ID" node_globals warn "$tool list failed" ;;
          pnpm) pnpm list -g --depth=0 --json > "$out" 2>/dev/null || "$AUDIT" "$LANE_ID" node_globals warn "$tool list failed" ;;
          yarn) yarn global list --json > "$out" 2>/dev/null || "$AUDIT" "$LANE_ID" node_globals warn "$tool list failed" ;;
        esac
        [ -f "$out" ] && "$AUDIT" "$LANE_ID" node_globals ok "Wrote manifests/$(basename "$out")"
      fi
    fi
  done
else
  "$AUDIT" "$LANE_ID" node_globals skip "Opted out via manifest"
fi

# --- C4. cargo ----------------------------------------------------------

if ! opt_out_sub cargo; then
  if command -v cargo >/dev/null 2>&1; then
    if [ "$DRY_RUN" = "1" ]; then
      "$AUDIT" "$LANE_ID" cargo info "Would record cargo install list"
    else
      "$AUDIT" "$LANE_ID" cargo start "Listing cargo installs"
      if cargo install --list > "$BUNDLE/manifests/cargo-installs.txt" 2>/dev/null; then
        "$AUDIT" "$LANE_ID" cargo ok "Wrote manifests/cargo-installs.txt"
      else
        "$AUDIT" "$LANE_ID" cargo warn "cargo install --list returned non-zero"
      fi
    fi
  else
    "$AUDIT" "$LANE_ID" cargo skip "cargo not installed"
  fi
else
  "$AUDIT" "$LANE_ID" cargo skip "Opted out via manifest"
fi

# --- C5. gem ------------------------------------------------------------

if ! opt_out_sub gem; then
  if command -v gem >/dev/null 2>&1; then
    if [ "$DRY_RUN" = "1" ]; then
      "$AUDIT" "$LANE_ID" gem info "Would record gem list"
    else
      "$AUDIT" "$LANE_ID" gem start "Listing gems"
      if gem list > "$BUNDLE/manifests/gem-list.txt" 2>/dev/null; then
        "$AUDIT" "$LANE_ID" gem ok "Wrote manifests/gem-list.txt"
      else
        "$AUDIT" "$LANE_ID" gem warn "gem list returned non-zero"
      fi
    fi
  else
    "$AUDIT" "$LANE_ID" gem skip "gem not installed"
  fi
else
  "$AUDIT" "$LANE_ID" gem skip "Opted out via manifest"
fi

# --- C6. go bin ---------------------------------------------------------

if ! opt_out_sub go; then
  if command -v go >/dev/null 2>&1; then
    gobin="$(go env GOPATH 2>/dev/null)/bin"
    if [ -d "$gobin" ]; then
      if [ "$DRY_RUN" = "1" ]; then
        bin_count="$(ls -1 "$gobin" 2>/dev/null | wc -l | tr -d ' ' || echo 0)"
        "$AUDIT" "$LANE_ID" go info "Would record $bin_count go-bin entries"
      else
        "$AUDIT" "$LANE_ID" go start "Listing $gobin"
        ls -1 "$gobin" > "$BUNDLE/manifests/go-bin.txt" 2>/dev/null || true
        "$AUDIT" "$LANE_ID" go ok "Wrote manifests/go-bin.txt"
        "$AUDIT" "$LANE_ID" go info "Go has no install-from-list -- restore is manual 'go install <path>@latest' per entry"
      fi
    else
      "$AUDIT" "$LANE_ID" go skip "No GOPATH/bin directory"
    fi
  else
    "$AUDIT" "$LANE_ID" go skip "go not installed"
  fi
else
  "$AUDIT" "$LANE_ID" go skip "Opted out via manifest"
fi

# --- C7. composer -------------------------------------------------------

if ! opt_out_sub composer; then
  if command -v composer >/dev/null 2>&1; then
    if [ "$DRY_RUN" = "1" ]; then
      "$AUDIT" "$LANE_ID" composer info "Would record composer globals"
    else
      "$AUDIT" "$LANE_ID" composer start "Listing composer globals"
      if composer global show --format=json > "$BUNDLE/manifests/composer-globals.json" 2>/dev/null; then
        "$AUDIT" "$LANE_ID" composer ok "Wrote manifests/composer-globals.json"
      else
        "$AUDIT" "$LANE_ID" composer warn "composer global show returned non-zero"
      fi
    fi
  else
    "$AUDIT" "$LANE_ID" composer skip "composer not installed"
  fi
else
  "$AUDIT" "$LANE_ID" composer skip "Opted out via manifest"
fi

# --- done marker --------------------------------------------------------

if [ "$DRY_RUN" = "1" ]; then
  "$AUDIT" "$LANE_ID" lane info "Dry-run complete; no .done marker written"
else
  bash "$DONE_HELPER" write "$LANE_ID"
  "$AUDIT" "$LANE_ID" lane ok "Lane C capture complete"
fi
