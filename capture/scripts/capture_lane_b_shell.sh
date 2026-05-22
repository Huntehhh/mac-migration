#!/usr/bin/env bash
# capture_lane_b_shell.sh
# Lane B -- Shell + PATH + Custom scripts
#
# Sub-modules:
#   B1/B2  Dotfile refs (~/.zshrc, ~/.zprofile, ~/.zshenv, ~/.bashrc, ~/.bash_profile)
#   B3     /etc/paths + /etc/paths.d (sudo)
#   B4     ~/bin + ~/.local/bin custom scripts
#   B5     /etc/hosts + /etc/sudoers.d (sudo)
#
# Opt-out keys:
#   opt_outs.lane_b
#   opt_outs.lane_b.{dotfile_refs,system_paths,home_bin,system_files}

set -euo pipefail

BUNDLE="${BUNDLE:-$HOME/migration-bundle}"
DRY_RUN="${DRY_RUN:-0}"
FORCE="${FORCE:-0}"

for arg in "$@"; do
  case "$arg" in
    --force)   FORCE=1 ;;
    --dry-run) DRY_RUN=1 ;;
    *) echo "capture_lane_b_shell.sh: unknown arg: $arg" >&2; exit 2 ;;
  esac
done

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SUB_SKILL_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
SKILL_DIR="$(cd "$SUB_SKILL_DIR/.." && pwd)"
AUDIT="$SCRIPT_DIR/audit_log.sh"
DONE_HELPER="$SKILL_DIR/scripts/lane_done_marker.sh"
LANE_ID="lane-b-shell"
MANIFEST="$BUNDLE/manifest.json"

if [ ! -f "$MANIFEST" ]; then
  echo "capture_lane_b_shell.sh: $MANIFEST not found -- run inventory first." >&2
  exit 3
fi

mkdir -p "$BUNDLE/dotfiles-refs" "$BUNDLE/manifests" "$BUNDLE/.done" "$BUNDLE/dry-run-report"

opt_out_lane() { jq -e ".opt_outs.lane_b == true" "$MANIFEST" >/dev/null 2>&1; }
opt_out_sub()  { jq -e ".opt_outs.lane_b.$1 == true" "$MANIFEST" >/dev/null 2>&1; }

if opt_out_lane; then
  "$AUDIT" "$LANE_ID" lane skip "manifest.json opts out of entire Lane B"
  [ "$DRY_RUN" != "1" ] && bash "$DONE_HELPER" set "$LANE_ID"
  exit 0
fi

if [ "$FORCE" != "1" ] && bash "$DONE_HELPER" check "$LANE_ID" >/dev/null 2>&1; then
  "$AUDIT" "$LANE_ID" lane skip "Already done -- use --force to re-capture"
  exit 0
fi

"$AUDIT" "$LANE_ID" lane start "Lane B -- Shell + PATH (dry_run=$DRY_RUN, force=$FORCE)"

# --- B1/B2. Dotfile refs -------------------------------------------------

if ! opt_out_sub dotfile_refs; then
  dotfile_count=0
  for f in ~/.zshrc ~/.zprofile ~/.zshenv ~/.bashrc ~/.bash_profile ~/.profile ~/.inputrc ~/.tmux.conf ~/.gitignore_global; do
    if [ -f "$f" ]; then
      if [ "$DRY_RUN" = "1" ]; then
        dotfile_count=$((dotfile_count + 1))
      else
        cp -p "$f" "$BUNDLE/dotfiles-refs/$(basename "$f")"
        "$AUDIT" "$LANE_ID" dotfile_refs ok "Copied $(basename "$f")"
      fi
    fi
  done
  if [ "$DRY_RUN" = "1" ]; then
    "$AUDIT" "$LANE_ID" dotfile_refs info "Would copy $dotfile_count rc files"
  fi
  "$AUDIT" "$LANE_ID" dotfile_refs info "path_helper reorders PATH from /etc/zprofile -- review on new Mac"
else
  "$AUDIT" "$LANE_ID" dotfile_refs skip "Opted out via manifest"
fi

# --- B3. /etc/paths + /etc/paths.d ---------------------------------------

if ! opt_out_sub system_paths; then
  if [ "$DRY_RUN" = "1" ]; then
    "$AUDIT" "$LANE_ID" system_paths info "Would sudo-copy /etc/paths and /etc/paths.d"
  else
    "$AUDIT" "$LANE_ID" system_paths start "Copying /etc/paths and /etc/paths.d via sudo"
    if sudo cp /etc/paths "$BUNDLE/manifests/etc-paths.txt" 2>/dev/null; then
      "$AUDIT" "$LANE_ID" system_paths ok "Wrote manifests/etc-paths.txt"
    else
      "$AUDIT" "$LANE_ID" system_paths fail "sudo cp /etc/paths failed"
      exit 20
    fi
    if sudo cp -R /etc/paths.d "$BUNDLE/manifests/etc-paths.d" 2>/dev/null; then
      "$AUDIT" "$LANE_ID" system_paths ok "Wrote manifests/etc-paths.d/"
    else
      "$AUDIT" "$LANE_ID" system_paths fail "sudo cp /etc/paths.d failed"
      exit 21
    fi
  fi
else
  "$AUDIT" "$LANE_ID" system_paths skip "Opted out via manifest"
fi

# --- B4. ~/bin and ~/.local/bin ------------------------------------------

if ! opt_out_sub home_bin; then
  for d in "$HOME/bin" "$HOME/.local/bin"; do
    if [ -d "$d" ]; then
      base="$(basename "$d")"
      target="$BUNDLE/home-${base}"
      [ "$base" = "bin" ] && target="$BUNDLE/home-bin"
      [ "$base" = "bin" ] && [ "$d" = "$HOME/.local/bin" ] && target="$BUNDLE/home-local-bin"
      # disambiguate ~/bin vs ~/.local/bin
      case "$d" in
        "$HOME/bin")        target="$BUNDLE/home-bin" ;;
        "$HOME/.local/bin") target="$BUNDLE/home-local-bin" ;;
      esac
      if [ "$DRY_RUN" = "1" ]; then
        file_count="$(find "$d" -maxdepth 1 -type f 2>/dev/null | wc -l | tr -d ' ')"
        "$AUDIT" "$LANE_ID" home_bin info "Would copy $d ($file_count files)"
      else
        "$AUDIT" "$LANE_ID" home_bin start "Copying $d"
        mkdir -p "$target"
        if rsync -av "$d/" "$target/" >/dev/null 2>&1; then
          "$AUDIT" "$LANE_ID" home_bin ok "Wrote $target/"
        else
          "$AUDIT" "$LANE_ID" home_bin warn "rsync of $d returned non-zero"
        fi
      fi
    fi
  done
  "$AUDIT" "$LANE_ID" home_bin info "Long-term: commit these to chezmoi dotfile repo"
else
  "$AUDIT" "$LANE_ID" home_bin skip "Opted out via manifest"
fi

# --- B5. /etc/hosts + /etc/sudoers.d -------------------------------------

if ! opt_out_sub system_files; then
  if [ "$DRY_RUN" = "1" ]; then
    "$AUDIT" "$LANE_ID" system_files info "Would sudo-copy /etc/hosts and /etc/sudoers.d"
  else
    "$AUDIT" "$LANE_ID" system_files start "Copying /etc/hosts and /etc/sudoers.d via sudo"
    if sudo cp /etc/hosts "$BUNDLE/manifests/etc-hosts" 2>/dev/null; then
      "$AUDIT" "$LANE_ID" system_files ok "Wrote manifests/etc-hosts"
    else
      "$AUDIT" "$LANE_ID" system_files fail "sudo cp /etc/hosts failed"
      exit 22
    fi
    mkdir -p "$BUNDLE/manifests/sudoers.d"
    if sudo cp -r /etc/sudoers.d/. "$BUNDLE/manifests/sudoers.d/" 2>/dev/null; then
      "$AUDIT" "$LANE_ID" system_files ok "Wrote manifests/sudoers.d/"
      "$AUDIT" "$LANE_ID" system_files info "Restore: run 'visudo -c -f <file>' on each before activating"
    else
      "$AUDIT" "$LANE_ID" system_files warn "/etc/sudoers.d copy returned non-zero (may be empty)"
    fi
  fi
else
  "$AUDIT" "$LANE_ID" system_files skip "Opted out via manifest"
fi

# --- done marker ---------------------------------------------------------

if [ "$DRY_RUN" = "1" ]; then
  "$AUDIT" "$LANE_ID" lane info "Dry-run complete; no .done marker written"
else
  bash "$DONE_HELPER" set "$LANE_ID"
  "$AUDIT" "$LANE_ID" lane ok "Lane B capture complete"
fi
