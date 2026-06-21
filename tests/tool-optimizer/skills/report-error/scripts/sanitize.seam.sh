#!/bin/sh
# WHAT: Seam test for sanitize.sh — proves the sanitize-by-construction guarantee. Seeds the
#       sanitizer with a user path, a home directory, a fake secret, and a repo name, then
#       asserts the emitted struct (1) is valid JSON, (2) carries the fingerprint, the
#       allowlisted fields, the [tool-optimizer] title prefix, and a LABELED synthetic
#       reproduction, and (3) PROVABLY contains none of the seeded denylist strings.
# WHY:  The struct is filed as a public upstream GitHub issue and is the ONLY thing handed to
#       the background filing subagent. This seam is the inspectable proof that no user path,
#       home dir, username, secret, or repo identifier can ride along.
# WHEN: Run by the CI gate (any *.seam.sh under tool-optimizer/).
# HOW:  Drives sanitize.sh with TO_* injection (deterministic), captures the struct, and
#       asserts allowlist presence + denylist absence with jq + grep.
#       POSIX sh only — no bash arrays, no [[ ]], no bashisms.

set -e

SCRIPT_DIR="$(CDPATH= cd -- "$(dirname "$0")" && pwd)"
SCRIPT_DIR="$(printf '%s' "$SCRIPT_DIR" | sed 's#/tests/tool-optimizer/#/tool-optimizer/#')"
SANITIZE_SH="$SCRIPT_DIR/sanitize.sh"
SH_BIN=$(command -v sh)

tmpdir=$(mktemp -d)
trap 'rm -rf "$tmpdir"' EXIT

fail=0

# --- a synthetic plugin manifest so version is deterministic (not the repo's) ---
PLUGIN_JSON="$tmpdir/plugin.json"
cat > "$PLUGIN_JSON" <<'ENDJSON'
{ "name": "tool-optimizer", "version": "9.9.9" }
ENDJSON

# --- the SEEDED denylist strings (AC4: user path, home dir, fake secret, repo name) ---
SEED_HOME="/home/alice"
SEED_USER="alice"
SEED_USERPATH="/home/alice/secret-project/src/main/java/Foo.java"
SEED_SECRET="ghp_AbCdEf0123456789AbCdEf0123456789xZ"   # fake GitHub-PAT-shaped token
SEED_REPO="alice/secret-project"
SEED_REMOTE="git@github.com:alice/secret-project.git"

# The raw tool error message carries ALL the seeded denylist strings, the way a real
# crash tail would: an absolute user path, the home dir, an exported secret, the repo.
RAW_MSG="detect.sh: line 42: jq: command not found
  while probing $SEED_USERPATH
  HOME=$SEED_HOME  GITHUB_TOKEN=$SEED_SECRET
  remote: $SEED_REMOTE  (repo $SEED_REPO)"

# The failing artifact is an ABSOLUTE user path under tool-optimizer/.
ARTIFACT="/home/alice/secret-project/tool-optimizer/skills/bootstrap/scripts/detect.sh"

STRUCT=$(
  TO_ERR_ARTIFACT="$ARTIFACT" \
  TO_ERR_EXIT="127" \
  TO_ERR_MESSAGE="$RAW_MSG" \
  TO_ERR_CLASS="crash" \
  TO_OS_CLASS="wsl" \
  TO_PKG_MGRS="brew,npm,uv,notamgr" \
  TO_PLUGIN_JSON="$PLUGIN_JSON" \
  TO_SCRUB_HOME="$SEED_HOME" \
  TO_SCRUB_USER="$SEED_USER" \
  TO_SCRUB_REPO="$SEED_REPO" \
  "$SH_BIN" "$SANITIZE_SH"
) || { echo "FAIL [run]: sanitize.sh exited non-zero"; fail=1; }

# ============================================================================
# Case 1: the struct is valid JSON
# ============================================================================
printf '%s' "$STRUCT" | jq empty 2>/dev/null \
  || { echo "FAIL [json]: emitted struct is not valid JSON"; fail=1; }

# ============================================================================
# Case 2: allowlisted fields present + correctly shaped
# ============================================================================
printf '%s' "$STRUCT" | jq -er '.titlePrefix == "[tool-optimizer]"' >/dev/null \
  || { echo "FAIL [allow]: title prefix missing/wrong"; fail=1; }
printf '%s' "$STRUCT" | jq -er '.title | startswith("[tool-optimizer]")' >/dev/null \
  || { echo "FAIL [allow]: title does not start with the [tool-optimizer] prefix"; fail=1; }
printf '%s' "$STRUCT" | jq -er '.fingerprint | length > 0' >/dev/null \
  || { echo "FAIL [allow]: fingerprint missing"; fail=1; }
printf '%s' "$STRUCT" | jq -er '.title | contains(.fingerprint? // "")' >/dev/null 2>&1 || true
# Fingerprint must also appear inside the title (AC1: a fingerprint line / marker).
fp=$(printf '%s' "$STRUCT" | jq -r '.fingerprint')
printf '%s' "$STRUCT" | jq -r '.title' | grep -qF "$fp" \
  || { echo "FAIL [allow]: fingerprint not embedded in title"; fail=1; }
printf '%s' "$STRUCT" | jq -er '.artifact == "tool-optimizer/skills/bootstrap/scripts/detect.sh"' >/dev/null \
  || { echo "FAIL [allow]: artifact not scrubbed to plugin-relative path"; fail=1; }
printf '%s' "$STRUCT" | jq -er '.exitCode == "127"' >/dev/null \
  || { echo "FAIL [allow]: exit code missing/wrong"; fail=1; }
printf '%s' "$STRUCT" | jq -er '.errorClass == "crash"' >/dev/null \
  || { echo "FAIL [allow]: error class missing/wrong"; fail=1; }
printf '%s' "$STRUCT" | jq -er '.osClass == "wsl"' >/dev/null \
  || { echo "FAIL [allow]: OS class missing/wrong"; fail=1; }
printf '%s' "$STRUCT" | jq -er '.pluginVersion == "9.9.9"' >/dev/null \
  || { echo "FAIL [allow]: plugin version not read from manifest"; fail=1; }
# package-manager set keeps known managers, drops the bogus one.
printf '%s' "$STRUCT" | jq -er '.packageManagers == "brew,npm,uv"' >/dev/null \
  || { echo "FAIL [allow]: package-manager set wrong (should drop unknown managers)"; fail=1; }
printf '%s' "$STRUCT" | jq -er '.upstreamRepo == "rodrigorjsf/ast-grep-for-agents"' >/dev/null \
  || { echo "FAIL [allow]: hardcoded upstream repo missing/wrong"; fail=1; }
# Synthetic reproduction is present AND labeled as synthetic.
printf '%s' "$STRUCT" | jq -er '.syntheticReproduction | contains("Synthetic reproduction")' >/dev/null \
  || { echo "FAIL [allow]: synthetic reproduction not labeled"; fail=1; }
printf '%s' "$STRUCT" | jq -er '.syntheticReproduction | contains("no user paths/code/data")' >/dev/null \
  || { echo "FAIL [allow]: synthetic reproduction missing the no-user-data label"; fail=1; }

echo "  [ok] allowlisted fields present and correctly shaped"

# ============================================================================
# Case 3: PROVABLY none of the seeded denylist strings appear ANYWHERE in the struct
# ============================================================================
assert_absent() {
  # $1 = label, $2 = seeded string that must NOT appear in the struct
  if printf '%s' "$STRUCT" | grep -qF "$2"; then
    echo "FAIL [denylist]: seeded $1 leaked into the struct: $2"
    fail=1
  fi
}

assert_absent "user path"     "$SEED_USERPATH"
assert_absent "home dir"      "$SEED_HOME"
assert_absent "username"      "secret-project"   # part of the repo/path; must be gone
assert_absent "fake secret"   "$SEED_SECRET"
assert_absent "repo slug"     "$SEED_REPO"
assert_absent "repo remote"   "$SEED_REMOTE"
# The literal username token "alice" must not survive either.
if printf '%s' "$STRUCT" | grep -qiw "alice"; then
  echo "FAIL [denylist]: seeded username 'alice' leaked into the struct"
  fail=1
fi

echo "  [ok] no seeded denylist string survived the sanitizer"

# ============================================================================
# Case 4: the tool's own (scrubbed) error message survives in spirit
#   — the allowlisted error message is kept, but with denylist shapes masked.
# ============================================================================
printf '%s' "$STRUCT" | jq -r '.toolMessage' | grep -q "jq: command not found" \
  || { echo "FAIL [message]: the tool's own error text was lost during scrubbing"; fail=1; }
printf '%s' "$STRUCT" | jq -r '.toolMessage' | grep -q "<redacted>" \
  || { echo "FAIL [message]: secret was not masked to <redacted> in the message"; fail=1; }

echo "  [ok] tool error message retained with denylist shapes masked"

# ============================================================================
# Case 5: an EXPECTED outcome must NOT produce a report. The skill decides this
#   upstream of sanitize.sh, but we assert sanitize.sh exposes a class the skill
#   keys on so the seam documents the contract: error classes are constrained.
# ============================================================================
# Re-run with a benign class to confirm errorClass is sanitized to a safe token
# (no free-form leakage) — the skill's "is this a real defect?" gate lives in
# SKILL.md, but the struct must never carry an arbitrary class string.
STRUCT2=$(
  TO_ERR_ARTIFACT="$ARTIFACT" TO_ERR_EXIT="1" \
  TO_ERR_MESSAGE="ok" TO_ERR_CLASS="weird class; rm -rf /" \
  TO_OS_CLASS="linux" TO_PLUGIN_JSON="$PLUGIN_JSON" \
  TO_SCRUB_HOME="$SEED_HOME" TO_SCRUB_USER="$SEED_USER" \
  "$SH_BIN" "$SANITIZE_SH"
) || { echo "FAIL [class]: sanitize.sh exited non-zero on second run"; fail=1; }

printf '%s' "$STRUCT2" | jq -er '.errorClass | test("^[A-Za-z0-9._-]+$")' >/dev/null \
  || { echo "FAIL [class]: error class not constrained to a safe token"; fail=1; }

echo "  [ok] error class constrained to a safe token (no injection)"

# ============================================================================
# Case 6: plugin version is read from the REAL shipped manifest when TO_PLUGIN_JSON
#   is unset (proves the single-source-of-truth wiring: .claude-plugin/plugin.json).
# ============================================================================
REAL_MANIFEST="$SCRIPT_DIR/../../../.claude-plugin/plugin.json"
if [ -f "$REAL_MANIFEST" ]; then
  REAL_VER=$(jq -r '.version' "$REAL_MANIFEST")
  STRUCT3=$(
    TO_ERR_ARTIFACT="$ARTIFACT" TO_ERR_EXIT="1" TO_ERR_MESSAGE="ok" \
    TO_ERR_CLASS="crash" TO_OS_CLASS="linux" \
    TO_SCRUB_HOME="$SEED_HOME" TO_SCRUB_USER="$SEED_USER" \
    "$SH_BIN" "$SANITIZE_SH"
  ) || { echo "FAIL [version]: sanitize.sh exited non-zero reading real manifest"; fail=1; }
  printf '%s' "$STRUCT3" | jq -er --arg v "$REAL_VER" '.pluginVersion == $v' >/dev/null \
    || { echo "FAIL [version]: plugin version not read from the shipped manifest (expected $REAL_VER)"; fail=1; }
  echo "  [ok] plugin version read from the shipped .claude-plugin/plugin.json ($REAL_VER)"
else
  echo "  [skip] real manifest not found at expected path (worktree layout differs)"
fi

# ============================================================================
# Case 7: the NAMED denylist rules (home / username / absolute-path catch-all)
#   must each scrub on their OWN, not be masked by the broad entropy rule.
#   Case 1 seeds long strings ("alice/secret-project", a 37-char token) that the
#   >=20-char entropy rule redacts before the named rules ever fire — so Case 1
#   alone would still pass if the home/user/path rules silently regressed. This
#   case seeds SHORT values (< 20 chars, low entropy) that ONLY the named rules
#   can catch, so a regression in any one of them fails the gate here.
# ============================================================================
S_HOME="/h/bob"                 # 6 chars  — entropy rule cannot catch it
S_USER="bob"                    # standalone username, masked by the \b word rule
S_OTHERPATH="/srv/data/x/y"     # unrelated multi-segment path — the catch-all's job
S_MSG="probe at $S_OTHERPATH under $S_HOME as user $S_USER ok"

STRUCT7=$(
  TO_ERR_ARTIFACT="$ARTIFACT" TO_ERR_EXIT="2" \
  TO_ERR_MESSAGE="$S_MSG" TO_ERR_CLASS="crash" \
  TO_OS_CLASS="linux" TO_PLUGIN_JSON="$PLUGIN_JSON" \
  TO_SCRUB_HOME="$S_HOME" TO_SCRUB_USER="$S_USER" \
  "$SH_BIN" "$SANITIZE_SH"
) || { echo "FAIL [named]: sanitize.sh exited non-zero on named-rule run"; fail=1; }

# Sanity: the broad entropy rule must NOT have fired (no 20+ char run here), so
# any masking we see is the work of the named rules — not the catch-all.
if printf '%s' "$S_MSG" | grep -Eq '[A-Za-z0-9+/_=-]{20,}'; then
  echo "FAIL [named]: test seed unexpectedly contains a 20+ char run (entropy rule would mask it)"
  fail=1
fi

# home rule: the short home dir must be gone (masked to <home>).
if printf '%s' "$STRUCT7" | grep -qF "$S_HOME"; then
  echo "FAIL [named]: short home dir leaked (home rule regressed): $S_HOME"; fail=1
fi
# username rule: the standalone short username must be gone.
if printf '%s' "$STRUCT7" | jq -r '.toolMessage' | grep -qw "$S_USER"; then
  echo "FAIL [named]: short username leaked (user word-boundary rule regressed): $S_USER"; fail=1
fi
# absolute-path catch-all: an unrelated multi-segment path must be masked to <path>.
if printf '%s' "$STRUCT7" | grep -qF "$S_OTHERPATH"; then
  echo "FAIL [named]: unrelated absolute path leaked (path catch-all regressed): $S_OTHERPATH"; fail=1
fi
# And the scrubbed message must still carry the masking tokens (proves the rules ran,
# not that the whole message was dropped).
printf '%s' "$STRUCT7" | jq -r '.toolMessage' | grep -q "<path>" \
  || { echo "FAIL [named]: <path> token absent — path catch-all did not run"; fail=1; }
printf '%s' "$STRUCT7" | jq -r '.toolMessage' | grep -q "<home>" \
  || { echo "FAIL [named]: <home> token absent — home rule did not run"; fail=1; }

echo "  [ok] named rules (home / username / path catch-all) each scrub independently"

# ============================================================================
# Summary
# ============================================================================
if [ "$fail" -eq 0 ]; then
  echo "sanitize seam ok"
  exit 0
else
  echo "sanitize seam FAILED"
  exit 1
fi
