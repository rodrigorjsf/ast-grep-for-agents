#!/bin/sh
# WHAT: Renders a sanitized comment body from an already-sanitized defect-report struct.
#       The rendered Markdown is written to stdout (or TO_COMMENT_OUT if set) and is safe
#       to pass directly to `gh issue comment --body-file` — it contains only allowlisted
#       fields already scrubbed by sanitize.sh.
# WHY:  The dedup flow (SKILL.md Step 3a/3b) needs to add a sanitized comment when a
#       fingerprint match is found but the new context meaningfully differs (different
#       osClass / pluginVersion / packageManagers). The comment body is built entirely
#       from the already-sanitized struct so no new denylist material can enter.
#       "Sanitize-by-construction" extends to comments: the struct is the trust boundary.
# WHEN: Called by the background dedup subagent AFTER sanitize.sh has produced the struct
#       and AFTER gh issue list/search has confirmed an open match with new context.
# HOW:  Injectable env vars:
#         TO_COMMENT_STRUCT   (required) the sanitized JSON struct produced by sanitize.sh
#         TO_COMMENT_OUT      (optional) if set, write the body here instead of stdout
#       POSIX sh only — no bashisms, no [[ ]], no arrays.

set -e

STRUCT="${TO_COMMENT_STRUCT:-}"
COMMENT_OUT="${TO_COMMENT_OUT:-}"

if [ -z "$STRUCT" ]; then
  echo "render-comment.sh: TO_COMMENT_STRUCT is required" >&2
  exit 1
fi

# Validate JSON.
printf '%s' "$STRUCT" | jq empty 2>/dev/null || {
  echo "render-comment.sh: TO_COMMENT_STRUCT is not valid JSON" >&2
  exit 1
}

# Extract all values from the already-sanitized struct (never from raw context).
fingerprint=$(printf '%s' "$STRUCT" | jq -r '.fingerprint // ""')
error_class=$(printf '%s' "$STRUCT" | jq -r '.errorClass // ""')
artifact=$(printf '%s' "$STRUCT" | jq -r '.artifact // ""')
exit_code=$(printf '%s' "$STRUCT" | jq -r '.exitCode // ""')
os_class=$(printf '%s' "$STRUCT" | jq -r '.osClass // ""')
plugin_version=$(printf '%s' "$STRUCT" | jq -r '.pluginVersion // ""')
pkg_mgrs=$(printf '%s' "$STRUCT" | jq -r '.packageManagers // ""')
tool_message=$(printf '%s' "$STRUCT" | jq -r '.toolMessage // ""')
synthetic_repro=$(printf '%s' "$STRUCT" | jq -r '.syntheticReproduction // ""')

# Render the comment body (Markdown).
# All values are from the already-sanitized struct — no raw context enters here.
comment_body="**Recurrence:** the same fingerprint (\`fp:${fingerprint}\`) was observed again with different context.

| Field | Value |
|---|---|
| Error class | \`${error_class}\` |
| Failing artifact | \`${artifact}\` |
| Exit code / signal | \`${exit_code}\` |
| OS class | \`${os_class}\` |
| Plugin version | \`${plugin_version}\` |
| Package managers | \`${pkg_mgrs}\` |

**Tool's own error (scrubbed):**
\`\`\`
${tool_message}
\`\`\`

${synthetic_repro}

_Auto-filed by the tool-optimizer report-error skill (recurrence comment). Sanitized by construction: no user paths, code, data, secrets, or repo name are included._"

if [ -n "$COMMENT_OUT" ]; then
  mkdir -p "$(dirname -- "$COMMENT_OUT")"
  printf '%s\n' "$comment_body" > "$COMMENT_OUT"
else
  printf '%s\n' "$comment_body"
fi
