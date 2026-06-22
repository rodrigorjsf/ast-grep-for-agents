#!/bin/sh
# WHAT: Seam test for nudge.sh — drives the PreToolUse soft-nudge hook directly
#       by piping synthetic hook-input JSON on stdin and asserting the expected
#       JSON output for each trigger/non-trigger case.
# WHY:  Verifies that triggering extensions fire an advisory, non-triggering reads
#       stay silent, the no-repeat deduplication works, the "off" setting suppresses
#       all output, and the hook NEVER blocks a tool call.
# WHEN: Run by the CI gate (any *.seam.sh under tool-optimizer/).
# HOW:  Each case pipes a synthetic JSON payload, captures stdout, and asserts with
#       grep/jq. Uses a temp dir that is cleaned up at exit. POSIX sh only.

set -e

here="$(CDPATH= cd -- "$(dirname "$0")" && pwd)"
here="$(printf '%s' "$here" | sed 's#/tests/tool-optimizer/#/tool-optimizer/#')"
NUDGE_SH="$here/nudge.sh"

# --- temp dir & cleanup -----------------------------------------------------

tmpdir=$(mktemp -d)
trap 'rm -rf "$tmpdir"' EXIT

SEEN="$tmpdir/seen.txt"
BREADCRUMB="$tmpdir/nudge.breadcrumb"
export TO_NUDGE_SEEN="$SEEN"
export TO_NUDGE="soft"
export TO_BREADCRUMB="$BREADCRUMB"

# Make a large temp file (> 100 KB) for the size trigger test
large_file="$tmpdir/bigfile.dat"
dd if=/dev/zero bs=1024 count=110 2>/dev/null > "$large_file"

fail=0

# --- helper -----------------------------------------------------------------

run_nudge() {
  # $1 = tool_name, $2 = file_path (or empty for non-Read tool tests)
  if [ "$1" = "Read" ]; then
    printf '{"tool_name":"Read","tool_input":{"file_path":"%s"}}' "$2"
  else
    printf '{"tool_name":"%s","tool_input":{"file_path":"%s"}}' "$1" "$2"
  fi | sh "$NUDGE_SH"
}

assert_allow() {
  # $1 = output, $2 = test label
  printf '%s' "$1" | jq -e '.hookSpecificOutput.permissionDecision=="allow"' >/dev/null 2>&1 \
    || { echo "FAIL [$2]: output does not contain allow"; fail=1; }
  # Also ensure it is never a block/deny
  if printf '%s' "$1" | grep -qi '"deny"\|"block"'; then
    echo "FAIL [$2]: output contains deny/block"
    fail=1
  fi
}

assert_has_msg() {
  # $1 = output, $2 = label, $3 = expected fragment (optional — just checks msg present)
  if ! printf '%s' "$1" | jq -e '.systemMessage != null and (.systemMessage | length) > 0' >/dev/null 2>&1; then
    echo "FAIL [$2]: expected a systemMessage but got none"
    fail=1
    return
  fi
  if [ -n "$3" ]; then
    if ! printf '%s' "$1" | jq -e --arg frag "$3" '.systemMessage | ascii_downcase | contains($frag)' >/dev/null 2>&1; then
      echo "FAIL [$2]: systemMessage does not contain '$3'"
      fail=1
    fi
  fi
}

assert_no_msg() {
  # $1 = output, $2 = label
  if printf '%s' "$1" | jq -e '.systemMessage != null and (.systemMessage | length) > 0' >/dev/null 2>&1; then
    echo "FAIL [$2]: expected no systemMessage but got one"
    fail=1
  fi
}

# --- reset seen-file between independent tests ------------------------------

reset_seen() { rm -f "$SEEN"; }

# ============================================================================
# Case 1: .csv Read -> allow + systemMessage naming duckdb/qsv
# ============================================================================
reset_seen
out=$(run_nudge "Read" "/data/sales.csv")
assert_allow "$out" "csv-trigger"
assert_has_msg "$out" "csv-trigger" "duckdb"
echo "  [ok] csv trigger"

# ============================================================================
# Case 2: .pdf Read -> allow + systemMessage naming pdf skill
# ============================================================================
reset_seen
out=$(run_nudge "Read" "/docs/report.pdf")
assert_allow "$out" "pdf-trigger"
assert_has_msg "$out" "pdf-trigger" "pdf"
echo "  [ok] pdf trigger"

# ============================================================================
# Case 3: .docx Read -> allow + systemMessage naming markitdown
# ============================================================================
reset_seen
out=$(run_nudge "Read" "/docs/spec.docx")
assert_allow "$out" "docx-trigger"
assert_has_msg "$out" "docx-trigger" "markitdown"
echo "  [ok] docx trigger"

# ============================================================================
# Case 4: large file (>100KB) Read -> allow + systemMessage about targeted read/ripgrep
# ============================================================================
reset_seen
out=$(run_nudge "Read" "$large_file")
assert_allow "$out" "large-file-trigger"
assert_has_msg "$out" "large-file-trigger" ""
echo "  [ok] large file trigger"

# ============================================================================
# Case 5: small .txt Read -> allow + NO systemMessage
# ============================================================================
reset_seen
out=$(run_nudge "Read" "/src/notes.txt")
assert_allow "$out" "txt-no-trigger"
assert_no_msg "$out" "txt-no-trigger"
echo "  [ok] txt no trigger (silent)"

# ============================================================================
# Case 6: non-Read tool -> allow + NO systemMessage
# ============================================================================
reset_seen
out=$(run_nudge "Bash" "/data/sales.csv")
assert_allow "$out" "non-read-tool"
assert_no_msg "$out" "non-read-tool"
echo "  [ok] non-Read tool silent"

# ============================================================================
# Case 7: no-repeat — same .csv path twice -> first fires, second is silent
# ============================================================================
reset_seen
out1=$(run_nudge "Read" "/data/repeat.csv")
out2=$(run_nudge "Read" "/data/repeat.csv")
assert_allow "$out1" "repeat-first"
assert_has_msg "$out1" "repeat-first" "duckdb"
assert_allow "$out2" "repeat-second"
assert_no_msg "$out2" "repeat-second"
echo "  [ok] no-repeat: first fires, second silent"

# ============================================================================
# Case 8: TO_NUDGE=off on .csv -> silent allow
# ============================================================================
reset_seen
out=$(TO_NUDGE=off run_nudge "Read" "/data/sales.csv")
assert_allow "$out" "off-setting"
assert_no_msg "$out" "off-setting"
echo "  [ok] off setting: silent"

# ============================================================================
# Case 9: .tsv, .xlsx, .parquet also trigger
# ============================================================================
reset_seen
for ext in tsv xlsx parquet; do
  reset_seen
  out=$(run_nudge "Read" "/data/file.$ext")
  assert_allow "$out" "$ext-trigger"
  assert_has_msg "$out" "$ext-trigger" "duckdb"
  echo "  [ok] $ext trigger"
done

# ============================================================================
# Case 10: .pptx triggers markitdown
# ============================================================================
reset_seen
out=$(run_nudge "Read" "/slides/deck.pptx")
assert_allow "$out" "pptx-trigger"
assert_has_msg "$out" "pptx-trigger" "markitdown"
echo "  [ok] pptx trigger"

# ============================================================================
# Case 11 (AC1): force a crash → exactly one breadcrumb line with no path
# Crash mechanism: point TO_NUDGE_SEEN at a path under an existing file so
# mkdir -p / append to the seen-file fails when jq runs, but first we force a
# predictable crash by pointing TO_NUDGE_SEEN at a non-writable sub-path of a
# regular file. Under set -e, the mkdir failure propagates as a non-zero exit.
# ============================================================================
crumb="$tmpdir/ac1.breadcrumb"
rm -f "$crumb"
# Create a regular file and try to use a path under it as the seen-file dir.
blocker="$tmpdir/blocker_file"
touch "$blocker"
bad_seen="$blocker/subpath/seen.txt"
out_crash=$(TO_NUDGE_SEEN="$bad_seen" TO_BREADCRUMB="$crumb" \
  sh "$NUDGE_SH" <<'EOFJSON' 2>/dev/null
{"tool_name":"Read","tool_input":{"file_path":"/data/crash.csv"}}
EOFJSON
) || true

# Assert exactly one line was written
if [ ! -f "$crumb" ]; then
  echo "FAIL [ac1-crash]: breadcrumb file was not created"
  fail=1
else
  line_count=$(wc -l < "$crumb" | tr -d ' ')
  if [ "$line_count" -ne 1 ]; then
    echo "FAIL [ac1-crash]: expected exactly 1 breadcrumb line, got $line_count"
    fail=1
  fi

  bc_line=$(cat "$crumb")
  # Assert the line matches artifact-identity#exit-code pattern
  if ! printf '%s' "$bc_line" | grep -qE '^hooks/nudge\.sh#[0-9]+$'; then
    echo "FAIL [ac1-crash]: breadcrumb line does not match 'hooks/nudge.sh#N' pattern: '$bc_line'"
    fail=1
  fi

  # Assert no path/content leak (no '/' or worktree prefix present)
  if printf '%s' "$bc_line" | grep -q '/home\|/tmp\|/var\|Users'; then
    echo "FAIL [ac1-crash]: breadcrumb line contains a filesystem path: '$bc_line'"
    fail=1
  fi
fi
echo "  [ok] ac1 crash: exactly one breadcrumb line with no path"

# ============================================================================
# Case 12 (AC1 inverse): normal happy-path exit writes NO breadcrumb
# ============================================================================
clean_crumb="$tmpdir/clean.breadcrumb"
rm -f "$clean_crumb"
reset_seen
out_clean=$(TO_BREADCRUMB="$clean_crumb" run_nudge "Read" "/src/notes.txt") || true
assert_allow "$out_clean" "happy-no-breadcrumb"
if [ -f "$clean_crumb" ] && [ -s "$clean_crumb" ]; then
  echo "FAIL [happy-no-breadcrumb]: breadcrumb was written on a clean exit"
  fail=1
fi
echo "  [ok] happy-path: no breadcrumb on clean exit"

# ============================================================================
# Cursor soft-deny cases (TO_HARNESS=cursor: fork at cursor-tool-optimizer)
# ============================================================================
# Resolve the Cursor fork path via the same remap the session-start seam uses.
cursor_nudge_sh="$(printf '%s' "$here" | sed 's#/tool-optimizer/#/cursor-tool-optimizer/#')/nudge.sh"

run_cursor_nudge() {
  # $1 = tool_name, $2 = file_path
  if [ "$1" = "Read" ]; then
    printf '{"tool_name":"Read","tool_input":{"file_path":"%s"}}' "$2"
  else
    printf '{"tool_name":"%s","tool_input":{"file_path":"%s"}}' "$1" "$2"
  fi | sh "$cursor_nudge_sh"
}

assert_cursor_deny() {
  # $1 = output, $2 = label, $3 = expected fragment in agent_message (optional)
  # Must be permission: deny + agent_message present + NO hookSpecificOutput
  printf '%s' "$1" | jq -e '.permission=="deny"' >/dev/null 2>&1 \
    || { echo "FAIL [$2]: expected permission:deny but got: $1"; fail=1; return; }
  if ! printf '%s' "$1" | jq -e '.agent_message != null and (.agent_message | length) > 0' >/dev/null 2>&1; then
    echo "FAIL [$2]: expected agent_message but got none"
    fail=1
  fi
  if printf '%s' "$1" | jq -e '.hookSpecificOutput' >/dev/null 2>&1; then
    echo "FAIL [$2]: hookSpecificOutput must NOT be present in Cursor envelope"
    fail=1
  fi
  if [ -n "$3" ]; then
    if ! printf '%s' "$1" | jq -e --arg frag "$3" '.agent_message | ascii_downcase | contains($frag)' >/dev/null 2>&1; then
      echo "FAIL [$2]: agent_message does not contain '$3'"
      fail=1
    fi
  fi
}

assert_cursor_allow() {
  # $1 = output, $2 = label
  # Must be permission: allow + no agent_message + NO hookSpecificOutput
  printf '%s' "$1" | jq -e '.permission=="allow"' >/dev/null 2>&1 \
    || { echo "FAIL [$2]: expected permission:allow but got: $1"; fail=1; return; }
  if printf '%s' "$1" | jq -e '.agent_message != null and (.agent_message | length) > 0' >/dev/null 2>&1; then
    echo "FAIL [$2]: expected no agent_message but got one"
    fail=1
  fi
  if printf '%s' "$1" | jq -e '.hookSpecificOutput' >/dev/null 2>&1; then
    echo "FAIL [$2]: hookSpecificOutput must NOT be present in Cursor envelope"
    fail=1
  fi
}

cursor_tmpdir=$(mktemp -d)
# Re-register the EXIT trap to clean up BOTH temp dirs (a second `trap ... EXIT`
# would override the first, leaking $tmpdir).
trap 'rm -rf "$tmpdir" "$cursor_tmpdir"' EXIT
cursor_seen="$cursor_tmpdir/cursor-seen.txt"
export TO_NUDGE_SEEN="$cursor_seen"
export TO_NUDGE="soft"

# Case C1: first trigger touch → deny + agent_message (soft-deny branch)
reset_seen
out_c1=$(run_cursor_nudge "Read" "/data/report.csv")
assert_cursor_deny "$out_c1" "cursor-csv-first-deny" "duckdb"
echo "  [ok] cursor C1: first trigger touch → deny + agent_message"

# Case C2: same path second touch → allow (once-per-path, no repeat deny)
out_c2=$(run_cursor_nudge "Read" "/data/report.csv")
assert_cursor_allow "$out_c2" "cursor-csv-second-allow"
echo "  [ok] cursor C2: second touch of same path → allow (once-per-path)"

# Case C3: non-trigger (.txt) → silent allow
reset_seen
out_c3=$(run_cursor_nudge "Read" "/src/notes.txt")
assert_cursor_allow "$out_c3" "cursor-txt-no-trigger"
echo "  [ok] cursor C3: non-trigger (.txt) → silent allow"

# Case C4: TO_NUDGE=off on a trigger path → silent allow (nudge disabled)
reset_seen
out_c4=$(TO_NUDGE=off run_cursor_nudge "Read" "/data/sales.xlsx")
assert_cursor_allow "$out_c4" "cursor-off-setting"
echo "  [ok] cursor C4: nudge off → silent allow"

# Validate hooks.json is still valid JSON and contains both hooks
hooks_json="$(printf '%s' "$cursor_nudge_sh" | sed 's#/hooks/nudge\.sh#/hooks.json#')"
jq empty "$hooks_json" 2>/dev/null \
  || { echo "FAIL [cursor-hooks-json]: hooks.json is not valid JSON"; fail=1; }
jq -e '.hooks.sessionStart' "$hooks_json" >/dev/null 2>&1 \
  || { echo "FAIL [cursor-hooks-json]: sessionStart entry missing from hooks.json"; fail=1; }
jq -e '.hooks.preToolUse' "$hooks_json" >/dev/null 2>&1 \
  || { echo "FAIL [cursor-hooks-json]: preToolUse entry missing from hooks.json"; fail=1; }
echo "  [ok] cursor hooks.json: valid JSON with both sessionStart and preToolUse entries"

# ============================================================================
# Summary
# ============================================================================
if [ "$fail" -eq 0 ]; then
  echo "nudge seam ok"
  exit 0
else
  echo "nudge seam FAILED ($fail assertion(s) failed)"
  exit 1
fi
