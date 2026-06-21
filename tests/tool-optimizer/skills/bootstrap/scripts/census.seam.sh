#!/bin/sh
# WHAT: Seam test for census.sh — feeds fixed path-list fixtures and asserts the exact
#       bucket counts for representative repo shapes.
# WHY:  census.sh is a pure function (path list -> counts). These fixtures pin the
#       thresholds the rank seam depends on (the prototype's NOTES left its verdict
#       "fill in after driving it"; these fixtures ARE that recorded verdict). Assertions
#       check exact values, never mere existence, so the test cannot pass vacuously.
# WHEN: Run by the test gate automatically (filename contains "seam"). Requires jq.
# HOW:  POSIX sh only. Builds each fixture path list with shell loops, runs census.sh
#       via TO_PATHS, asserts with jq -er. No git, no host filesystem scan.

set -e

SCRIPT_DIR="$(CDPATH= cd -- "$(dirname "$0")" && pwd)"
SCRIPT_DIR="$(printf '%s' "$SCRIPT_DIR" | sed 's#/tests/tool-optimizer/#/tool-optimizer/#')"
CENSUS="$SCRIPT_DIR/census.sh"
TMP=$(mktemp -d)

fail() { printf 'FAIL: %s\n' "$1" >&2; rm -rf "$TMP"; exit 1; }
# assert <census-file> <jq-bool-expr> <message>
assert() { jq -er "$2" "$1" >/dev/null 2>&1 || fail "$3"; }

# ---- Scenario 1: Java monorepo (60 .java under packages/, 2 build files, .md docs) ----
F="$TMP/java.paths"
{
  i=0; while [ $i -lt 60 ]; do echo "packages/svc/src/main/java/App$i.java"; i=$((i+1)); done
  echo "packages/svc/pom.xml"
  echo "build.gradle"
  i=0; while [ $i -lt 5 ]; do echo "docs/readme$i.md"; i=$((i+1)); done
} > "$F"
TO_PATHS="$F" TO_CENSUS_OUT="$TMP/java.json" "$SCRIPT_DIR/census.sh" || fail "census failed (java)"
assert "$TMP/java.json" '.total_files == 67'      "java: total_files should be 67"
assert "$TMP/java.json" '.total_source == 60'     "java: total_source should be 60"
assert "$TMP/java.json" '.by_lang[0].lang == "java"' "java: top lang should be java"
assert "$TMP/java.json" '.by_lang[0].n == 60'     "java: java count should be 60"
assert "$TMP/java.json" '.security_source == 60'  "java: security_source should be 60"
assert "$TMP/java.json" '(.build_files | length) == 2' "java: should see 2 build files"
assert "$TMP/java.json" '.monorepo == true'       "java: should be monorepo (packages/ + 2 build files)"

# ---- Scenario 2: Docs-only repo (90 .md, 4 .docx, 2 .pdf — NO source) ----
F="$TMP/docs.paths"
{
  i=0; while [ $i -lt 90 ]; do echo "chapter$i.md"; i=$((i+1)); done
  i=0; while [ $i -lt 4 ]; do echo "handouts/slides$i.docx"; i=$((i+1)); done
  i=0; while [ $i -lt 2 ]; do echo "handouts/spec$i.pdf"; i=$((i+1)); done
} > "$F"
TO_PATHS="$F" TO_CENSUS_OUT="$TMP/docs.json" "$SCRIPT_DIR/census.sh" || fail "census failed (docs)"
assert "$TMP/docs.json" '.total_source == 0'   "docs: total_source should be 0"
assert "$TMP/docs.json" '(.by_lang | length) == 0' "docs: by_lang should be empty"
assert "$TMP/docs.json" '.docs == 6'           "docs: should count 6 Office/web docs"
assert "$TMP/docs.json" '.tabular == 0'        "docs: tabular should be 0"
assert "$TMP/docs.json" '.is_global == false'  "docs: is_global should be false (96 files)"

# ---- Scenario 3: Data project (40 .py, 12 .csv, 2 .xlsx, 3 .ipynb) ----
F="$TMP/data.paths"
{
  echo "pyproject.toml"
  i=0; while [ $i -lt 40 ]; do echo "src/mod$i.py"; i=$((i+1)); done
  i=0; while [ $i -lt 12 ]; do echo "data/set$i.csv"; i=$((i+1)); done
  i=0; while [ $i -lt 2 ]; do echo "data/book$i.xlsx"; i=$((i+1)); done
  i=0; while [ $i -lt 3 ]; do echo "notebooks/explore$i.ipynb"; i=$((i+1)); done
} > "$F"
TO_PATHS="$F" TO_CENSUS_OUT="$TMP/data.json" "$SCRIPT_DIR/census.sh" || fail "census failed (data)"
assert "$TMP/data.json" '.total_source == 40' "data: total_source should be 40"
assert "$TMP/data.json" '.tabular == 14'      "data: tabular should be 14 (12 csv + 2 xlsx)"
assert "$TMP/data.json" '.notebooks == 3'     "data: notebooks should be 3"
assert "$TMP/data.json" '.monorepo == false'  "data: single build file -> not monorepo"

# ---- Scenario 4: Tiny repo (5 .py + README.md + pyproject.toml + .gitignore) ----
F="$TMP/tiny.paths"
{
  i=0; while [ $i -lt 5 ]; do echo "util$i.py"; i=$((i+1)); done
  echo "README.md"
  echo "pyproject.toml"
  echo ".gitignore"
} > "$F"
TO_PATHS="$F" TO_CENSUS_OUT="$TMP/tiny.json" "$SCRIPT_DIR/census.sh" || fail "census failed (tiny)"
assert "$TMP/tiny.json" '.total_files == 8'   "tiny: total_files should be 8"
assert "$TMP/tiny.json" '.total_source == 5'  "tiny: total_source should be 5 (.gitignore/.md not source)"
assert "$TMP/tiny.json" '(.build_files | length) == 1' "tiny: 1 build file"
assert "$TMP/tiny.json" '.monorepo == false'  "tiny: not a monorepo"

# ---- Scenario 5: Empty / global (no paths) ----
: > "$TMP/empty.paths"
TO_PATHS="$TMP/empty.paths" TO_CENSUS_OUT="$TMP/empty.json" "$SCRIPT_DIR/census.sh" || fail "census failed (empty)"
assert "$TMP/empty.json" '.is_global == true'      "empty: is_global should be true"
assert "$TMP/empty.json" '.total_files == 0'       "empty: total_files should be 0"
assert "$TMP/empty.json" '(.by_lang | length) == 0' "empty: by_lang should be empty"

# ---- Determinism: two runs over the same fixture are byte-identical ----
TO_PATHS="$TMP/data.paths" TO_CENSUS_OUT="$TMP/det1.json" "$SCRIPT_DIR/census.sh"
TO_PATHS="$TMP/data.paths" TO_CENSUS_OUT="$TMP/det2.json" "$SCRIPT_DIR/census.sh"
diff "$TMP/det1.json" "$TMP/det2.json" || fail "census not deterministic (two runs differ)"

rm -rf "$TMP"
echo "census seam ok"
