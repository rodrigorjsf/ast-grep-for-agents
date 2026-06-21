#!/bin/sh
# WHAT: Seam test for rank.sh — drives census.sh -> rank.sh end to end on fixed repo
#       shapes and asserts the EXACT relevance verdict per tool per scenario.
# WHY:  These verdicts are the validation the prototype's NOTES deferred ("fill in after
#       driving it"). They prove the honesty ADR-0004 asks for: docs-only must NOT push
#       ast-grep; data MUST surface DuckDB; available-but-unneeded must be flagged; the
#       global case must split GEN-core (recommend) from GEN-conditional (show, not push);
#       and EVERY tool gets a verdict (none omitted). Also pins two structural properties:
#       re-running rank is idempotent, and relevance regenerates after a detect overwrite.
# WHEN: Run by the test gate automatically (filename contains "seam"). Requires jq.
# HOW:  POSIX sh. mkinv builds a detect-shaped inventory from a space-separated
#       available-tool set. Fixtures feed census.sh via TO_PATHS; rank.sh via TO_CENSUS +
#       TO_INVENTORY + TO_RANK_OUT. Assertions use jq -er on the merged output.

set -e

SCRIPT_DIR="$(dirname "$0")"
TMP=$(mktemp -d)

fail() { printf 'FAIL: %s\n' "$1" >&2; rm -rf "$TMP"; exit 1; }
# assert <file> <jq-bool-expr> <message>
assert() { jq -er "$2" "$1" >/dev/null 2>&1 || fail "$3"; }

# mkinv "<space-separated available tools>" > inventory.json
# Emits a detect-shaped inventory: every tool present, available flag per the set,
# category matching detect.sh, plus a detectedAt key (a non-tool top-level key).
mkinv() {
  jq -n --arg avail "$1" '
    ($avail | split(" ") | map(select(length > 0))) as $a
    | {
        "ast-grep":        ("ast-grep"        as $t | {available: ($a|index($t)!=null), category:"structural"}),
        "duckdb":          ("duckdb"          as $t | {available: ($a|index($t)!=null), category:"tabular"}),
        "files-to-prompt": ("files-to-prompt" as $t | {available: ($a|index($t)!=null), category:"context-packing"}),
        "markitdown":      ("markitdown"      as $t | {available: ($a|index($t)!=null), category:"doc"}),
        "qsv":             ("qsv"             as $t | {available: ($a|index($t)!=null), category:"tabular"}),
        "repomix":         ("repomix"         as $t | {available: ($a|index($t)!=null), category:"context-packing"}),
        "ripgrep":         ("ripgrep"         as $t | {available: ($a|index($t)!=null), category:"text"}),
        "rtk":             ("rtk"             as $t | {available: ($a|index($t)!=null), category:"persistence-or-codenav"}),
        "semgrep":         ("semgrep"         as $t | {available: ($a|index($t)!=null), category:"structural"}),
        "universal-ctags": ("universal-ctags" as $t | {available: ($a|index($t)!=null), category:"persistence-or-codenav"}),
        "detectedAt": "2026-01-01T00:00:00Z"
      }'
}

# rel <file> <tool> -> prints the relevance string (helper for messages not needed; we assert directly)
# verdict assertion helpers
vrel()  { jq -er ".relevance[] | select(.tool==\"$2\") | .relevance == \"$3\"" "$1" >/dev/null 2>&1 || fail "$4"; }
vflag() { jq -er ".relevance[] | select(.tool==\"$2\") | .$3 == true" "$1" >/dev/null 2>&1 || fail "$4"; }
vnflag(){ jq -er ".relevance[] | select(.tool==\"$2\") | .$3 == false" "$1" >/dev/null 2>&1 || fail "$4"; }

# ===========================================================================
# Scenario A: Java monorepo — ast-grep / repomix / ctags HIGH and recommended
# ===========================================================================
{
  i=0; while [ $i -lt 60 ]; do echo "packages/svc/src/main/java/App$i.java"; i=$((i+1)); done
  echo "packages/svc/pom.xml"; echo "build.gradle"
} > "$TMP/java.paths"
TO_PATHS="$TMP/java.paths" "$SCRIPT_DIR/census.sh" > "$TMP/java.census.json"
mkinv "ripgrep" > "$TMP/java.inv.json"   # only ripgrep available; the rest Missing
TO_CENSUS="$TMP/java.census.json" TO_INVENTORY="$TMP/java.inv.json" TO_RANK_OUT="$TMP/java.out.json" "$SCRIPT_DIR/rank.sh"
vrel  "$TMP/java.out.json" "ast-grep" "HIGH"        "java: ast-grep should be HIGH"
vflag "$TMP/java.out.json" "ast-grep" "recommend"   "java: ast-grep should be recommended (Missing+HIGH)"
vrel  "$TMP/java.out.json" "repomix"  "HIGH"        "java: repomix should be HIGH (monorepo)"
vrel  "$TMP/java.out.json" "universal-ctags" "HIGH" "java: ctags should be HIGH (60 src, big repo)"
vrel  "$TMP/java.out.json" "markitdown" "NA"        "java: markitdown should be NA (no docs)"
vrel  "$TMP/java.out.json" "duckdb"   "NA"          "java: duckdb should be NA (no tabular)"
assert "$TMP/java.out.json" '(.relevance | length) == 10' "java: all 10 tools must get a verdict (none omitted)"

# ===========================================================================
# Scenario B: Docs-only — ast-grep NA + unneeded; markitdown HIGH; honesty both ways
# ===========================================================================
{
  i=0; while [ $i -lt 90 ]; do echo "chapter$i.md"; i=$((i+1)); done
  i=0; while [ $i -lt 4 ]; do echo "handouts/slides$i.docx"; i=$((i+1)); done
} > "$TMP/docs.paths"
TO_PATHS="$TMP/docs.paths" "$SCRIPT_DIR/census.sh" > "$TMP/docs.census.json"
mkinv "ast-grep duckdb ripgrep" > "$TMP/docs.inv.json"  # ast-grep & duckdb available -> should flag unneeded
TO_CENSUS="$TMP/docs.census.json" TO_INVENTORY="$TMP/docs.inv.json" TO_RANK_OUT="$TMP/docs.out.json" "$SCRIPT_DIR/rank.sh"
vrel   "$TMP/docs.out.json" "ast-grep" "NA"        "docs: ast-grep should be NA (0 source)"
vflag  "$TMP/docs.out.json" "ast-grep" "unneeded"  "docs: ast-grep available+NA should be flagged unneeded"
vnflag "$TMP/docs.out.json" "ast-grep" "recommend" "docs: ast-grep must NOT be recommended"
vrel   "$TMP/docs.out.json" "markitdown" "HIGH"    "docs: markitdown should be HIGH (4 docx)"
vflag  "$TMP/docs.out.json" "markitdown" "recommend" "docs: markitdown Missing+HIGH should be recommended"
vrel   "$TMP/docs.out.json" "duckdb" "NA"          "docs: duckdb should be NA"
vflag  "$TMP/docs.out.json" "duckdb" "unneeded"    "docs: duckdb available+NA should be flagged unneeded"

# ===========================================================================
# Scenario C: Data project — DuckDB HIGH heads install order; qsv MED; ast-grep MED
# ===========================================================================
{
  echo "pyproject.toml"
  i=0; while [ $i -lt 40 ]; do echo "src/mod$i.py"; i=$((i+1)); done
  i=0; while [ $i -lt 12 ]; do echo "data/set$i.csv"; i=$((i+1)); done
  i=0; while [ $i -lt 2 ]; do echo "data/book$i.xlsx"; i=$((i+1)); done
} > "$TMP/data.paths"
TO_PATHS="$TMP/data.paths" "$SCRIPT_DIR/census.sh" > "$TMP/data.census.json"
mkinv "" > "$TMP/data.inv.json"  # nothing available
TO_CENSUS="$TMP/data.census.json" TO_INVENTORY="$TMP/data.inv.json" TO_RANK_OUT="$TMP/data.out.json" "$SCRIPT_DIR/rank.sh"
vrel "$TMP/data.out.json" "duckdb"  "HIGH" "data: duckdb should be HIGH (14 tabular)"
vrel "$TMP/data.out.json" "qsv"     "MED"  "data: qsv should be MED"
vrel "$TMP/data.out.json" "ast-grep" "MED" "data: ast-grep should be MED (40 source, 10<=n<50)"
assert "$TMP/data.out.json" '.recommendOrder[0].tool == "duckdb"' "data: duckdb should head the recommend order (HIGH)"

# ===========================================================================
# Scenario D: Tiny repo — everything LOW/NA, empty recommend order (env tools present)
# ===========================================================================
{
  i=0; while [ $i -lt 5 ]; do echo "util$i.py"; i=$((i+1)); done
  echo "README.md"; echo "pyproject.toml"
} > "$TMP/tiny.paths"
TO_PATHS="$TMP/tiny.paths" "$SCRIPT_DIR/census.sh" > "$TMP/tiny.census.json"
mkinv "ripgrep ast-grep rtk" > "$TMP/tiny.inv.json"  # env + ast-grep available
TO_CENSUS="$TMP/tiny.census.json" TO_INVENTORY="$TMP/tiny.inv.json" TO_RANK_OUT="$TMP/tiny.out.json" "$SCRIPT_DIR/rank.sh"
vrel  "$TMP/tiny.out.json" "ast-grep" "LOW"       "tiny: ast-grep should be LOW (5 source)"
vflag "$TMP/tiny.out.json" "ast-grep" "unneeded"  "tiny: ast-grep available+LOW should be flagged unneeded"
assert "$TMP/tiny.out.json" '(.recommendOrder | length) == 0' "tiny: nothing should be recommended (no over-pushing)"

# ===========================================================================
# Scenario E: Global / no codebase — GEN-core recommended, GEN-conditional shown only
# ===========================================================================
: > "$TMP/empty.paths"
TO_PATHS="$TMP/empty.paths" "$SCRIPT_DIR/census.sh" > "$TMP/global.census.json"
mkinv "" > "$TMP/global.inv.json"
TO_CENSUS="$TMP/global.census.json" TO_INVENTORY="$TMP/global.inv.json" TO_RANK_OUT="$TMP/global.out.json" "$SCRIPT_DIR/rank.sh"
vrel  "$TMP/global.out.json" "ast-grep" "GEN-core"        "global: ast-grep should be GEN-core"
vflag "$TMP/global.out.json" "ast-grep" "recommend"       "global: GEN-core ast-grep should be recommended"
vrel  "$TMP/global.out.json" "rtk" "GEN-core"             "global: rtk should be GEN-core (unconditional)"
vrel  "$TMP/global.out.json" "duckdb" "GEN-conditional"   "global: duckdb should be GEN-conditional"
vnflag "$TMP/global.out.json" "duckdb" "recommend"        "global: GEN-conditional duckdb must NOT be recommended"
vrel  "$TMP/global.out.json" "markitdown" "GEN-conditional" "global: markitdown should be GEN-conditional"
assert "$TMP/global.out.json" '.recommendOrder | map(.tool) | index("duckdb") == null'   "global: conditional tools stay out of recommend order"
assert "$TMP/global.out.json" '.recommendOrder | map(.tool) | index("ast-grep") != null' "global: core tools are in recommend order"
assert "$TMP/global.out.json" '(.relevance | length) == 10' "global: all 10 tools still get a verdict"

# ===========================================================================
# Property 1: idempotency — re-ranking an already-ranked inventory keeps 10 tools.
# (census/relevance/recommendOrder top-level keys must NOT be mistaken for tools.)
# ===========================================================================
TO_CENSUS="$TMP/data.census.json" TO_INVENTORY="$TMP/data.out.json" TO_RANK_OUT="$TMP/data.out2.json" "$SCRIPT_DIR/rank.sh"
assert "$TMP/data.out2.json" '(.relevance | length) == 10' "idempotency: re-rank must still yield exactly 10 verdicts"

# ===========================================================================
# Property 2: regenerate on re-detect — a detect overwrite drops relevance; re-rank restores it.
# ===========================================================================
mkinv "duckdb" > "$TMP/redetect.inv.json"   # simulate detect.sh overwriting the file (no relevance block)
assert "$TMP/redetect.inv.json" '.relevance == null' "re-detect: fresh detect output has no relevance block"
TO_CENSUS="$TMP/data.census.json" TO_INVENTORY="$TMP/redetect.inv.json" TO_RANK_OUT="$TMP/redetect.out.json" "$SCRIPT_DIR/rank.sh"
assert "$TMP/redetect.out.json" '.relevance | type == "array"'      "re-detect: relevance must regenerate after detect overwrite"
assert "$TMP/redetect.out.json" '(.relevance | length) == 10'       "re-detect: regenerated relevance covers all 10 tools"
assert "$TMP/redetect.out.json" '.census | type == "object"'        "re-detect: census must be persisted into the inventory"

rm -rf "$TMP"
echo "rank seam ok"
