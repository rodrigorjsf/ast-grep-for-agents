#!/bin/sh
# WHAT: PreToolUse hook — soft-nudges the agent toward a cheaper specialized tool
#       when the Read tool is invoked on a path that matches known expensive patterns
#       (tabular data, PDFs, Office docs, or a very large file).
# WHY:  Reading whole CSVs, PDFs, or binary Office files wastes tokens. A non-blocking
#       advisory fires once per path per session and names the cheaper alternative,
#       letting the agent self-correct without blocking the workflow.
# WHEN: Invoked automatically by Claude Code before every Read tool call.
# HOW:  Claude Code POSTs a JSON payload on stdin (tool_name + tool_input). This script
#       parses the path, checks triggers, deduplicates via a per-session seen-file, and
#       emits a JSON allow response — with or without a systemMessage advisory.
#
# ENV vars (injectable for testing):
#   TO_NUDGE          "soft" (default) | "off" — disables all nudges when "off".
#   TO_NUDGE_SEEN     path to the per-session seen-file
#                     (default: ${TMPDIR:-/tmp}/tool-optimizer-nudge-$PPID.seen)
#   TO_NUDGE_SIZE_MAX max file size in bytes before triggering the "large file" nudge
#                     (default: 102400 = 100 KB)

set -e

NUDGE_SETTING="${TO_NUDGE:-soft}"
SEEN_FILE="${TO_NUDGE_SEEN:-${TMPDIR:-/tmp}/tool-optimizer-nudge-$PPID.seen}"
SIZE_MAX="${TO_NUDGE_SIZE_MAX:-102400}"

# --- helpers ----------------------------------------------------------------

allow_silent() {
  printf '{"hookSpecificOutput":{"hookEventName":"PreToolUse","permissionDecision":"allow"}}\n'
  exit 0
}

allow_with_msg() {
  # $1 = advisory message (no embedded newlines needed)
  msg="$1"
  # Escape for JSON string: backslash, double-quote, tab, newline
  escaped=$(printf '%s' "$msg" | sed 's/\\/\\\\/g; s/"/\\"/g; s/	/\\t/g')
  printf '{"hookSpecificOutput":{"hookEventName":"PreToolUse","permissionDecision":"allow"},"systemMessage":"%s"}\n' \
    "$escaped"
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
    advisory="Consider querying this tabular file with duckdb (or qsv) instead of reading the whole file — it is faster and uses far fewer tokens."
    ;;
  pdf)
    advisory="Consider using the pdf skill instead of pasting the binary — it extracts structured text with far fewer tokens."
    ;;
  docx|pptx)
    advisory="Consider converting this Office document with markitdown instead of reading the binary — markitdown produces clean Markdown."
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

# Check if this path was already nudged this session
if [ -f "$SEEN_FILE" ] && grep -qF "$path_key" "$SEEN_FILE" 2>/dev/null; then
  allow_silent
fi

# Record the path as seen
printf '%s\n' "$path_key" >> "$SEEN_FILE"

# --- emit advisory ----------------------------------------------------------

allow_with_msg "$advisory"
