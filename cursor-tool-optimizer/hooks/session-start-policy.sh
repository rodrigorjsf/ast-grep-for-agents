#!/bin/sh
# WHAT: Cursor sessionStart hook — injects the tool policy + available-tool inventory into
#       the agent context at session start via Cursor's additional_context envelope.
# WHY:  The hook is on the hot path (every session). It reads a PRE-RENDERED markdown block
#       from .cursor/tool-optimizer.local.md (written by render.sh) so it never runs jq,
#       command -v, or any detection logic. Pure cat/sed is all that executes here.
# WHEN: Invoked automatically by Cursor at every sessionStart event.
# HOW:  Reads TO_LOCAL_MD (default: ${TO_STATE_DIR:-.cursor}/tool-optimizer.local.md) — strip
#       YAML frontmatter if present (sed /^---/,/^---/d), then JSON-escape and emit Cursor's
#       additional_context envelope: { "env": {}, "additional_context": "<context>" }.
#       GRACEFUL FALLBACK: if the file is absent or has no usable body after stripping, emits
#       the static Policy so sessions without a bootstrap still get the guardrails.
#       BREADCRUMB PICKUP: reads the breadcrumb file (if non-empty) and appends a one-line
#       pending-defect pointer so the agent files the pending hook defect(s) via report-error.
#
# ENV vars (injectable for seam testing):
#   TO_STATE_DIR   harness-agnostic state-dir umbrella (default: .cursor). Used to derive
#                  TO_LOCAL_MD and TO_BREADCRUMB when those are not set explicitly.
#   TO_LOCAL_MD    path to the pre-rendered markdown body
#                  (default: ${TO_STATE_DIR:-.cursor}/tool-optimizer.local.md)
#   TO_BREADCRUMB  path to the hook on-failure breadcrumb file
#                  (default: ${TO_STATE_DIR:-.cursor}/tool-optimizer.breadcrumb)
#   TO_FORCE_CRASH set non-empty to trigger a deliberate non-zero exit (seam testing only)
#
# NOTE — live re-verification deferred: the exact Cursor sessionStart output envelope
#   { "env": {...}, "additional_context": "<context>" } is implemented per ADR-0007's
#   [sourced — unverified] citation of cursor.com/docs/hooks (2026-06-21). A real Cursor
#   runtime is required to confirm the schema; see cursor-tool-optimizer/README.md.

set -e

STATE_DIR="${TO_STATE_DIR:-.cursor}"
LOCAL_MD="${TO_LOCAL_MD:-${STATE_DIR}/tool-optimizer.local.md}"
BREADCRUMB="${TO_BREADCRUMB:-${STATE_DIR}/tool-optimizer.breadcrumb}"

# --- on-failure trap --------------------------------------------------------
# Fires only on unexpected non-zero exit. Appends artifact-identity#exit-code
# to the local breadcrumb file. NO paths, NO file contents, NO network calls.
trap 'rc=$?; [ "$rc" -ne 0 ] && { mkdir -p "$(dirname "$BREADCRUMB")" 2>/dev/null; printf "hooks/session-start-policy.sh#%s\n" "$rc" >> "$BREADCRUMB" 2>/dev/null; }; :' EXIT

# --- static fallback policy (preserved from slice #2) ---
POLICY='## Local tool policy (token-first) — extends the code-search policy

Before reading or searching, pick by the SHAPE of the task:
- Literal / regex / identifier across a tree -> ripgrep (`rg`, add `--json` to parse fields).
- Syntax-aware search/rewrite in one language -> ast-grep. Need taint/dataflow or a CWE rule
  registry -> semgrep. (Type-aware cross-file refactor -> IDE/OpenRewrite, not these.)
- Pack a tree/file-set into context -> repomix (whole repo, structured XML/MD) or
  files-to-prompt (an explicit file subset, `--cxml`). Do NOT cat whole files in.
- A PDF -> the pdf skill. A docx/pptx/xlsx/html/epub -> markitdown. Never paste a binary doc raw.
- A CSV/Excel you won'\''t fully consume -> query it: `duckdb -c "SELECT ... FROM '\''f.csv'\''"`
  (or qsv for quick stats). Reading the whole file is the thing to avoid.
- "Where is X defined / used?" on a large repo -> consult the ctags index before re-scanning.
- "Did I/we already see this?" -> claude-mem (cross-session). Verbose command output -> RTK.

Guardrail: a non-standard tool must beat the standard tool (Read/Grep/rg) for THIS task on
tokens or capability — novelty is never the reason. No standard tool is deny-listed.

Self-report: if a tool-optimizer Bootstrap script is GENUINELY defective — it crashes
unexpectedly or emits clearly garbage output — invoke the `report-error` skill. It files ONE
sanitized issue on the plugin'\''s upstream tracker (rodrigorjsf/ast-grep-for-agents), carrying
only allowlisted facts (OS class, plugin version, package-manager set, the scrubbed error) and
a synthetic reproduction — never your paths, code, data, secrets, or repo name. An EXPECTED
outcome (a documented no-match exit, an expected empty result, a genuinely missing tool you
degrade around, or a declined consented install) is NOT a defect — do not report it.'

# --- seam-only crash injection (never set in production) --------------------
# TO_FORCE_CRASH is only set by the seam test to trigger the on-failure trap.
# In production this variable is always unset; this guard is a no-op.
if [ -n "${TO_FORCE_CRASH:-}" ]; then
  # Deliberately fail so the EXIT trap fires and writes a breadcrumb.
  false
fi

# --- read the pre-rendered block (hot path: cat/sed only, no jq, no command -v) ---

block=""
if [ -f "$LOCAL_MD" ]; then
  # Strip YAML frontmatter (lines between leading --- delimiters) if present.
  # The substitution is a no-op when no frontmatter exists (forward-compat for slice #5).
  raw=$(sed '/^---$/,/^---$/d' "$LOCAL_MD")
  # Trim leading blank lines after frontmatter strip.
  block=$(printf '%s' "$raw" | sed '/./,$!d')
fi

# Fall back to static Policy when the cached block is absent or empty.
if [ -z "$block" ]; then
  block="$POLICY"
fi

# --- breadcrumb pickup (AC2) ------------------------------------------------
# If the breadcrumb file is non-empty, a prior hook exited unexpectedly and
# could not self-report (e.g. a SessionStart crash is invisible to the agent).
# Append a one-line pointer so the agent files the pending defect(s) via the
# report-error skill. NO network calls here — this is a pure local read.
if [ -f "$BREADCRUMB" ] && [ -s "$BREADCRUMB" ]; then
  block="${block}

tool-optimizer: pending hook defect(s) detected in breadcrumb — invoke the \`report-error\` skill to file them upstream."
fi

# --- emit Cursor JSON payload -----------------------------------------------
# Cursor sessionStart envelope: { "env": {}, "additional_context": "<context>" }
# [sourced — unverified]: cursor.com/docs/hooks, 2026-06-21

printf '{"env":{},"additional_context":"%s"}\n' \
  "$(printf '%s' "$block" | sed 's/\\/\\\\/g; s/"/\\"/g; s/	/\\t/g' | awk '{printf "%s\\n", $0}' | sed '$ s/\\n$//')"
