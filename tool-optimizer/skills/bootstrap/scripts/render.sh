#!/bin/sh
# WHAT: Renders the SessionStart block from the tool inventory JSON into a cached markdown file.
# WHY:  The SessionStart hook is on the hot path (every session start). This render script runs
#       once (batch) and writes a pre-rendered markdown block so the hook can cat it without
#       running jq, command -v, or any detection logic.
# WHEN: Run after detect.sh to refresh the cached block. Re-running with the same inputs and
#       TO_NOW produces a byte-identical file (deterministic).
# HOW:  Set env vars to override defaults:
#         TO_INVENTORY  path to the inventory JSON   (default: .claude/tool-optimizer.local.json)
#         TO_NOW        current time in ISO-8601 UTC  (default: date -u +"%Y-%m-%dT%H:%M:%SZ")
#         TO_RENDER_OUT output path for the body-only markdown block
#                       (default: .claude/tool-optimizer.local.md)
#       render.sh regenerates only the body block. Any existing YAML frontmatter in
#       TO_RENDER_OUT is PRESERVED (user settings — enabled/nudge/mcp/overrides — live there,
#       so a re-render must never churn them). The hot path strips frontmatter on read.
#       Usage:
#         sh render.sh
#         TO_INVENTORY=/tmp/inv.json TO_NOW="2026-01-01T00:00:00Z" TO_RENDER_OUT=/tmp/out.md sh render.sh

set -e

INVENTORY="${TO_INVENTORY:-.claude/tool-optimizer.local.json}"
RENDER_OUT="${TO_RENDER_OUT:-.claude/tool-optimizer.local.md}"
NOW_ISO="${TO_NOW:-$(date -u +"%Y-%m-%dT%H:%M:%SZ")}"

# --- validate inputs ---

if [ ! -f "$INVENTORY" ]; then
  printf 'render.sh: inventory not found: %s\n' "$INVENTORY" >&2
  exit 1
fi

# --- staleness computation ---
# Parse detectedAt from the inventory JSON using sed (no jq dependency here;
# jq is allowed in render.sh per contract, but sed keeps the script portable and simple).
# detectedAt is the last key, format: "detectedAt": "2026-01-01T00:00:00Z"

detected_at=$(grep '"detectedAt"' "$INVENTORY" | sed 's/.*"detectedAt"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/')

if [ -z "$detected_at" ]; then
  printf 'render.sh: detectedAt not found in inventory\n' >&2
  exit 1
fi

# Convert ISO-8601 timestamps to epoch seconds using GNU date -d (Linux/WSL2 target).
now_epoch=$(date -d "$NOW_ISO" +%s 2>/dev/null) || {
  printf 'render.sh: cannot parse TO_NOW as date: %s\n' "$NOW_ISO" >&2
  exit 1
}
det_epoch=$(date -d "$detected_at" +%s 2>/dev/null) || {
  printf 'render.sh: cannot parse detectedAt as date: %s\n' "$detected_at" >&2
  exit 1
}

diff_seconds=$((now_epoch - det_epoch))
days_old=$((diff_seconds / 86400))

stale_note=""
if [ "$diff_seconds" -gt "$((30 * 86400))" ]; then
  stale_note="$(printf '> **Note:** inventory is %d days old; re-run the bootstrap to refresh.' "$days_old")"
fi

# --- extract available tools from inventory ---
# Use jq to iterate the JSON object and collect names where available=true.
# Output is sorted by key order as emitted by detect.sh (alphabetical).

available_tools=$(jq -r 'to_entries[] | select(.key != "detectedAt") | select(.value.available == true) | .key' "$INVENTORY" 2>/dev/null) || {
  printf 'render.sh: jq failed to parse inventory\n' >&2
  exit 1
}

# --- build the markdown block ---

POLICY='Before reading or searching, pick by the SHAPE of the task:
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

# Build available tools list as a markdown bullet list.
tool_list=""
for tool in $available_tools; do
  tool_list="${tool_list}- ${tool}
"
done
# Strip trailing newline from tool_list
tool_list=$(printf '%s' "$tool_list" | sed '$ s/[[:space:]]*$//')

# Compose the final block.
# Block structure:
#   ## Local tool policy (token-first) — extends the code-search policy
#   ### Available tools
#   <bullet list>
#   ### Preference order & guardrails
#   <policy text>
#   [staleness note if stale]

block="## Local tool policy (token-first) — extends the code-search policy

### Available tools on this machine

${tool_list}

### Preference order & guardrails

${POLICY}"

if [ -n "$stale_note" ]; then
  block="${block}

${stale_note}"
fi

# --- ensure output directory exists and write ---
# Preserve any existing YAML frontmatter: user settings live there, so a re-render
# regenerates ONLY the body block, never churning the settings. Extract a leading
# `---` ... `---` block if present and re-emit it above the freshly rendered body.
frontmatter=""
if [ -f "$RENDER_OUT" ]; then
  frontmatter=$(sed -n '1{/^---$/!q;}; /^---$/,/^---$/p' "$RENDER_OUT")
fi

mkdir -p "$(dirname "$RENDER_OUT")"
if [ -n "$frontmatter" ]; then
  printf '%s\n\n%s\n' "$frontmatter" "$block" > "$RENDER_OUT"
else
  printf '%s\n' "$block" > "$RENDER_OUT"
fi
