#!/bin/sh
# WHAT: Seam test for render.sh — verifies that the render script produces a deterministic
#       markdown block from a synthetic inventory, includes available tools + Policy, and
#       appends a staleness note when the inventory is older than 30 days.
# WHY:  render.sh is the batch step that populates the cached .local.md read by the hot-path
#       SessionStart hook. This seam gates correctness: right tools listed, policy present,
#       staleness note appears/absent at the exact 30-day boundary, two runs are byte-identical.
# WHEN: Run by the CI gate (any *.seam.sh under tool-optimizer/).
# HOW:  Writes a synthetic inventory JSON to a temp dir (two available tools, two missing,
#       a pinned detectedAt). Runs render.sh with TO_INVENTORY, TO_NOW, and TO_RENDER_OUT
#       all pointing into the temp dir. Asserts via grep (no jq on the rendered markdown).
#       POSIX sh only — no bash arrays, no [[ ]], no bashisms.

set -e

SCRIPT_DIR="$(CDPATH= cd -- "$(dirname "$0")" && pwd)"
SCRIPT_DIR="$(printf '%s' "$SCRIPT_DIR" | sed 's#/tests/tool-optimizer/#/tool-optimizer/#')"
RENDER_SH="$SCRIPT_DIR/render.sh"

# Capture sh path before any PATH manipulation.
SH_BIN=$(command -v sh)

tmpdir=$(mktemp -d)
trap 'rm -rf "$tmpdir"' EXIT

fail=0

# --- write synthetic inventory JSON ---
# Two available: ripgrep, ast-grep
# Two missing:   duckdb, semgrep
# detectedAt is pinned for determinism.

INVENTORY="$tmpdir/tool-optimizer.local.json"
cat > "$INVENTORY" <<'ENDJSON'
{
  "ast-grep": { "available": true, "version": "0.31.0", "path": "/usr/local/bin/ast-grep", "category": "structural", "installHint": "brew install ast-grep" },
  "duckdb": { "available": false, "version": "", "path": "", "category": "tabular", "installHint": "brew install duckdb" },
  "ripgrep": { "available": true, "version": "14.1.0", "path": "/usr/local/bin/rg", "category": "text", "installHint": "brew install ripgrep" },
  "semgrep": { "available": false, "version": "", "path": "", "category": "structural", "installHint": "brew install semgrep" },
  "detectedAt": "2026-01-01T00:00:00Z"
}
ENDJSON

# ============================================================================
# Case 1: FRESH — TO_NOW only 5 days after detectedAt
#   Expect: available tool names in block, Policy text present, NO staleness note
# ============================================================================
OUT_FRESH="$tmpdir/fresh.md"
FRESH_NOW="2026-01-06T00:00:00Z"

TO_INVENTORY="$INVENTORY" TO_NOW="$FRESH_NOW" TO_RENDER_OUT="$OUT_FRESH" \
  "$SH_BIN" "$RENDER_SH" || { echo "FAIL [fresh]: render.sh exited non-zero"; fail=1; }

# Available tools must appear.
grep -q "ripgrep" "$OUT_FRESH" \
  || { echo "FAIL [fresh]: 'ripgrep' not in rendered block"; fail=1; }
grep -q "ast-grep" "$OUT_FRESH" \
  || { echo "FAIL [fresh]: 'ast-grep' not in rendered block"; fail=1; }

# Missing tools must NOT appear in the tool list section.
# We check the "Available tools" section specifically by ensuring duckdb and semgrep
# are absent from the bullet list lines (lines starting with "- ").
if grep -E '^- duckdb$' "$OUT_FRESH" >/dev/null 2>&1; then
  echo "FAIL [fresh]: 'duckdb' (missing tool) appears in available tools list"
  fail=1
fi
if grep -E '^- semgrep$' "$OUT_FRESH" >/dev/null 2>&1; then
  echo "FAIL [fresh]: 'semgrep' (missing tool) appears in available tools list"
  fail=1
fi

# Policy text must be present.
grep -q "Local tool policy (token-first)" "$OUT_FRESH" \
  || { echo "FAIL [fresh]: policy title not in rendered block"; fail=1; }
grep -q "novelty is never the reason" "$OUT_FRESH" \
  || { echo "FAIL [fresh]: policy tail not in rendered block"; fail=1; }

# Self-report trigger clause must be present on the RENDERED (hot-path) block too.
grep -q "report-error" "$OUT_FRESH" \
  || { echo "FAIL [fresh]: self-report trigger clause not in rendered block"; fail=1; }
grep -q "rodrigorjsf/ast-grep-for-agents" "$OUT_FRESH" \
  || { echo "FAIL [fresh]: upstream tracker not in rendered self-report clause"; fail=1; }

# Staleness note must be ABSENT (only 5 days old).
if grep -q "re-run the bootstrap to refresh" "$OUT_FRESH"; then
  echo "FAIL [fresh]: staleness note present but inventory is only 5 days old"
  fail=1
fi

echo "  [ok] fresh case: tools + policy present, no staleness note"

# ============================================================================
# Case 2: STALE — TO_NOW 35 days after detectedAt (> 30 days)
#   Expect: available tools present, Policy present, staleness note present
# ============================================================================
OUT_STALE="$tmpdir/stale.md"
STALE_NOW="2026-02-05T00:00:00Z"

TO_INVENTORY="$INVENTORY" TO_NOW="$STALE_NOW" TO_RENDER_OUT="$OUT_STALE" \
  "$SH_BIN" "$RENDER_SH" || { echo "FAIL [stale]: render.sh exited non-zero"; fail=1; }

grep -q "ripgrep" "$OUT_STALE" \
  || { echo "FAIL [stale]: 'ripgrep' not in rendered block"; fail=1; }
grep -q "Local tool policy (token-first)" "$OUT_STALE" \
  || { echo "FAIL [stale]: policy title not in rendered block"; fail=1; }

# Staleness note must be PRESENT (35 days old).
grep -q "re-run the bootstrap to refresh" "$OUT_STALE" \
  || { echo "FAIL [stale]: staleness note absent but inventory is 35 days old"; fail=1; }

echo "  [ok] stale case: staleness note present"

# ============================================================================
# Case 3: BOUNDARY — TO_NOW exactly 30 days after detectedAt (NOT stale yet)
#   30*86400 seconds = 2592000; "greater than" means 30 days exactly is NOT stale.
# ============================================================================
OUT_BOUNDARY="$tmpdir/boundary.md"
BOUNDARY_NOW="2026-01-31T00:00:00Z"

TO_INVENTORY="$INVENTORY" TO_NOW="$BOUNDARY_NOW" TO_RENDER_OUT="$OUT_BOUNDARY" \
  "$SH_BIN" "$RENDER_SH" || { echo "FAIL [boundary]: render.sh exited non-zero"; fail=1; }

if grep -q "re-run the bootstrap to refresh" "$OUT_BOUNDARY"; then
  echo "FAIL [boundary]: staleness note present at exactly 30 days (should be absent)"
  fail=1
fi

echo "  [ok] boundary case: exactly 30 days → no staleness note"

# ============================================================================
# Case 4: DETERMINISM — two runs with same TO_NOW → byte-identical output
# ============================================================================
OUT_DET1="$tmpdir/det1.md"
OUT_DET2="$tmpdir/det2.md"
DET_NOW="2026-01-06T12:00:00Z"

TO_INVENTORY="$INVENTORY" TO_NOW="$DET_NOW" TO_RENDER_OUT="$OUT_DET1" \
  "$SH_BIN" "$RENDER_SH" || { echo "FAIL [determinism]: first run exited non-zero"; fail=1; }
TO_INVENTORY="$INVENTORY" TO_NOW="$DET_NOW" TO_RENDER_OUT="$OUT_DET2" \
  "$SH_BIN" "$RENDER_SH" || { echo "FAIL [determinism]: second run exited non-zero"; fail=1; }

diff "$OUT_DET1" "$OUT_DET2" \
  || { echo "FAIL [determinism]: two runs with same TO_NOW produced different output"; fail=1; }

echo "  [ok] determinism: two runs with same TO_NOW are byte-identical"

# ============================================================================
# Case 5: PRESERVE FRONTMATTER — a pre-existing .local.md with YAML frontmatter (user
#   settings) must keep that frontmatter; only the body block is regenerated.
# ============================================================================
OUT_FM="$tmpdir/with-frontmatter.md"
printf '%s\n' '---' 'enabled: true' 'mcp: on' '---' '## old stale body to be replaced' > "$OUT_FM"

TO_INVENTORY="$INVENTORY" TO_NOW="2026-01-06T00:00:00Z" TO_RENDER_OUT="$OUT_FM" \
  "$SH_BIN" "$RENDER_SH" || { echo "FAIL [frontmatter]: render.sh exited non-zero"; fail=1; }

# Frontmatter settings survive.
grep -q '^mcp: on$' "$OUT_FM" \
  || { echo "FAIL [frontmatter]: 'mcp: on' setting was churned by re-render"; fail=1; }
grep -q '^enabled: true$' "$OUT_FM" \
  || { echo "FAIL [frontmatter]: 'enabled: true' setting was churned by re-render"; fail=1; }
# Body is regenerated (policy present) and the stale body is gone.
grep -q "Local tool policy (token-first)" "$OUT_FM" \
  || { echo "FAIL [frontmatter]: body block not regenerated"; fail=1; }
if grep -q "old stale body to be replaced" "$OUT_FM"; then
  echo "FAIL [frontmatter]: stale body survived instead of being regenerated"; fail=1
fi

echo "  [ok] frontmatter case: settings preserved, body regenerated"

# ============================================================================
# Case 6: STATE-DIR CONTRACT — TO_STATE_DIR umbrella drives BOTH the inventory
#   read path AND the render output path; granular vars still win.
#   The cases above pin both via TO_INVENTORY/TO_RENDER_OUT, which does NOT
#   exercise the defaults. Here both granular vars are UNSET and the script runs
#   from a tmp CWD, so the derived defaults are observable and the worktree is
#   never polluted.
#     - TO_STATE_DIR unset   -> reads .claude/...json, writes .claude/...md (backward-compat).
#     - TO_STATE_DIR=.cursor -> reads .cursor/...json, writes .cursor/...md  (Cursor port).
# ============================================================================
SD_CWD="$tmpdir/sd-cwd"

# --- default (umbrella unset): seed inventory under .claude, expect .md under .claude ---
mkdir -p "$SD_CWD/.claude"
cp "$INVENTORY" "$SD_CWD/.claude/tool-optimizer.local.json"
( cd "$SD_CWD" && env -u TO_INVENTORY -u TO_RENDER_OUT -u TO_STATE_DIR TO_NOW="2026-01-06T00:00:00Z" \
    "$SH_BIN" "$RENDER_SH" ) \
  || { echo "FAIL [state-dir/default]: render.sh exited non-zero with TO_STATE_DIR unset"; fail=1; }
if [ ! -f "$SD_CWD/.claude/tool-optimizer.local.md" ]; then
  echo "FAIL [state-dir/default]: render output must land under .claude/ (backward-compat)"; fail=1
elif ! grep -q "Local tool policy (token-first)" "$SD_CWD/.claude/tool-optimizer.local.md"; then
  echo "FAIL [state-dir/default]: rendered .claude block missing policy"; fail=1
else
  echo "  [ok] state-dir default: reads/writes under .claude with umbrella unset"
fi

# --- umbrella=.cursor: seed inventory under .cursor, expect .md under .cursor ---
mkdir -p "$SD_CWD/.cursor"
cp "$INVENTORY" "$SD_CWD/.cursor/tool-optimizer.local.json"
( cd "$SD_CWD" && env -u TO_INVENTORY -u TO_RENDER_OUT TO_STATE_DIR=".cursor" TO_NOW="2026-01-06T00:00:00Z" \
    "$SH_BIN" "$RENDER_SH" ) \
  || { echo "FAIL [state-dir/cursor]: render.sh exited non-zero with TO_STATE_DIR=.cursor"; fail=1; }
if [ ! -f "$SD_CWD/.cursor/tool-optimizer.local.md" ]; then
  echo "FAIL [state-dir/cursor]: render output must land under .cursor/ when TO_STATE_DIR=.cursor"; fail=1
elif ! grep -q "Local tool policy (token-first)" "$SD_CWD/.cursor/tool-optimizer.local.md"; then
  echo "FAIL [state-dir/cursor]: rendered .cursor block missing policy"; fail=1
else
  echo "  [ok] state-dir cursor: reads/writes under .cursor with TO_STATE_DIR=.cursor"
fi

# --- granular wins: explicit TO_RENDER_OUT beats the umbrella ---
GRAN_MD="$tmpdir/granular-render.md"
( cd "$SD_CWD" && env -u TO_INVENTORY TO_STATE_DIR=".cursor" TO_RENDER_OUT="$GRAN_MD" TO_NOW="2026-01-06T00:00:00Z" \
    "$SH_BIN" "$RENDER_SH" ) \
  || { echo "FAIL [state-dir/granular]: render.sh exited non-zero with TO_RENDER_OUT + TO_STATE_DIR"; fail=1; }
if [ ! -f "$GRAN_MD" ]; then
  echo "FAIL [state-dir/granular]: granular TO_RENDER_OUT must win over TO_STATE_DIR umbrella"; fail=1
else
  echo "  [ok] state-dir granular: explicit TO_RENDER_OUT wins over umbrella"
fi

# ============================================================================
# Summary
# ============================================================================
if [ "$fail" -eq 0 ]; then
  echo "render seam ok"
  exit 0
else
  echo "render seam FAILED"
  exit 1
fi
