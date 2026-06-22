#!/bin/sh
# WHAT: Seam test for resolve.sh — verifies key-by-key config resolution.
# WHY:  resolve.sh is the canonical implementation of the two-scope merge rule.
#       This seam gates correctness: project keys win over global, absent project keys
#       fall back to global, project-only keys are included, missing-file cases are
#       handled gracefully (treated as {}). A passing seam proves the merge contract.
# WHEN: Run by the CI/test gate automatically (filename contains "seam").
# HOW:  Writes fixture JSON files to a temp dir — constructed to exercise all three
#       resolution cases. Runs resolve.sh with GLOBAL_CONFIG/PROJECT_CONFIG pointed at
#       the fixtures. Asserts resolved values with jq. Also tests missing-file behavior.
#       Cleans up temp dir on exit. POSIX sh only — no bash arrays, no [[ ]], no bashisms.

set -e

SCRIPT_DIR="$(CDPATH= cd -- "$(dirname "$0")" && pwd)"
SCRIPT_DIR="$(printf '%s' "$SCRIPT_DIR" | sed 's#/tests/tool-optimizer/#/tool-optimizer/#')"
RESOLVE_SH="$SCRIPT_DIR/resolve.sh"

SH_BIN=$(command -v sh)
JQ_BIN=$(command -v jq 2>/dev/null) || true

tmpdir=$(mktemp -d)
trap 'rm -rf "$tmpdir"' EXIT

fail() {
  printf 'FAIL: %s\n' "$1" >&2
  exit 1
}

# AC4: Settings resolve key-by-key across Project and Global scopes
#   (project[key] ?? global[key]).
#   Cases 1–5 cover: shared key (project wins), global-only key (falls through),
#   project-only key (included), missing project file (no error), missing both ({}),
#   stdout mode, and the TO_STATE_DIR umbrella contract for both .claude and .cursor.

# ============================================================================
# Fixtures — constructed to exercise all three resolution cases:
#   (a) key in BOTH with DIFFERENT values → project value wins
#   (b) key ONLY in global               → global value falls through
#   (c) key ONLY in project              → project value included
# ============================================================================

GLOBAL_FILE="$tmpdir/global.json"
PROJECT_FILE="$tmpdir/project.json"

# Global config: has "shared_key" (case a), "global_only_key" (case b).
cat > "$GLOBAL_FILE" <<'ENDJSON'
{
  "shared_key": "global_value",
  "global_only_key": "only_in_global"
}
ENDJSON

# Project config: has "shared_key" (case a, different value), "project_only_key" (case c).
cat > "$PROJECT_FILE" <<'ENDJSON'
{
  "shared_key": "project_value",
  "project_only_key": "only_in_project"
}
ENDJSON

# ============================================================================
# Case 1: Both scopes present — full three-way assertion
# ============================================================================
RESOLVED_FILE="$tmpdir/resolved.json"

GLOBAL_CONFIG="$GLOBAL_FILE" PROJECT_CONFIG="$PROJECT_FILE" TO_RESOLVE_OUT="$RESOLVED_FILE" \
  "$SH_BIN" "$RESOLVE_SH" \
  || fail "resolve.sh exited non-zero with both scopes present"

# (a) key in BOTH: project value wins
if [ -n "$JQ_BIN" ]; then
  "$JQ_BIN" -er '.shared_key == "project_value"' "$RESOLVED_FILE" >/dev/null \
    || fail "(a) shared_key: expected project_value, got global_value"
else
  grep -q '"shared_key": "project_value"' "$RESOLVED_FILE" \
    || fail "(a) shared_key: expected project_value (grep fallback)"
fi

# (b) key ONLY in global: falls through to resolved output
if [ -n "$JQ_BIN" ]; then
  "$JQ_BIN" -er '.global_only_key == "only_in_global"' "$RESOLVED_FILE" >/dev/null \
    || fail "(b) global_only_key: expected only_in_global (global fallback)"
else
  grep -q '"global_only_key": "only_in_global"' "$RESOLVED_FILE" \
    || fail "(b) global_only_key: expected only_in_global (grep fallback)"
fi

# (c) key ONLY in project: included in resolved output
if [ -n "$JQ_BIN" ]; then
  "$JQ_BIN" -er '.project_only_key == "only_in_project"' "$RESOLVED_FILE" >/dev/null \
    || fail "(c) project_only_key: expected only_in_project (project-only key)"
else
  grep -q '"project_only_key": "only_in_project"' "$RESOLVED_FILE" \
    || fail "(c) project_only_key: expected only_in_project (grep fallback)"
fi

echo "  [ok] both scopes: project wins on shared_key, global falls through, project-only included"

# ============================================================================
# Case 2: Project missing — returns global only (no error)
# ============================================================================
RESOLVED_GLOBAL_ONLY="$tmpdir/resolved_global_only.json"
MISSING_PROJECT="$tmpdir/no_such_project.json"

GLOBAL_CONFIG="$GLOBAL_FILE" PROJECT_CONFIG="$MISSING_PROJECT" TO_RESOLVE_OUT="$RESOLVED_GLOBAL_ONLY" \
  "$SH_BIN" "$RESOLVE_SH" \
  || fail "resolve.sh exited non-zero when project file missing"

if [ -n "$JQ_BIN" ]; then
  "$JQ_BIN" -er '.global_only_key == "only_in_global"' "$RESOLVED_GLOBAL_ONLY" >/dev/null \
    || fail "project-missing: global_only_key not present in result"
  # shared_key should be global value since project is missing
  "$JQ_BIN" -er '.shared_key == "global_value"' "$RESOLVED_GLOBAL_ONLY" >/dev/null \
    || fail "project-missing: shared_key should be global_value when project absent"
else
  grep -q '"global_only_key": "only_in_global"' "$RESOLVED_GLOBAL_ONLY" \
    || fail "project-missing: global_only_key not present (grep fallback)"
fi

echo "  [ok] project missing: returns global config without error"

# ============================================================================
# Case 3: Neither scope present — returns {} (no error)
# ============================================================================
RESOLVED_EMPTY="$tmpdir/resolved_empty.json"
MISSING_GLOBAL="$tmpdir/no_such_global.json"

GLOBAL_CONFIG="$MISSING_GLOBAL" PROJECT_CONFIG="$MISSING_PROJECT" TO_RESOLVE_OUT="$RESOLVED_EMPTY" \
  "$SH_BIN" "$RESOLVE_SH" \
  || fail "resolve.sh exited non-zero when both files missing"

# Result should be valid JSON and equal to {} (empty object)
if [ -n "$JQ_BIN" ]; then
  "$JQ_BIN" empty "$RESOLVED_EMPTY" >/dev/null \
    || fail "neither-present: result is not valid JSON"
  result_keys=$("$JQ_BIN" 'keys | length' "$RESOLVED_EMPTY")
  if [ "$result_keys" != "0" ]; then
    fail "neither-present: expected empty object {}, got $result_keys keys"
  fi
else
  grep -q '{}' "$RESOLVED_EMPTY" \
    || fail "neither-present: result is not {} (grep fallback)"
fi

echo "  [ok] neither scope present: returns {} without error"

# ============================================================================
# Case 4: stdout mode (no TO_RESOLVE_OUT) — output goes to stdout
# ============================================================================
STDOUT_RESULT=$(GLOBAL_CONFIG="$GLOBAL_FILE" PROJECT_CONFIG="$PROJECT_FILE" \
  "$SH_BIN" "$RESOLVE_SH") \
  || fail "resolve.sh exited non-zero in stdout mode"

if [ -n "$JQ_BIN" ]; then
  echo "$STDOUT_RESULT" | "$JQ_BIN" -er '.shared_key == "project_value"' >/dev/null \
    || fail "stdout mode: shared_key should be project_value"
else
  echo "$STDOUT_RESULT" | grep -q '"shared_key": "project_value"' \
    || fail "stdout mode: shared_key should be project_value (grep fallback)"
fi

echo "  [ok] stdout mode: output written to stdout when TO_RESOLVE_OUT unset"

# ============================================================================
# Case 5: STATE-DIR CONTRACT — TO_STATE_DIR drives the PROJECT_CONFIG default
#   (the global scope is HOME-rooted and intentionally NOT state-dir'd). The
#   cases above pin PROJECT_CONFIG, which does NOT exercise the default. Here
#   PROJECT_CONFIG is UNSET and resolve runs from a tmp CWD, so the derived
#   default is observable and the worktree is never polluted. GLOBAL_CONFIG is
#   pointed at a tmp nonexistent path so the test never reads the real $HOME.
#     - TO_STATE_DIR unset   -> reads .claude/tool-optimizer.local.json (backward-compat).
#     - TO_STATE_DIR=.cursor -> reads .cursor/tool-optimizer.local.json  (Cursor port).
# ============================================================================
SD_CWD="$tmpdir/sd-cwd"
NO_GLOBAL="$tmpdir/no_such_global_sd.json"   # nonexistent -> resolve treats as {}

# --- default (umbrella unset): seed project config under .claude ---
mkdir -p "$SD_CWD/.claude"
cat > "$SD_CWD/.claude/tool-optimizer.local.json" <<'ENDJSON'
{ "claude_default_marker": "from_claude_default" }
ENDJSON
SD_DEFAULT=$( cd "$SD_CWD" && env -u PROJECT_CONFIG -u TO_STATE_DIR GLOBAL_CONFIG="$NO_GLOBAL" \
  "$SH_BIN" "$RESOLVE_SH" ) \
  || fail "state-dir/default: resolve.sh exited non-zero with TO_STATE_DIR unset"
if [ -n "$JQ_BIN" ]; then
  printf '%s' "$SD_DEFAULT" | "$JQ_BIN" -er '.claude_default_marker == "from_claude_default"' >/dev/null \
    || fail "state-dir/default: PROJECT_CONFIG default must resolve under .claude"
else
  printf '%s' "$SD_DEFAULT" | grep -q '"claude_default_marker": "from_claude_default"' \
    || fail "state-dir/default: PROJECT_CONFIG default must resolve under .claude (grep fallback)"
fi
echo "  [ok] state-dir default: PROJECT_CONFIG resolves under .claude with umbrella unset"

# --- umbrella=.cursor: seed project config under .cursor ---
mkdir -p "$SD_CWD/.cursor"
cat > "$SD_CWD/.cursor/tool-optimizer.local.json" <<'ENDJSON'
{ "cursor_default_marker": "from_cursor_default" }
ENDJSON
SD_CURSOR=$( cd "$SD_CWD" && env -u PROJECT_CONFIG TO_STATE_DIR=".cursor" GLOBAL_CONFIG="$NO_GLOBAL" \
  "$SH_BIN" "$RESOLVE_SH" ) \
  || fail "state-dir/cursor: resolve.sh exited non-zero with TO_STATE_DIR=.cursor"
if [ -n "$JQ_BIN" ]; then
  printf '%s' "$SD_CURSOR" | "$JQ_BIN" -er '.cursor_default_marker == "from_cursor_default"' >/dev/null \
    || fail "state-dir/cursor: PROJECT_CONFIG default must resolve under .cursor"
else
  printf '%s' "$SD_CURSOR" | grep -q '"cursor_default_marker": "from_cursor_default"' \
    || fail "state-dir/cursor: PROJECT_CONFIG default must resolve under .cursor (grep fallback)"
fi
echo "  [ok] state-dir cursor: PROJECT_CONFIG resolves under .cursor with TO_STATE_DIR=.cursor"

# --- granular wins: explicit PROJECT_CONFIG beats the umbrella ---
cat > "$tmpdir/granular_project.json" <<'ENDJSON'
{ "granular_marker": "from_granular" }
ENDJSON
SD_GRAN=$( cd "$SD_CWD" && env TO_STATE_DIR=".cursor" PROJECT_CONFIG="$tmpdir/granular_project.json" \
  GLOBAL_CONFIG="$NO_GLOBAL" "$SH_BIN" "$RESOLVE_SH" ) \
  || fail "state-dir/granular: resolve.sh exited non-zero with PROJECT_CONFIG + TO_STATE_DIR"
if [ -n "$JQ_BIN" ]; then
  printf '%s' "$SD_GRAN" | "$JQ_BIN" -er '.granular_marker == "from_granular"' >/dev/null \
    || fail "state-dir/granular: explicit PROJECT_CONFIG must win over TO_STATE_DIR umbrella"
  printf '%s' "$SD_GRAN" | "$JQ_BIN" -er 'has("cursor_default_marker") | not' >/dev/null \
    || fail "state-dir/granular: umbrella default must NOT leak when PROJECT_CONFIG is explicit"
else
  printf '%s' "$SD_GRAN" | grep -q '"granular_marker": "from_granular"' \
    || fail "state-dir/granular: explicit PROJECT_CONFIG must win (grep fallback)"
fi
echo "  [ok] state-dir granular: explicit PROJECT_CONFIG wins over umbrella"

echo "resolve seam ok"
exit 0
