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

SCRIPT_DIR="$(dirname "$0")"
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
# Summary
# ============================================================================
if [ "$fail" -eq 0 ]; then
  echo "render seam ok"
  exit 0
else
  echo "render seam FAILED"
  exit 1
fi
