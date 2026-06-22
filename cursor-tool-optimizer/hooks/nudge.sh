#!/bin/sh
# WHAT: Cursor preToolUse hook — soft-deny redirect toward a cheaper specialized tool
#       when the Read tool is invoked on a path that matches known expensive patterns
#       (tabular data, PDFs, Office docs, or a very large file).
# WHY:  Reading whole CSVs, PDFs, or binary Office files wastes tokens. A one-time
#       soft-deny fires per path per session and names the cheaper alternative via
#       Cursor's agent_message field, turning the agent toward the cheaper tool
#       without repeating for the same path.
# WHEN: Invoked automatically by Cursor before every preToolUse event.
# HOW:  Cursor POSTs a JSON payload on stdin (tool_name + tool_input). This script
#       parses the path, checks triggers, deduplicates via a per-session seen-file, and
#       emits a Cursor preToolUse response — deny-with-agent_message on first trigger
#       touch, silent allow on second touch of the same path, and silent allow on
#       non-triggers.
#
# NOTE — soft-deny is the ADR-0010 default branch: the allow-path (permission: allow +
#   agent_message reaching the agent) could not be confirmed without a live Cursor
#   runtime. See cursor-tool-optimizer/README.md for the deferred manual checks.
#   [sourced — unverified]: cursor.com/docs/hooks, 2026-06-21.
#
# NOTE — this hook is a harness-coupled FORK of tool-optimizer/hooks/nudge.sh.
#   Do NOT add it to scripts/sync-cursor-plugin.sh or scripts/check-cursor-drift.sh.
#
# ENV vars (injectable for testing):
#   TO_NUDGE          "soft" (default) | "off" — disables all nudges when "off".
#   TO_NUDGE_SEEN     path to the per-session seen-file
#                     (default: ${TO_STATE_DIR:-.cursor}/tool-optimizer-nudge.seen)
#   TO_NUDGE_SIZE_MAX max file size in bytes before triggering the "large file" nudge
#                     (default: 102400 = 100 KB)
#   TO_STATE_DIR      harness-agnostic state-dir umbrella (default: .cursor). Used to
#                     derive TO_NUDGE_SEEN and TO_BREADCRUMB when those are not set.
#   TO_BREADCRUMB     path to the hook on-failure breadcrumb file
#                     (default: ${TO_STATE_DIR:-.cursor}/tool-optimizer.breadcrumb)

set -e

STATE_DIR="${TO_STATE_DIR:-.cursor}"
NUDGE_SETTING="${TO_NUDGE:-soft}"
SEEN_FILE="${TO_NUDGE_SEEN:-${STATE_DIR}/tool-optimizer-nudge.seen}"
SIZE_MAX="${TO_NUDGE_SIZE_MAX:-102400}"
BREADCRUMB="${TO_BREADCRUMB:-${STATE_DIR}/tool-optimizer.breadcrumb}"

# --- on-failure trap --------------------------------------------------------
# Fires only on unexpected non-zero exit. Appends artifact-identity#exit-code
# to the local breadcrumb file. NO paths, NO file contents, NO network calls.
trap 'rc=$?; [ "$rc" -ne 0 ] && { mkdir -p "$(dirname "$BREADCRUMB")" 2>/dev/null; printf "hooks/nudge.sh#%s\n" "$rc" >> "$BREADCRUMB" 2>/dev/null; }; :' EXIT

# --- helpers ----------------------------------------------------------------

allow_silent() {
  printf '{"permission":"allow"}\n'
  exit 0
}

deny_with_msg() {
  # $1 = agent message (the redirect to the cheaper tool)
  msg="$1"
  # Escape for JSON string: backslash, double-quote, tab, newline
  escaped=$(printf '%s' "$msg" | sed 's/\\/\\\\/g; s/"/\\"/g; s/	/\\t/g')
  printf '{"permission":"deny","agent_message":"%s"}\n' "$escaped"
  exit 0
}

# --- read stdin -------------------------------------------------------------

input=$(cat)

# Extract tool_name
tool_name=$(printf '%s' "$input" | jq -r '.tool_name // ""' 2>/dev/null || true)

# Only act on the Read tool; all others get a silent allow
if [ "$tool_name" != "Read" ]; then
  allow_silent
fi

# Extract file_path
file_path=$(printf '%s' "$input" | jq -r '.tool_input.file_path // ""' 2>/dev/null || true)

# If nudge is off, always allow silently
if [ "$NUDGE_SETTING" = "off" ]; then
  allow_silent
fi

# --- determine advisory message (if any) ------------------------------------

advisory=""

# Lowercase extension for case-insensitive matching
ext=$(printf '%s' "$file_path" | sed 's/.*\.//' | tr '[:upper:]' '[:lower:]')

case "$ext" in
  csv|tsv|xlsx|parquet)
    advisory="This file looks like tabular data. Consider querying it with duckdb (or qsv) instead of reading the whole file — it is faster and uses far fewer tokens."
    ;;
  pdf)
    advisory="This is a PDF. Consider using the pdf skill instead of reading the raw binary — it extracts structured text with far fewer tokens."
    ;;
  docx|pptx)
    advisory="This is an Office document. Consider converting it with markitdown instead of reading the raw binary — markitdown produces clean Markdown."
    ;;
  *)
    # Check file size only when the file exists on disk
    if [ -n "$file_path" ] && [ -f "$file_path" ]; then
      size=$(wc -c < "$file_path" 2>/dev/null || echo 0)
      if [ "$size" -gt "$SIZE_MAX" ]; then
        advisory="This file is larger than 100 KB. Consider reading a targeted slice (offset/limit) or searching with ripgrep instead of loading the whole file."
      fi
    fi
    ;;
esac

# No trigger — silent allow
if [ -z "$advisory" ]; then
  allow_silent
fi

# --- no-repeat deduplication ------------------------------------------------

# Normalise the path key (strip trailing whitespace, if any)
path_key=$(printf '%s' "$file_path" | tr -d '\n\r')

# Ensure seen-file directory exists
seen_dir=$(dirname "$SEEN_FILE")
mkdir -p "$seen_dir" 2>/dev/null || true

# Check if this path was already nudged this session — if so, allow (once-per-path)
if [ -f "$SEEN_FILE" ] && grep -qF "$path_key" "$SEEN_FILE" 2>/dev/null; then
  allow_silent
fi

# Record the path as seen
printf '%s\n' "$path_key" >> "$SEEN_FILE"

# --- emit soft-deny redirect ------------------------------------------------

deny_with_msg "$advisory"
