#!/bin/sh
# WHAT: Seam test for render-comment.sh — proves the comment-sanitization guarantee.
#       Seeds the full pipeline (sanitize.sh -> struct -> render-comment.sh -> comment body)
#       with denylist strings and asserts that NONE survive into the comment body.
#       Also asserts that the comment body contains the expected allowlisted fields.
# WHY:  Comments added to existing upstream issues by the dedup flow (AC4) must be
#       sanitized. This seam is the inspectable proof: raw context passes through
#       sanitize.sh first; render-comment.sh consumes only the already-sanitized struct;
#       the final comment body can contain no raw denylist material.
# WHEN: Run by the CI gate (any *.seam.sh under tool-optimizer/).
# HOW:  Drives sanitize.sh then render-comment.sh with TO_* injection (deterministic),
#       captures the comment body, and asserts allowlist presence + denylist absence.
#       No network calls — gh is never invoked. POSIX sh only.

set -e

SCRIPT_DIR="$(CDPATH= cd -- "$(dirname "$0")" && pwd)"
SCRIPT_DIR="$(printf '%s' "$SCRIPT_DIR" | sed 's#/tests/tool-optimizer/#/tool-optimizer/#')"
SANITIZE_SH="$SCRIPT_DIR/sanitize.sh"
RENDER_COMMENT_SH="$SCRIPT_DIR/render-comment.sh"
SH_BIN=$(command -v sh)

tmpdir=$(mktemp -d)
trap 'rm -rf "$tmpdir"' EXIT

fail=0

# --- a synthetic plugin manifest so version is deterministic ---
PLUGIN_JSON="$tmpdir/plugin.json"
cat > "$PLUGIN_JSON" <<'ENDJSON'
{ "name": "tool-optimizer", "version": "9.9.9" }
ENDJSON

# --- the SEEDED denylist strings ---
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

# ============================================================================
# Step 1: Run sanitize.sh to produce the struct (same as the main pipeline)
# ============================================================================
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

# Confirm the struct is valid JSON (prerequisite for render-comment.sh)
printf '%s' "$STRUCT" | jq empty 2>/dev/null \
  || { echo "FAIL [json-struct]: sanitize.sh output is not valid JSON"; fail=1; }

echo "  [ok] sanitize.sh produced valid JSON struct"

# ============================================================================
# Step 2: Run render-comment.sh with ONLY the sanitized struct (no raw context)
# ============================================================================
COMMENT=$(
  TO_COMMENT_STRUCT="$STRUCT" \
  "$SH_BIN" "$RENDER_COMMENT_SH"
) || { echo "FAIL [run-render]: render-comment.sh exited non-zero"; fail=1; }

# ============================================================================
# Case 1: The comment is non-empty and contains expected structural markers
# ============================================================================
if [ -z "$COMMENT" ]; then
  echo "FAIL [non-empty]: render-comment.sh emitted an empty comment body"
  fail=1
fi

# Recurrence marker and fingerprint line.
fp=$(printf '%s' "$STRUCT" | jq -r '.fingerprint')
if ! printf '%s' "$COMMENT" | grep -qF "fp:${fp}"; then
  echo "FAIL [fingerprint]: fingerprint (fp:${fp}) not found in comment body"
  fail=1
fi

# The two-column table headers.
if ! printf '%s' "$COMMENT" | grep -q "Error class"; then
  echo "FAIL [table]: 'Error class' row not found in comment body"
  fail=1
fi

if ! printf '%s' "$COMMENT" | grep -q "Plugin version"; then
  echo "FAIL [table]: 'Plugin version' row not found in comment body"
  fail=1
fi

if ! printf '%s' "$COMMENT" | grep -q "Package managers"; then
  echo "FAIL [table]: 'Package managers' row not found in comment body"
  fail=1
fi

# Allowlisted values from the struct must appear.
if ! printf '%s' "$COMMENT" | grep -qF "9.9.9"; then
  echo "FAIL [version]: plugin version '9.9.9' not found in comment body"
  fail=1
fi

if ! printf '%s' "$COMMENT" | grep -qF "wsl"; then
  echo "FAIL [osclass]: OS class 'wsl' not found in comment body"
  fail=1
fi

if ! printf '%s' "$COMMENT" | grep -q "jq: command not found"; then
  echo "FAIL [tool-message]: scrubbed tool message not found in comment body"
  fail=1
fi

# The Synthetic reproduction section.
if ! printf '%s' "$COMMENT" | grep -q "Synthetic reproduction"; then
  echo "FAIL [synthetic-repro]: synthetic reproduction not found in comment body"
  fail=1
fi

# The sanitized-by-construction closing line.
if ! printf '%s' "$COMMENT" | grep -q "Sanitized by construction"; then
  echo "FAIL [closing-line]: 'Sanitized by construction' closing line not found"
  fail=1
fi

echo "  [ok] comment body has the expected structure and allowlisted fields"

# ============================================================================
# Case 2: PROVABLY none of the seeded denylist strings appear in the comment
# ============================================================================
assert_absent() {
  # $1 = label, $2 = seeded string that must NOT appear in the comment
  if printf '%s' "$COMMENT" | grep -qF "$2"; then
    echo "FAIL [denylist]: seeded $1 leaked into the comment body: $2"
    fail=1
  fi
}

assert_absent "user path"   "$SEED_USERPATH"
assert_absent "home dir"    "$SEED_HOME"
assert_absent "fake secret" "$SEED_SECRET"
assert_absent "repo slug"   "$SEED_REPO"
assert_absent "repo remote" "$SEED_REMOTE"

# The literal username token "alice" must not survive.
if printf '%s' "$COMMENT" | grep -qiw "alice"; then
  echo "FAIL [denylist]: seeded username 'alice' leaked into the comment body"
  fail=1
fi

echo "  [ok] no seeded denylist string survived into the comment body"

# ============================================================================
# Case 3: TO_COMMENT_OUT file-write path works
# ============================================================================
COMMENT_FILE="$tmpdir/comment-out.md"
TO_COMMENT_STRUCT="$STRUCT" \
TO_COMMENT_OUT="$COMMENT_FILE" \
  "$SH_BIN" "$RENDER_COMMENT_SH" || { echo "FAIL [file-out]: render-comment.sh failed with TO_COMMENT_OUT"; fail=1; }

if [ ! -f "$COMMENT_FILE" ]; then
  echo "FAIL [file-out]: TO_COMMENT_OUT file was not created"
  fail=1
elif [ ! -s "$COMMENT_FILE" ]; then
  echo "FAIL [file-out]: TO_COMMENT_OUT file is empty"
  fail=1
else
  echo "  [ok] TO_COMMENT_OUT file-write path works"
fi

# ============================================================================
# Case 4: missing TO_COMMENT_STRUCT exits non-zero
# ============================================================================
set +e
"$SH_BIN" "$RENDER_COMMENT_SH" 2>/dev/null
_rc=$?
set -e
if [ "$_rc" -eq 0 ]; then
  echo "FAIL [required]: render-comment.sh should exit non-zero when TO_COMMENT_STRUCT is missing"
  fail=1
else
  echo "  [ok] render-comment.sh exits non-zero when TO_COMMENT_STRUCT is missing"
fi

# ============================================================================
# Summary
# ============================================================================
if [ "$fail" -eq 0 ]; then
  echo "render-comment seam ok"
  exit 0
else
  echo "render-comment seam FAILED"
  exit 1
fi
