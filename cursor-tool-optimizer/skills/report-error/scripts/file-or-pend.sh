#!/bin/sh
# WHAT: gh-availability gate + lossless local pending-report fallback.
#       Given an already-sanitized defect-report struct (JSON from sanitize.sh), checks
#       whether `gh` is present AND authenticated. If both conditions hold, prints "gh-available"
#       and exits 0 — the caller proceeds to spawn the filing subagent. If either condition
#       fails (gh missing OR unauthenticated), appends the struct (compact JSONL, one struct
#       per line) to the local pending-reports file and prints "pended", then exits 0 — the
#       caller stops without spawning the filing subagent. This is the AC3 guarantee: the
#       fallback path and the filing path are mutually exclusive; no partial upstream issue
#       can be created.
# WHY:  Machines without a usable GitHub CLI must not lose the defect report. The already-
#       sanitized struct is appended to a gitignored local file and kept there until a human
#       or a future gh-available session files it manually. This is the "lossless local pending
#       fallback" described in SKILL.md. No auto-flush is implemented — only append.
# WHEN: Called by the report-error skill (SKILL.md) on the MAIN THREAD after sanitize.sh has
#       produced the struct (Step 2) and BEFORE spawning the background filing subagent (Step 3).
#       The skill reads the stdout token ("gh-available" | "pended") and branches accordingly.
# HOW:  Injectable env vars:
#         TO_FOP_STRUCT   (required) the already-sanitized JSON struct from sanitize.sh
#         TO_STATE_DIR    (optional) harness-agnostic state-dir umbrella (default: .claude).
#                         The Cursor host sets it to .cursor; an explicit TO_FOP_PEND wins.
#         TO_FOP_PEND     (optional) path to the pending-reports file; default is
#                         "${TO_STATE_DIR}/tool-optimizer.pending-reports.jsonl" relative to
#                         CWD (same directory convention as the breadcrumb). Override in tests
#                         to point at a tmp file and avoid polluting the worktree.
#         TO_GH_BIN       (optional) the gh binary to use; default "gh". Override in seam
#                         tests to simulate gh-missing or gh-unauthenticated.
#       Stdout: the single token "gh-available" or "pended" (no trailing newline).
#       Always exits 0 — lossless: the fallback does NOT throw, does NOT prompt the user.
#       POSIX sh only — no bashisms, no [[ ]], no arrays.

set -e

STRUCT="${TO_FOP_STRUCT:-}"
STATE_DIR="${TO_STATE_DIR:-.claude}"
PEND_FILE="${TO_FOP_PEND:-${STATE_DIR}/tool-optimizer.pending-reports.jsonl}"
GH="${TO_GH_BIN:-gh}"

if [ -z "$STRUCT" ]; then
  echo "file-or-pend.sh: TO_FOP_STRUCT is required" >&2
  exit 1
fi

# --- gh-availability gate (both must succeed; use if/else, not bare &&, to be safe under set -e) ---
if command -v "$GH" >/dev/null 2>&1 && "$GH" auth status >/dev/null 2>&1; then
  # gh is present and authenticated — caller proceeds to the filing subagent.
  printf 'gh-available'
  exit 0
fi

# --- fallback: gh is missing or unauthenticated ---
# Compact the struct to a single line before appending (JSONL: one struct per line).
compact=""
if command -v jq >/dev/null 2>&1; then
  compact=$(printf '%s' "$STRUCT" | jq -c .)
else
  # jq unavailable: strip literal newlines so the struct at least lands on one line.
  # This is a best-effort fallback; a proper jq-less compactor is out of scope.
  compact=$(printf '%s' "$STRUCT" | tr -d '\n')
fi

# Ensure the parent directory of the pending file exists.
_pend_dir=$(dirname -- "$PEND_FILE")
mkdir -p "$_pend_dir"

# Append the compact struct, one line per report (JSONL).
printf '%s\n' "$compact" >> "$PEND_FILE"

printf 'pended'
exit 0
