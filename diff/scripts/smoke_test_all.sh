#!/usr/bin/env bash
# smoke_test_all.sh — runs per-lane smoke tests across every captured lane.
#
# Reads $BUNDLE/manifest.json, identifies which lanes were captured (.lanes.<X>.captured == true),
# invokes the parent-level scripts/smoke_test_lane.sh for each, aggregates results.
#
# Writes a structured JSON report to $BUNDLE/SMOKE-TEST-RESULTS.json and a one-line summary per lane
# to stdout.
#
# Environment:
#   BUNDLE             default $HOME/migration-bundle
#   SMOKE_TEST_LANE    path to smoke_test_lane.sh (default: ../../scripts/smoke_test_lane.sh
#                      relative to this script)
#
# Exit codes:
#   0  every lane passed (or was skipped)
#   1  one or more lanes failed
#   2  manifest missing / unparseable
#   3  smoke_test_lane.sh not found

set -euo pipefail

BUNDLE="${BUNDLE:-$HOME/migration-bundle}"
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
SMOKE_TEST_LANE="${SMOKE_TEST_LANE:-$SCRIPT_DIR/../../scripts/smoke_test_lane.sh}"

# --- Guards ----------------------------------------------------------------
test -f "$BUNDLE/manifest.json" || { echo "smoke_test_all.sh: missing $BUNDLE/manifest.json" >&2; exit 2; }
command -v jq >/dev/null 2>&1   || { echo "smoke_test_all.sh: jq is required" >&2; exit 2; }
jq empty "$BUNDLE/manifest.json" 2>/dev/null || { echo "smoke_test_all.sh: manifest is invalid JSON" >&2; exit 2; }
test -x "$SMOKE_TEST_LANE"      || { echo "smoke_test_all.sh: smoke_test_lane.sh not executable at $SMOKE_TEST_LANE" >&2; exit 3; }

# --- Discover captured lanes ----------------------------------------------
# Any lane key whose .captured == true is a candidate. Lane J is always surfaced
# as a checklist-only check (see per-lane-smoke-tests.md J.1).
captured_lanes=$(jq -r '.lanes | to_entries[] | select(.value.captured == true) | .key' "$BUNDLE/manifest.json" | sort)

# Ensure Lane J is included even if not flagged "captured" (its smoke test is the
# MANUAL-STEPS.md existence check).
captured_lanes=$(printf '%s\nJ\n' "$captured_lanes" | sort -u)

# --- Run tests -------------------------------------------------------------
pass_count=0
fail_count=0
skip_count=0
results_json='['
first=true

while IFS= read -r lane; do
  [ -z "$lane" ] && continue
  detail=""
  status="pass"

  # Capture stderr from smoke_test_lane.sh — that's the diagnostic on fail.
  # stdout carries the structured "lane=X test=N status=... detail=..." lines.
  out=$(BUNDLE="$BUNDLE" "$SMOKE_TEST_LANE" "$lane" 2> >(detail_var=$(cat); printf '%s' "$detail_var" >&2; echo "$detail_var" > /tmp/.smoke_stderr.$$) ) || rc=$? && rc=${rc:-0}
  stderr_text=""
  [ -f "/tmp/.smoke_stderr.$$" ] && { stderr_text=$(cat "/tmp/.smoke_stderr.$$"); rm -f "/tmp/.smoke_stderr.$$"; }

  if [ "$rc" -eq 0 ]; then
    if echo "$out" | grep -q 'status=fail'; then
      status="fail"
      detail=$(echo "$out" | grep 'status=fail' | head -1 | sed 's/.*detail=//')
      fail_count=$((fail_count + 1))
    elif echo "$out" | grep -q 'status=pass'; then
      status="pass"
      pass_count=$((pass_count + 1))
    else
      status="skip"
      detail="no tests for lane (or all skipped)"
      skip_count=$((skip_count + 1))
    fi
  else
    status="fail"
    detail="${stderr_text:-smoke_test_lane.sh exited $rc}"
    detail=$(echo "$detail" | head -1)
    fail_count=$((fail_count + 1))
  fi

  printf 'lane=%s status=%s detail=%s\n' "$lane" "$status" "${detail:-ok}"

  # Append to JSON array. jq builds it safely so quotes in $detail can't escape.
  entry=$(jq -n --arg l "$lane" --arg s "$status" --arg d "${detail:-ok}" \
              '{lane: $l, status: $s, detail: $d}')
  if $first; then first=false; else results_json="$results_json,"; fi
  results_json="$results_json$entry"
done <<<"$captured_lanes"

results_json="$results_json]"

# --- Emit JSON --------------------------------------------------------------
report_path="$BUNDLE/SMOKE-TEST-RESULTS.json"
jq -n \
  --arg generated_at "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
  --arg bundle "$BUNDLE" \
  --argjson pass "$pass_count" \
  --argjson fail "$fail_count" \
  --argjson skip "$skip_count" \
  --argjson results "$results_json" \
  '{generated_at: $generated_at, bundle: $bundle, summary: {pass: $pass, fail: $fail, skip: $skip}, lanes: $results}' \
  > "$report_path"

echo "smoke_test_all.sh: pass=$pass_count fail=$fail_count skip=$skip_count -> $report_path"

# --- Exit -----------------------------------------------------------------
[ "$fail_count" -eq 0 ] || exit 1
exit 0
