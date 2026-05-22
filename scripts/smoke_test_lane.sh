#!/usr/bin/env bash
# smoke_test_lane.sh — generic per-lane smoke-test runner.
#
# Usage:
#   smoke_test_lane.sh <lane-letter>
#
# Reads the canonical smoke-test catalog at:
#   ../diff/references/per-lane-smoke-tests.md  (default; relative to this script)
# Extracts the bash blocks under the H2 section "## Lane <letter> —" and executes each
# H3 subsection's first ```bash block. Captures stderr per test as the diagnostic.
#
# Output (stdout, one line per test):
#   lane=<X> test=<N> status=<pass|fail|skip> detail=<message>
#
# Environment:
#   BUNDLE                  default: $HOME/migration-bundle
#   SMOKE_TEST_CATALOG      override the catalog markdown path
#
# Exit codes:
#   0  every test in the lane passed (or was skipped)
#   1  one or more tests failed
#   2  catalog missing / lane has no tests
#   3  invalid invocation

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
SMOKE_TEST_CATALOG="${SMOKE_TEST_CATALOG:-$SCRIPT_DIR/../diff/references/per-lane-smoke-tests.md}"
BUNDLE="${BUNDLE:-$HOME/migration-bundle}"

# --- Arg guard ------------------------------------------------------------
if [ $# -ne 1 ]; then
  echo "smoke_test_lane.sh: usage: $0 <lane-letter>" >&2
  exit 3
fi
LANE="$1"

case "$LANE" in
  [A-Za-z]) ;;
  *) echo "smoke_test_lane.sh: lane must be a single letter (got '$LANE')" >&2; exit 3 ;;
esac
LANE=$(echo "$LANE" | tr '[:lower:]' '[:upper:]')

# --- Locate catalog -------------------------------------------------------
test -f "$SMOKE_TEST_CATALOG" || { echo "smoke_test_lane.sh: catalog not found: $SMOKE_TEST_CATALOG" >&2; exit 2; }

# --- Extract this lane's section ------------------------------------------
# We slice between "## Lane <X> —" and the next H2 / H1.
# The awk pattern uses a literal anchor; we pre-compute it with shell so awk gets a fixed string.
LANE_HEADER="## Lane $LANE"

section=$(awk -v hdr="$LANE_HEADER" '
  BEGIN { in_section = 0 }
  {
    if ($0 ~ "^" hdr) { in_section = 1; next }
    if (in_section && /^## / && $0 !~ "^" hdr) { in_section = 0 }
    if (in_section) print
  }
' "$SMOKE_TEST_CATALOG")

if [ -z "$section" ]; then
  # No tests for this lane is not an error — Lane J is a checklist-only lane in the catalog,
  # and any lane the user didn't capture won't have a section either.
  printf 'lane=%s test=0 status=skip detail=no tests defined for lane\n' "$LANE"
  exit 0
fi

# --- Parse H3 subsections + their first ```bash block ---------------------
# Each H3 starts with "### " and the bash block is fenced with ```bash ... ```.
# We materialize each test to a tempfile so set -e in a sub-block doesn't kill us.
WORK_DIR=$(mktemp -d -t smoke-tests.XXXX)
trap 'rm -rf "$WORK_DIR"' EXIT

# Use awk to split section by H3 boundaries and emit one block per subsection.
# Each block file: $WORK_DIR/test-NN.sh
echo "$section" | awk -v dir="$WORK_DIR" '
  BEGIN { test_num = 0; in_bash = 0; collecting = 0; out = "" }
  /^### / {
    if (out != "" && test_num > 0) {
      # Close previous test
      close(out)
    }
    test_num++
    sub(/^### /, "", $0)
    title = $0
    out = sprintf("%s/test-%02d.sh", dir, test_num)
    titles_out = sprintf("%s/test-%02d.title", dir, test_num)
    print title > titles_out
    close(titles_out)
    in_bash = 0
    collecting = 0
    next
  }
  /^```bash/ {
    if (test_num > 0 && !collecting) {
      in_bash = 1
      collecting = 1
      print "#!/usr/bin/env bash" > out
      print "set -euo pipefail" > out
    }
    next
  }
  /^```/ {
    if (in_bash) {
      in_bash = 0
      close(out)
    }
    next
  }
  {
    if (in_bash) print $0 > out
  }
'

# --- Run each materialized test ------------------------------------------
fail_count=0
test_count=0
overall_status="pass"

shopt -s nullglob
for test_file in "$WORK_DIR"/test-*.sh; do
  test_count=$((test_count + 1))
  test_num=$(basename "$test_file" .sh | sed 's/^test-//')
  title_file="$WORK_DIR/test-$test_num.title"
  title=$(cat "$title_file" 2>/dev/null || echo "untitled")

  # Run the test with BUNDLE exported. Capture stderr for diagnostics; ignore stdout.
  chmod +x "$test_file"
  stderr_file="$WORK_DIR/test-$test_num.err"
  rc=0
  BUNDLE="$BUNDLE" bash "$test_file" >/dev/null 2>"$stderr_file" || rc=$?

  if [ "$rc" -eq 0 ]; then
    printf 'lane=%s test=%s status=pass detail=%s\n' "$LANE" "$test_num" "$title"
  else
    detail=$(head -1 "$stderr_file" 2>/dev/null | tr '\n' ' ' | sed 's/[[:space:]]*$//')
    [ -z "$detail" ] && detail="exited $rc with no diagnostic"
    printf 'lane=%s test=%s status=fail detail=%s\n' "$LANE" "$test_num" "$detail"
    fail_count=$((fail_count + 1))
    overall_status="fail"
  fi
done
shopt -u nullglob

if [ "$test_count" -eq 0 ]; then
  printf 'lane=%s test=0 status=skip detail=no executable tests parsed for lane\n' "$LANE"
  exit 0
fi

# --- Exit ----------------------------------------------------------------
[ "$fail_count" -eq 0 ] || exit 1
exit 0
