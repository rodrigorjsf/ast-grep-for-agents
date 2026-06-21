#!/bin/sh
# WHAT: Seam test for detect.sh — verifies tool detection under a controlled stub PATH.
# WHY:  Ensures the probe correctly marks stubbed binaries as Available (with version)
#       and absent binaries as Missing, and that output is valid JSON and byte-identical
#       on re-runs when the timestamp is pinned.
# WHEN: Run by the CI/test gate automatically (filename contains "seam").
# HOW:  Creates fake stub binaries for a subset of tools in a temp dir, then runs
#       detect.sh under a FULLY ISOLATED PATH consisting of ONLY that stub dir (plus
#       symlinks to the handful of shell utilities detect.sh itself needs). This means
#       tools NOT stubbed genuinely resolve to nothing, so the Missing assertions are
#       real — real host installs of rg/duckdb/ctags cannot leak in.
#       POSIX sh only — no bash arrays, no [[ ]], no bashisms.

set -e

SCRIPT_DIR="$(dirname "$0")"
DETECT="$SCRIPT_DIR/detect.sh"

# Capture absolute path of sh and jq BEFORE we alter PATH.
SH_BIN=$(command -v sh)
JQ_BIN=""
JQ_BIN=$(command -v jq 2>/dev/null) || true

fail() {
  printf 'FAIL: %s\n' "$1" >&2
  rm -rf "$TMPDIR_TEST"
  exit 1
}

# Create isolated temp directory.
TMPDIR_TEST=$(mktemp -d)
STUB_BIN="$TMPDIR_TEST/bin"
mkdir -p "$STUB_BIN"

# Create a stub for ripgrep (binary name: rg).
cat > "$STUB_BIN/rg" <<'EOF'
#!/bin/sh
echo "ripgrep 14.1.0 (rev abc123)"
EOF
chmod +x "$STUB_BIN/rg"

# Create a stub for ast-grep (binary name: ast-grep).
cat > "$STUB_BIN/ast-grep" <<'EOF'
#!/bin/sh
echo "ast-grep 0.31.0"
EOF
chmod +x "$STUB_BIN/ast-grep"

# Create a stub for duckdb.
cat > "$STUB_BIN/duckdb" <<'EOF'
#!/bin/sh
echo "v1.2.0 dev"
EOF
chmod +x "$STUB_BIN/duckdb"

# All other probed tools (semgrep, repomix, files-to-prompt, markitdown, qsv, rtk, ctags)
# are intentionally absent from STUB_BIN.
#
# CRITICAL — full PATH isolation. detect.sh runs with PATH set to ONLY the stub dir, so
# any probed tool not stubbed genuinely resolves to nothing (available=false), regardless
# of what is installed on the host. To keep detect.sh runnable under that isolated PATH,
# symlink the handful of shell utilities it needs into the stub dir BEFORE restricting
# PATH (resolved here under the real PATH). cat/sed/head/mkdir/dirname are load-bearing;
# grep/date are included for safety (ctags branch / unpinned timestamp).
for _util in cat sed head mkdir dirname grep date; do
  _src=$(command -v "$_util" 2>/dev/null) || true
  if [ -n "$_src" ]; then
    ln -s "$_src" "$STUB_BIN/$_util"
  fi
done
SEAM_PATH="$STUB_BIN"

# Pin the output path and timestamp for determinism.
OUT1="$TMPDIR_TEST/out1.json"
OUT2="$TMPDIR_TEST/out2.json"
PINNED_NOW="2026-01-01T00:00:00Z"

# Run detect.sh with the controlled PATH and pinned timestamp.
PATH="$SEAM_PATH" TO_OUTPUT="$OUT1" TO_NOW="$PINNED_NOW" "$SH_BIN" "$DETECT" \
  || fail "detect.sh exited non-zero on first run"

# Run again for determinism check.
PATH="$SEAM_PATH" TO_OUTPUT="$OUT2" TO_NOW="$PINNED_NOW" "$SH_BIN" "$DETECT" \
  || fail "detect.sh exited non-zero on second run"

# --- Assert: output is valid JSON ---
if [ -n "$JQ_BIN" ]; then
  "$JQ_BIN" empty "$OUT1" || fail "output is not valid JSON"
else
  grep -q '"ast-grep"' "$OUT1" || fail "missing ast-grep key (JSON check fallback)"
fi

# --- Assert: stubbed tools are Available with non-empty version ---
# The exact version values prove the sed parsing extracts the version-like token:
#   "ripgrep 14.1.0 (rev abc123)" -> "14.1.0", "ast-grep 0.31.0" -> "0.31.0",
#   "v1.2.0 dev" -> "1.2.0".
if [ -n "$JQ_BIN" ]; then
  "$JQ_BIN" -er '."ripgrep".available == true' "$OUT1" >/dev/null \
    || fail "ripgrep should be available (it is in STUB_BIN)"
  "$JQ_BIN" -er '."ripgrep".version == "14.1.0"' "$OUT1" >/dev/null \
    || fail "ripgrep version should parse to 14.1.0"
  "$JQ_BIN" -er '."ast-grep".available == true' "$OUT1" >/dev/null \
    || fail "ast-grep should be available (it is in STUB_BIN)"
  "$JQ_BIN" -er '."ast-grep".version == "0.31.0"' "$OUT1" >/dev/null \
    || fail "ast-grep version should parse to 0.31.0"
  "$JQ_BIN" -er '."duckdb".available == true' "$OUT1" >/dev/null \
    || fail "duckdb should be available (it is in STUB_BIN)"
  "$JQ_BIN" -er '."duckdb".version == "1.2.0"' "$OUT1" >/dev/null \
    || fail "duckdb version should parse to 1.2.0"
else
  grep -q '"ripgrep": { "available": true' "$OUT1" \
    || fail "ripgrep should be available (grep fallback)"
  grep -q '"ast-grep": { "available": true' "$OUT1" \
    || fail "ast-grep should be available (grep fallback)"
fi

# --- Assert: non-stubbed tools are genuinely Missing (PATH isolation proof) ---
# These 7 tools are NOT in STUB_BIN, and PATH contains only STUB_BIN, so they must
# resolve to nothing. This assertion is the whole point of the seam test; it was
# vacuous when PATH merely prepended the stub dir to the real PATH.
if [ -n "$JQ_BIN" ]; then
  for tool in "semgrep" "repomix" "files-to-prompt" "markitdown" "qsv" "rtk" "universal-ctags"; do
    "$JQ_BIN" -er ".\"$tool\".available == false" "$OUT1" >/dev/null \
      || fail "$tool should be Missing (not in isolated stub PATH)"
    "$JQ_BIN" -er ".\"$tool\".version == \"\"" "$OUT1" >/dev/null \
      || fail "$tool version should be empty when Missing"
  done
else
  for tool in "semgrep" "repomix" "files-to-prompt" "markitdown" "qsv" "rtk" "universal-ctags"; do
    grep -q "\"$tool\": { \"available\": false" "$OUT1" \
      || fail "$tool should be Missing (grep fallback)"
  done
fi

# --- Assert: all 10 tool keys are present in the JSON ---
if [ -n "$JQ_BIN" ]; then
  for tool in "ast-grep" "duckdb" "files-to-prompt" "markitdown" "qsv" "repomix" "ripgrep" "rtk" "semgrep" "universal-ctags"; do
    "$JQ_BIN" -er ".\"$tool\" | type == \"object\"" "$OUT1" >/dev/null \
      || fail "missing tool key: $tool"
  done
fi

# --- Assert: category and installHint fields are present on stubbed tools ---
if [ -n "$JQ_BIN" ]; then
  "$JQ_BIN" -er '."ripgrep".category == "text"' "$OUT1" >/dev/null \
    || fail "ripgrep category should be text"
  "$JQ_BIN" -er '."ast-grep".category == "structural"' "$OUT1" >/dev/null \
    || fail "ast-grep category should be structural"
  "$JQ_BIN" -er '."universal-ctags".category == "persistence-or-codenav"' "$OUT1" >/dev/null \
    || fail "universal-ctags category should be persistence-or-codenav"
  "$JQ_BIN" -er '."ripgrep".installHint != ""' "$OUT1" >/dev/null \
    || fail "ripgrep installHint should be non-empty"
fi

# --- Assert: detectedAt is present and matches the pinned value ---
if [ -n "$JQ_BIN" ]; then
  "$JQ_BIN" -er ".detectedAt == \"$PINNED_NOW\"" "$OUT1" >/dev/null \
    || fail "detectedAt should match pinned value"
else
  grep -q "\"$PINNED_NOW\"" "$OUT1" || fail "detectedAt not found (grep fallback)"
fi

# --- Assert: determinism — two runs with the same TO_NOW produce byte-identical output ---
diff "$OUT1" "$OUT2" \
  || fail "two runs with same TO_NOW produced different output (not deterministic)"

# Cleanup.
rm -rf "$TMPDIR_TEST"

echo "detect seam ok"
