#!/bin/sh
# WHAT: Seam test for file-or-pend.sh — proves the gh-absent fallback guarantee (AC1-AC3).
#       Seeds the full pipeline (sanitize.sh -> struct -> file-or-pend.sh) with denylist
#       strings and asserts that:
#         (a) when gh is MISSING, the struct is appended to the pending file and no upstream
#             side-effect occurs (AC1, AC3),
#         (b) when gh is UNAUTHENTICATED, the same append happens (AC1, AC3),
#         (c) the appended JSONL line is sanitized — no denylist string survived (AC2),
#         (d) when gh IS available and authenticated, the token "gh-available" is returned
#             and nothing is appended to the pending file (AC3: file-or-append, never both).
# WHY:  The pending-report fallback is the lossless path for machines without a usable GitHub
#       CLI. This seam is the inspectable proof that the path is sanitized, lossless, and
#       does not create any partial upstream issue.
# WHEN: Run by the CI gate (any *.seam.sh under tool-optimizer/).
# HOW:  Uses TO_GH_BIN to substitute a fake gh shim (present but exits non-zero on auth status,
#       or simply nonexistent) and TO_FOP_PEND to redirect the pending file to a temp path.
#       No network calls — gh is never invoked for real. POSIX sh only.

set -e

SCRIPT_DIR="$(dirname "$0")"
SANITIZE_SH="$SCRIPT_DIR/sanitize.sh"
FILE_OR_PEND_SH="$SCRIPT_DIR/file-or-pend.sh"
SH_BIN=$(command -v sh)

tmpdir=$(mktemp -d)
trap 'rm -rf "$tmpdir"' EXIT

fail=0

# --- a synthetic plugin manifest so version is deterministic ---
PLUGIN_JSON="$tmpdir/plugin.json"
cat > "$PLUGIN_JSON" <<'ENDJSON'
{ "name": "tool-optimizer", "version": "9.9.9" }
ENDJSON

# --- the SEEDED denylist strings (same shape as sanitize.seam.sh) ---
SEED_HOME="/home/alice"
SEED_USER="alice"
SEED_USERPATH="/home/alice/secret-project/src/main/java/Foo.java"
SEED_SECRET="ghp_AbCdEf0123456789AbCdEf0123456789xZ"
SEED_REPO="alice/secret-project"
SEED_REMOTE="git@github.com:alice/secret-project.git"

# Raw tool error message carries ALL the seeded denylist strings.
RAW_MSG="detect.sh: line 42: jq: command not found
  while probing $SEED_USERPATH
  HOME=$SEED_HOME  GITHUB_TOKEN=$SEED_SECRET
  remote: $SEED_REMOTE  (repo $SEED_REPO)"

ARTIFACT="/home/alice/secret-project/tool-optimizer/skills/bootstrap/scripts/detect.sh"

# Produce a sanitized struct via sanitize.sh (the shared trust boundary).
STRUCT=$(
  TO_ERR_ARTIFACT="$ARTIFACT" \
  TO_ERR_EXIT="127" \
  TO_ERR_MESSAGE="$RAW_MSG" \
  TO_ERR_CLASS="crash" \
  TO_OS_CLASS="wsl" \
  TO_PKG_MGRS="brew,npm,uv" \
  TO_PLUGIN_JSON="$PLUGIN_JSON" \
  TO_SCRUB_HOME="$SEED_HOME" \
  TO_SCRUB_USER="$SEED_USER" \
  TO_SCRUB_REPO="$SEED_REPO" \
  "$SH_BIN" "$SANITIZE_SH"
) || { echo "FAIL [run-sanitize]: sanitize.sh exited non-zero"; fail=1; }

printf '%s' "$STRUCT" | jq empty 2>/dev/null \
  || { echo "FAIL [json-struct]: sanitize.sh output is not valid JSON"; fail=1; }

echo "  [ok] sanitize.sh produced valid JSON struct"

# ============================================================================
# Case 1: gh MISSING — command -v fails → struct appended to pending file
# ============================================================================
PEND_FILE_1="$tmpdir/pend-missing.jsonl"

# Use a name that cannot be a real binary in any $PATH.
TOKEN1=$(
  TO_FOP_STRUCT="$STRUCT" \
  TO_FOP_PEND="$PEND_FILE_1" \
  TO_GH_BIN="__gh_does_not_exist_seam__" \
  "$SH_BIN" "$FILE_OR_PEND_SH"
) || { echo "FAIL [case1-exit]: file-or-pend.sh exited non-zero on gh-missing (must always exit 0)"; fail=1; }

if [ "$TOKEN1" != "pended" ]; then
  echo "FAIL [case1-token]: expected 'pended', got '$TOKEN1'"
  fail=1
else
  echo "  [ok] case1: gh-missing → token 'pended'"
fi

if [ ! -f "$PEND_FILE_1" ]; then
  echo "FAIL [case1-file]: pending file was not created on gh-missing"
  fail=1
elif [ ! -s "$PEND_FILE_1" ]; then
  echo "FAIL [case1-file]: pending file is empty on gh-missing"
  fail=1
else
  echo "  [ok] case1: pending file written"
fi

# The appended line must be valid JSON (compact JSONL).
if [ -f "$PEND_FILE_1" ]; then
  LINE1=$(head -1 "$PEND_FILE_1")
  printf '%s' "$LINE1" | jq empty 2>/dev/null \
    || { echo "FAIL [case1-jsonl]: appended line is not valid JSON"; fail=1; }
  # Must be one line (compact), not multi-line pretty JSON.
  LINES=$(wc -l < "$PEND_FILE_1")
  if [ "$LINES" -ne 1 ]; then
    echo "FAIL [case1-compact]: expected exactly 1 JSONL line, got $LINES"
    fail=1
  else
    echo "  [ok] case1: appended line is compact JSON (1 line)"
  fi
fi

# ============================================================================
# Case 2: gh UNAUTHENTICATED — command -v succeeds but auth status fails
#         Simulate by dropping a fake gh shim that always exits 1.
# ============================================================================
FAKE_GH_DIR="$tmpdir/fake-gh-unauth"
mkdir -p "$FAKE_GH_DIR"
FAKE_GH="$FAKE_GH_DIR/gh"
cat > "$FAKE_GH" <<'ENDSH'
#!/bin/sh
# Fake gh shim: present but always unauthenticated.
# Prints nothing and exits 1 to simulate "gh auth status" failure.
exit 1
ENDSH
chmod +x "$FAKE_GH"

PEND_FILE_2="$tmpdir/pend-unauth.jsonl"

TOKEN2=$(
  TO_FOP_STRUCT="$STRUCT" \
  TO_FOP_PEND="$PEND_FILE_2" \
  TO_GH_BIN="$FAKE_GH" \
  "$SH_BIN" "$FILE_OR_PEND_SH"
) || { echo "FAIL [case2-exit]: file-or-pend.sh exited non-zero on gh-unauthenticated (must always exit 0)"; fail=1; }

if [ "$TOKEN2" != "pended" ]; then
  echo "FAIL [case2-token]: expected 'pended', got '$TOKEN2'"
  fail=1
else
  echo "  [ok] case2: gh-unauthenticated → token 'pended'"
fi

if [ ! -f "$PEND_FILE_2" ]; then
  echo "FAIL [case2-file]: pending file was not created on gh-unauthenticated"
  fail=1
elif [ ! -s "$PEND_FILE_2" ]; then
  echo "FAIL [case2-file]: pending file is empty on gh-unauthenticated"
  fail=1
else
  echo "  [ok] case2: pending file written"
fi

# ============================================================================
# Case 3: DENYLIST ABSENT — prove the appended JSONL line has no denylist strings (AC2)
# ============================================================================
assert_absent_in_pend() {
  # $1 = label, $2 = seeded string that must NOT appear in the pending file
  if [ -f "$PEND_FILE_1" ] && grep -qF "$2" "$PEND_FILE_1" 2>/dev/null; then
    echo "FAIL [denylist]: seeded $1 leaked into the pending file: $2"
    fail=1
  fi
}

assert_absent_in_pend "user path"   "$SEED_USERPATH"
assert_absent_in_pend "home dir"    "$SEED_HOME"
assert_absent_in_pend "fake secret" "$SEED_SECRET"
assert_absent_in_pend "repo slug"   "$SEED_REPO"
assert_absent_in_pend "repo remote" "$SEED_REMOTE"

if [ -f "$PEND_FILE_1" ] && grep -qiw "alice" "$PEND_FILE_1" 2>/dev/null; then
  echo "FAIL [denylist]: seeded username 'alice' leaked into the pending file"
  fail=1
fi

echo "  [ok] no seeded denylist string survived into the pending file (AC2)"

# ============================================================================
# Case 4: gh AVAILABLE and AUTHENTICATED → token "gh-available", no pending write (AC3)
#         Simulate by dropping a fake gh shim that exits 0 on auth status.
# ============================================================================
FAKE_GH_OK_DIR="$tmpdir/fake-gh-ok"
mkdir -p "$FAKE_GH_OK_DIR"
FAKE_GH_OK="$FAKE_GH_OK_DIR/gh"
cat > "$FAKE_GH_OK" <<'ENDSH'
#!/bin/sh
# Fake gh shim: present and authenticated.
# Exits 0 for any subcommand (simulates a working, logged-in gh).
exit 0
ENDSH
chmod +x "$FAKE_GH_OK"

PEND_FILE_4="$tmpdir/pend-should-not-exist.jsonl"

TOKEN4=$(
  TO_FOP_STRUCT="$STRUCT" \
  TO_FOP_PEND="$PEND_FILE_4" \
  TO_GH_BIN="$FAKE_GH_OK" \
  "$SH_BIN" "$FILE_OR_PEND_SH"
) || { echo "FAIL [case4-exit]: file-or-pend.sh exited non-zero on gh-available"; fail=1; }

if [ "$TOKEN4" != "gh-available" ]; then
  echo "FAIL [case4-token]: expected 'gh-available', got '$TOKEN4'"
  fail=1
else
  echo "  [ok] case4: gh-available → token 'gh-available'"
fi

if [ -f "$PEND_FILE_4" ]; then
  echo "FAIL [case4-nopend]: pending file was written when gh is available (must NOT happen — AC3)"
  fail=1
else
  echo "  [ok] case4: no pending file written when gh is available (AC3: file-or-append, never both)"
fi

# ============================================================================
# Case 5: missing TO_FOP_STRUCT exits non-zero (required input guard)
# ============================================================================
set +e
"$SH_BIN" "$FILE_OR_PEND_SH" 2>/dev/null
_rc=$?
set -e
if [ "$_rc" -eq 0 ]; then
  echo "FAIL [required]: file-or-pend.sh should exit non-zero when TO_FOP_STRUCT is missing"
  fail=1
else
  echo "  [ok] case5: file-or-pend.sh exits non-zero when TO_FOP_STRUCT is missing"
fi

# ============================================================================
# Summary
# ============================================================================
if [ "$fail" -eq 0 ]; then
  echo "file-or-pend seam ok"
  exit 0
else
  echo "file-or-pend seam FAILED"
  exit 1
fi
