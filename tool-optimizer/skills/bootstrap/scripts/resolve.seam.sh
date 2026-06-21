#!/bin/sh
# WHAT: Seam test for resolve.sh — verifies key-by-key config resolution (ADR-0001).
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

SCRIPT_DIR="$(dirname "$0")"
RESOLVE_SH="$SCRIPT_DIR/resolve.sh"

SH_BIN=$(command -v sh)
JQ_BIN=$(command -v jq 2>/dev/null) || true

tmpdir=$(mktemp -d)
trap 'rm -rf "$tmpdir"' EXIT

fail() {
  printf 'FAIL: %s\n' "$1" >&2
  exit 1
}

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

echo "resolve seam ok"
exit 0
