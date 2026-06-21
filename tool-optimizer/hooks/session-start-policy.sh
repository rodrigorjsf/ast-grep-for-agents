#!/bin/sh
# WHAT: SessionStart hook — injects the tool policy + available-tool inventory into the agent
#       context at session start.
# WHY:  The hook is on the hot path (every session). It reads a PRE-RENDERED markdown block
#       from .claude/tool-optimizer.local.md (written by render.sh) so it never runs jq,
#       command -v, or any detection logic. Pure cat/sed is all that executes here.
# WHEN: Invoked automatically by Claude Code at every SessionStart event.
# HOW:  Reads TO_LOCAL_MD (default: .claude/tool-optimizer.local.md) — strip YAML frontmatter
#       if present (sed /^---/,/^---/d), then JSON-escape and emit the structured payload.
#       GRACEFUL FALLBACK: if the file is absent or has no usable body after stripping, emits
#       the static Policy so sessions without a bootstrap still get the guardrails.
#
# ENV vars (injectable for seam testing):
#   TO_LOCAL_MD   path to the pre-rendered markdown body
#                 (default: .claude/tool-optimizer.local.md)

LOCAL_MD="${TO_LOCAL_MD:-.claude/tool-optimizer.local.md}"

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
tokens or capability — novelty is never the reason. No standard tool is deny-listed.'

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

# --- emit JSON payload (same contract as before) ---

printf '{"hookSpecificOutput":{"hookEventName":"SessionStart","additionalContext":"%s"}}\n' \
  "$(printf '%s' "$block" | sed 's/\\/\\\\/g; s/"/\\"/g; s/	/\\t/g' | awk '{printf "%s\\n", $0}' | sed '$ s/\\n$//')"
