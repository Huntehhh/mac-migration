#!/usr/bin/env bash
# diff_state.sh — main diff engine for mac-migration Phase 4.
#
# Modes:
#   diff_state.sh                  Verify mode: compare $BUNDLE/manifest.json -> current Mac state.
#                                  Writes $BUNDLE/DIFF-REPORT.md.
#   diff_state.sh --baseline       Drift mode: compare ~/.mac-migration/baseline.json -> current Mac state.
#                                  Writes ~/.mac-migration/drift-report-YYYY-MM-DD.md.
#   diff_state.sh --write-baseline Snapshot current Mac state to ~/.mac-migration/baseline.json.
#                                  Used to establish a drift-detection reference.
#
# Environment:
#   BUNDLE   Bundle path (default: $HOME/migration-bundle)
#   BASELINE Baseline path (default: $HOME/.mac-migration/baseline.json)
#
# Exit codes:
#   0  all lanes pass
#   1  one or more lanes have missing items
#   2  manifest/baseline not found or unparseable
#   3  invalid invocation

set -euo pipefail

# --- Defaults --------------------------------------------------------------
BUNDLE="${BUNDLE:-$HOME/migration-bundle}"
BASELINE="${BASELINE:-$HOME/.mac-migration/baseline.json}"
MODE="verify"  # verify | drift | write-baseline

# --- Arg parse -------------------------------------------------------------
while [ $# -gt 0 ]; do
  case "$1" in
    --baseline)       MODE="drift"; shift ;;
    --write-baseline) MODE="write-baseline"; shift ;;
    --bundle)         BUNDLE="${2:?--bundle requires path}"; shift 2 ;;
    --baseline-path)  BASELINE="${2:?--baseline-path requires path}"; shift 2 ;;
    -h|--help)
      sed -n '2,30p' "$0"
      exit 0
      ;;
    *)
      echo "diff_state.sh: unknown flag: $1" >&2
      exit 3
      ;;
  esac
done

# --- Tool guard ------------------------------------------------------------
command -v jq >/dev/null 2>&1 || { echo "diff_state.sh: jq is required (brew install jq)" >&2; exit 2; }

# --- Helpers ---------------------------------------------------------------
now_iso() { date -u +"%Y-%m-%dT%H:%M:%SZ"; }
today()   { date +"%Y-%m-%d"; }

# scan_current_state -> emits the in-memory state JSON for the current Mac.
# Mirrors the schema capture/inventory produces. Each lane block is best-effort:
# tools missing -> lane gets "captured: false" with a "skipped_reason".
scan_current_state() {
  local tmp
  tmp=$(mktemp)
  {
    echo '{'
    echo '  "captured_at": "'"$(now_iso)"'",'

    # macOS version
    local sw_raw sw_major
    sw_raw=$(sw_vers -productVersion 2>/dev/null || echo "unknown")
    sw_major="${sw_raw%%.*}"
    echo '  "macos_version": {"major": '"${sw_major:-0}"', "raw": "'"$sw_raw"'"},'

    echo '  "lanes": {'

    # ----- Lane A -----
    echo -n '    "A": '
    if command -v brew >/dev/null 2>&1; then
      local f c
      f=$(brew list --formula 2>/dev/null | jq -R . | jq -s . 2>/dev/null || echo '[]')
      c=$(brew list --cask    2>/dev/null | jq -R . | jq -s . 2>/dev/null || echo '[]')
      printf '{"captured": true, "brewfile_formulae": %s, "brewfile_casks": %s}' "$f" "$c"
    else
      printf '{"captured": false, "skipped_reason": "brew not installed"}'
    fi
    echo ','

    # ----- Lane B -----
    echo -n '    "B": '
    local home_bin_count=0 path_d_count=0
    [ -d "$HOME/bin" ] && home_bin_count=$(find "$HOME/bin" -type f 2>/dev/null | wc -l | tr -d ' ')
    [ -d /etc/paths.d ] && path_d_count=$(find /etc/paths.d -type f 2>/dev/null | wc -l | tr -d ' ')
    printf '{"captured": true, "home_bin_count": %s, "paths_d_count": %s}' "$home_bin_count" "$path_d_count"
    echo ','

    # ----- Lane C -----
    echo -n '    "C": '
    if [ -f "$HOME/.tool-versions" ]; then
      local tv
      tv=$(awk 'NF >= 2 && !/^#/ {printf "\"%s\":\"%s\",", $1, $2}' "$HOME/.tool-versions" | sed 's/,$//')
      printf '{"captured": true, "tool_versions": {%s}}' "$tv"
    else
      printf '{"captured": false, "skipped_reason": "no ~/.tool-versions"}'
    fi
    echo ','

    # ----- Lane D -----
    echo -n '    "D": '
    local font_count=0
    [ -d "$HOME/Library/Fonts" ] && font_count=$(find "$HOME/Library/Fonts" -type f \( -name '*.ttf' -o -name '*.otf' -o -name '*.woff*' \) 2>/dev/null | wc -l | tr -d ' ')
    printf '{"captured": true, "user_font_count": %s}' "$font_count"
    echo ','

    # ----- Lane E -----
    echo -n '    "E": '
    local browsers=()
    for b in "Google Chrome" "Brave Browser" "Firefox" "Safari" "Arc" "Microsoft Edge"; do
      [ -d "/Applications/$b.app" ] && browsers+=("\"$b\"")
    done
    local b_json
    b_json=$(IFS=,; echo "${browsers[*]:-}")
    printf '{"captured": true, "browsers": [%s]}' "$b_json"
    echo ','

    # ----- Lane F -----
    echo -n '    "F": '
    local ides=() ext_count=0
    command -v code   >/dev/null 2>&1 && ides+=("\"vscode\"")
    command -v cursor >/dev/null 2>&1 && ides+=("\"cursor\"")
    [ -d "/Applications/Zed.app" ] && ides+=("\"zed\"")
    command -v code >/dev/null 2>&1 && ext_count=$(code --list-extensions 2>/dev/null | wc -l | tr -d ' ')
    local f_json
    f_json=$(IFS=,; echo "${ides[*]:-}")
    printf '{"captured": true, "ides": [%s], "vscode_extension_count": %s}' "$f_json" "$ext_count"
    echo ','

    # ----- Lane G -----
    echo -n '    "G": '
    local dbs=() docker_ctx=0
    command -v pg_isready >/dev/null 2>&1 && pg_isready -q -U postgres 2>/dev/null && dbs+=("\"postgres\"")
    command -v redis-cli  >/dev/null 2>&1 && redis-cli ping 2>/dev/null | grep -q PONG && dbs+=("\"redis\"")
    command -v docker     >/dev/null 2>&1 && docker_ctx=$(docker context ls --format '{{.Name}}' 2>/dev/null | wc -l | tr -d ' ')
    local g_json
    g_json=$(IFS=,; echo "${dbs[*]:-}")
    printf '{"captured": true, "databases": [%s], "docker_context_count": %s}' "$g_json" "$docker_ctx"
    echo ','

    # ----- Lane H -----
    echo -n '    "H": '
    local la_count=0 brew_started=()
    [ -d "$HOME/Library/LaunchAgents" ] && la_count=$(find "$HOME/Library/LaunchAgents" -name '*.plist' -type f 2>/dev/null | wc -l | tr -d ' ')
    if command -v brew >/dev/null 2>&1; then
      while IFS= read -r svc; do
        brew_started+=("\"$svc\"")
      done < <(brew services list 2>/dev/null | awk '$2=="started" {print $1}')
    fi
    local h_json
    h_json=$(IFS=,; echo "${brew_started[*]:-}")
    printf '{"captured": true, "user_launchagent_count": %s, "brew_services_started": [%s]}' "$la_count" "$h_json"
    echo ','

    # ----- Lane I -----
    echo -n '    "I": '
    local has_gitconfig=false has_ssh=false has_gpg=false
    [ -f "$HOME/.gitconfig" ]    && has_gitconfig=true
    [ -d "$HOME/.ssh" ]          && has_ssh=true
    [ -d "$HOME/.gnupg" ]        && has_gpg=true
    printf '{"captured": true, "has_gitconfig": %s, "has_ssh": %s, "has_gpg": %s}' "$has_gitconfig" "$has_ssh" "$has_gpg"
    echo ''

    echo '  }'
    echo '}'
  } > "$tmp"

  # Validate that what we wrote is actually JSON before returning it.
  if ! jq empty "$tmp" 2>/dev/null; then
    echo "diff_state.sh: internal error — generated state is invalid JSON" >&2
    cat "$tmp" >&2
    rm -f "$tmp"
    exit 2
  fi

  cat "$tmp"
  rm -f "$tmp"
}

# compare_lane <lane-letter> <reference-json> <current-json>
# Prints a markdown section for the lane. Sets global $LANE_FAIL=1 on any missing.
compare_lane() {
  local lane="$1" ref="$2" cur="$3"

  local ref_lane cur_lane
  ref_lane=$(jq ".lanes.$lane // {}" <<<"$ref")
  cur_lane=$(jq ".lanes.$lane // {}" <<<"$cur")

  local ref_captured cur_captured
  ref_captured=$(jq -r '.captured // false' <<<"$ref_lane")
  cur_captured=$(jq -r '.captured // false' <<<"$cur_lane")

  echo "### Lane $lane"
  echo ""

  if [ "$ref_captured" != "true" ]; then
    echo "- Reference: not captured (skipped at capture time)."
    echo ""
    return
  fi

  if [ "$cur_captured" != "true" ]; then
    local reason
    reason=$(jq -r '.skipped_reason // "unknown"' <<<"$cur_lane")
    echo "- Status: FAIL — lane present in reference but not detected on current Mac ($reason)."
    LANE_FAIL=1
    echo ""
    return
  fi

  # Per-lane delta logic. Keep it lane-specific and concrete.
  case "$lane" in
    A)
      local r_f c_f r_c c_c missing_f missing_c
      r_f=$(jq -r '.brewfile_formulae // [] | .[]' <<<"$ref_lane" | sort -u)
      c_f=$(jq -r '.brewfile_formulae // [] | .[]' <<<"$cur_lane" | sort -u)
      r_c=$(jq -r '.brewfile_casks    // [] | .[]' <<<"$ref_lane" | sort -u)
      c_c=$(jq -r '.brewfile_casks    // [] | .[]' <<<"$cur_lane" | sort -u)
      missing_f=$(comm -23 <(echo "$r_f") <(echo "$c_f") | grep -v '^$' || true)
      missing_c=$(comm -23 <(echo "$r_c") <(echo "$c_c") | grep -v '^$' || true)
      if [ -z "$missing_f" ] && [ -z "$missing_c" ]; then
        echo "- Status: PASS"
      else
        echo "- Status: FAIL"
        [ -n "$missing_f" ] && { echo "- Missing formulae:"; echo "$missing_f" | sed 's/^/    - /'; }
        [ -n "$missing_c" ] && { echo "- Missing casks:";    echo "$missing_c" | sed 's/^/    - /'; }
        echo "- Remediation: \`brew bundle --file=$BUNDLE/Brewfile\`"
        LANE_FAIL=1
      fi
      ;;
    B)
      local r_hb c_hb r_pd c_pd
      r_hb=$(jq -r '.home_bin_count // 0' <<<"$ref_lane")
      c_hb=$(jq -r '.home_bin_count // 0' <<<"$cur_lane")
      r_pd=$(jq -r '.paths_d_count // 0'  <<<"$ref_lane")
      c_pd=$(jq -r '.paths_d_count // 0'  <<<"$cur_lane")
      if [ "$r_hb" -le "$c_hb" ] && [ "$r_pd" -le "$c_pd" ]; then
        echo "- Status: PASS (~/bin: $c_hb/$r_hb, /etc/paths.d: $c_pd/$r_pd)"
      else
        echo "- Status: FAIL (~/bin: $c_hb/$r_hb, /etc/paths.d: $c_pd/$r_pd)"
        echo "- Remediation: rsync \`$BUNDLE/home-bin/\` -> \`~/bin/\` and \`$BUNDLE/manifests/etc-paths.d/\` -> \`/etc/paths.d/\`"
        LANE_FAIL=1
      fi
      ;;
    C)
      local r_keys missing
      r_keys=$(jq -r '.tool_versions // {} | keys[]' <<<"$ref_lane")
      missing=""
      while read -r k; do
        [ -z "$k" ] && continue
        local r_v c_v
        r_v=$(jq -r ".tool_versions[\"$k\"] // \"\"" <<<"$ref_lane")
        c_v=$(jq -r ".tool_versions[\"$k\"] // \"\"" <<<"$cur_lane")
        if [ -z "$c_v" ]; then
          missing="${missing}    - $k (expected $r_v, missing)"$'\n'
        elif [ "${r_v%%.*}" != "${c_v%%.*}" ]; then
          missing="${missing}    - $k (expected major ${r_v%%.*}, got major ${c_v%%.*})"$'\n'
        fi
      done <<<"$r_keys"
      if [ -z "$missing" ]; then
        echo "- Status: PASS"
      else
        echo "- Status: FAIL — tool-version mismatches:"
        printf '%s' "$missing"
        echo "- Remediation: \`mise install\` from $BUNDLE/manifests/.tool-versions"
        LANE_FAIL=1
      fi
      ;;
    D)
      local r c diff
      r=$(jq -r '.user_font_count // 0' <<<"$ref_lane")
      c=$(jq -r '.user_font_count // 0' <<<"$cur_lane")
      diff=$(( r > c ? r - c : c - r ))
      if [ "$diff" -le 5 ]; then
        echo "- Status: PASS (fonts $c/$r, delta $diff)"
      else
        echo "- Status: FAIL (fonts $c/$r, delta $diff)"
        echo "- Remediation: rsync \`$BUNDLE/fonts/\` -> \`~/Library/Fonts/\`"
        LANE_FAIL=1
      fi
      ;;
    E)
      local r_b c_b missing
      r_b=$(jq -r '.browsers // [] | .[]' <<<"$ref_lane" | sort -u)
      c_b=$(jq -r '.browsers // [] | .[]' <<<"$cur_lane" | sort -u)
      missing=$(comm -23 <(echo "$r_b") <(echo "$c_b") | grep -v '^$' || true)
      if [ -z "$missing" ]; then
        echo "- Status: PASS"
      else
        echo "- Status: FAIL — browsers not installed:"
        echo "$missing" | sed 's/^/    - /'
        echo "- Remediation: re-run \`brew bundle\` (browsers ship as casks)"
        LANE_FAIL=1
      fi
      ;;
    F)
      local r_i c_i missing r_x c_x diff
      r_i=$(jq -r '.ides // [] | .[]' <<<"$ref_lane" | sort -u)
      c_i=$(jq -r '.ides // [] | .[]' <<<"$cur_lane" | sort -u)
      missing=$(comm -23 <(echo "$r_i") <(echo "$c_i") | grep -v '^$' || true)
      r_x=$(jq -r '.vscode_extension_count // 0' <<<"$ref_lane")
      c_x=$(jq -r '.vscode_extension_count // 0' <<<"$cur_lane")
      diff=$(( r_x > c_x ? r_x - c_x : c_x - r_x ))
      if [ -z "$missing" ] && [ "$diff" -le 2 ]; then
        echo "- Status: PASS (extensions $c_x/$r_x)"
      else
        echo "- Status: FAIL"
        [ -n "$missing" ] && { echo "- Missing IDEs:"; echo "$missing" | sed 's/^/    - /'; }
        [ "$diff" -gt 2 ] && echo "- VS Code extensions: expected ~$r_x, got $c_x"
        echo "- Remediation: \`cat $BUNDLE/ides/vscode-extensions.txt | xargs -I {} code --install-extension {}\`"
        LANE_FAIL=1
      fi
      ;;
    G)
      local r_d c_d missing r_dc c_dc
      r_d=$(jq -r '.databases // [] | .[]' <<<"$ref_lane" | sort -u)
      c_d=$(jq -r '.databases // [] | .[]' <<<"$cur_lane" | sort -u)
      missing=$(comm -23 <(echo "$r_d") <(echo "$c_d") | grep -v '^$' || true)
      r_dc=$(jq -r '.docker_context_count // 0' <<<"$ref_lane")
      c_dc=$(jq -r '.docker_context_count // 0' <<<"$cur_lane")
      if [ -z "$missing" ] && [ "$c_dc" -ge "$r_dc" ]; then
        echo "- Status: PASS (databases up, docker contexts $c_dc/$r_dc)"
      else
        echo "- Status: FAIL"
        [ -n "$missing" ] && { echo "- Databases not running:"; echo "$missing" | sed 's/^/    - /'; }
        [ "$c_dc" -lt "$r_dc" ] && echo "- Docker contexts: expected $r_dc, got $c_dc"
        echo "- Remediation: \`brew services start <db>\`; \`rsync $BUNDLE/docker/ ~/.docker/\`"
        LANE_FAIL=1
      fi
      ;;
    H)
      local r_la c_la r_bs c_bs missing_bs
      r_la=$(jq -r '.user_launchagent_count // 0' <<<"$ref_lane")
      c_la=$(jq -r '.user_launchagent_count // 0' <<<"$cur_lane")
      r_bs=$(jq -r '.brew_services_started // [] | .[]' <<<"$ref_lane" | sort -u)
      c_bs=$(jq -r '.brew_services_started // [] | .[]' <<<"$cur_lane" | sort -u)
      missing_bs=$(comm -23 <(echo "$r_bs") <(echo "$c_bs") | grep -v '^$' || true)
      if [ "$r_la" -le "$c_la" ] && [ -z "$missing_bs" ]; then
        echo "- Status: PASS (LaunchAgents $c_la/$r_la)"
      else
        echo "- Status: FAIL (LaunchAgents $c_la/$r_la)"
        [ -n "$missing_bs" ] && { echo "- brew services not started:"; echo "$missing_bs" | sed 's/^/    - /'; }
        echo "- Remediation: copy plists from $BUNDLE/launchd/user-LaunchAgents/; \`brew services start <name>\`"
        LANE_FAIL=1
      fi
      ;;
    I)
      local r_g c_g r_s c_s r_p c_p fails=""
      r_g=$(jq -r '.has_gitconfig // false' <<<"$ref_lane"); c_g=$(jq -r '.has_gitconfig // false' <<<"$cur_lane")
      r_s=$(jq -r '.has_ssh       // false' <<<"$ref_lane"); c_s=$(jq -r '.has_ssh       // false' <<<"$cur_lane")
      r_p=$(jq -r '.has_gpg       // false' <<<"$ref_lane"); c_p=$(jq -r '.has_gpg       // false' <<<"$cur_lane")
      [ "$r_g" = true ] && [ "$c_g" != true ] && fails="$fails    - .gitconfig missing"$'\n'
      [ "$r_s" = true ] && [ "$c_s" != true ] && fails="$fails    - ~/.ssh missing"$'\n'
      [ "$r_p" = true ] && [ "$c_p" != true ] && fails="$fails    - ~/.gnupg missing"$'\n'
      if [ -z "$fails" ]; then
        echo "- Status: PASS"
      else
        echo "- Status: FAIL — credential files missing:"
        printf '%s' "$fails"
        echo "- Remediation: unseal $BUNDLE/credentials/credentials.tar.gz.gpg via \`scripts/encrypt_creds.sh unseal\`"
        LANE_FAIL=1
      fi
      ;;
    *)
      echo "- Status: SKIP (no per-lane comparator for lane $lane)"
      ;;
  esac
  echo ""
}

# emit_report <ref-path> <ref-label> <out-path>
emit_report() {
  local ref_path="$1" ref_label="$2" out_path="$3"
  local ref_json cur_json

  ref_json=$(cat "$ref_path")
  cur_json=$(scan_current_state)

  LANE_FAIL=0

  mkdir -p "$(dirname "$out_path")"
  {
    echo "# Mac Migration Diff Report"
    echo ""
    echo "- **Reference:** $ref_label"
    echo "- **Reference captured:** $(jq -r '.captured_at // "unknown"' <<<"$ref_json")"
    echo "- **Reference macOS:** $(jq -r '.macos_version.raw // "unknown"' <<<"$ref_json")"
    echo "- **Current Mac scanned:** $(jq -r '.captured_at' <<<"$cur_json")"
    echo "- **Current macOS:** $(jq -r '.macos_version.raw' <<<"$cur_json")"
    echo ""
    echo "## Per-lane delta"
    echo ""
    for lane in A B C D E F G H I; do
      compare_lane "$lane" "$ref_json" "$cur_json"
    done

    if [ "$LANE_FAIL" -eq 0 ]; then
      echo "## Verdict: ALL LANES PASS"
    else
      echo "## Verdict: ONE OR MORE LANES FAILED — see remediation notes above"
    fi
  } > "$out_path"

  echo "diff_state.sh: report -> $out_path" >&2
  return "$LANE_FAIL"
}

# --- Dispatch --------------------------------------------------------------
case "$MODE" in
  write-baseline)
    mkdir -p "$(dirname "$BASELINE")"
    state=$(scan_current_state)
    echo "$state" > "$BASELINE"
    echo "diff_state.sh: baseline -> $BASELINE" >&2
    exit 0
    ;;

  drift)
    test -f "$BASELINE" || { echo "diff_state.sh: no baseline at $BASELINE — run --write-baseline first" >&2; exit 2; }
    jq empty "$BASELINE" 2>/dev/null || { echo "diff_state.sh: baseline at $BASELINE is invalid JSON" >&2; exit 2; }
    out="$HOME/.mac-migration/drift-report-$(today).md"
    if emit_report "$BASELINE" "drift baseline ($BASELINE)" "$out"; then
      exit 0
    else
      exit 1
    fi
    ;;

  verify)
    test -f "$BUNDLE/manifest.json" || { echo "diff_state.sh: no manifest at $BUNDLE/manifest.json — run capture first" >&2; exit 2; }
    jq empty "$BUNDLE/manifest.json" 2>/dev/null || { echo "diff_state.sh: $BUNDLE/manifest.json is invalid JSON" >&2; exit 2; }
    out="$BUNDLE/DIFF-REPORT.md"
    if emit_report "$BUNDLE/manifest.json" "migration bundle ($BUNDLE/manifest.json)" "$out"; then
      exit 0
    else
      exit 1
    fi
    ;;

  *)
    echo "diff_state.sh: internal error — unknown mode $MODE" >&2
    exit 3
    ;;
esac
