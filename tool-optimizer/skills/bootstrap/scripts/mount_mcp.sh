#!/bin/sh
# WHAT: Mounts / unmounts the opt-in ast-grep MCP server in the project-root .mcp.json,
#       driven by the resolved `mcp` setting.
# WHY:  `mcp` is off by default. A plugin-bundled .mcp.json mounts its servers
#       unconditionally the moment the plugin is enabled, so it cannot honor a per-setting
#       toggle. The bootstrap therefore owns the opt-in mount: it writes a consented,
#       project-scope .mcp.json entry when `mcp` is on and removes ONLY that entry when
#       off — preserving any other servers / keys the user already has. Project-scope
#       .mcp.json is the official committable mechanism (top-level `mcpServers`).
#       Writing the entry does NOT auto-activate the server: Claude Code prompts for
#       approval on first session, or pre-opt-in via the enableAllProjectMcpServers /
#       enabledMcpjsonServers settings.
#       [sourced — https://code.claude.com/docs/en/mcp, 2026-06-21]
# WHEN: Run from the bootstrap after the inventory is resolved, on explicit consent (the
#       write mutates a committable repo file). Idempotent — re-running with the same
#       setting converges to the same .mcp.json.
# HOW:  Injectable env vars (all optional):
#         TO_MCP_SETTING  the `mcp` value. "on"/"true"/"1"/"yes" => mount; anything else
#                         (including unset) => unmount. If this var is unset, the setting is
#                         read from the .local.md settings frontmatter (see below).
#         PROJECT_MCP     path to the project .mcp.json (default: .mcp.json)
#         PROJECT_SETTINGS / GLOBAL_SETTINGS  the settings files whose YAML frontmatter holds
#                         `mcp:` (defaults: .claude/tool-optimizer.local.md and
#                         ~/.claude/tool-optimizer/tool-optimizer.local.md). `mcp` lives in
#                         frontmatter, NOT the inventory JSON (detect.sh overwrites that);
#                         project frontmatter wins over global.
#       Server entry (key "ast-grep"), no-clone portable form — runs the upstream server
#       straight from git, so the committable .mcp.json carries no machine-specific path.
#       Upstream: https://github.com/ast-grep/ast-grep-mcp. The assembled invocation is
#       [sourced — unverified] (the literal server arg is not shown verbatim upstream);
#       for a pinned or custom command, use `claude mcp add --scope project` instead and
#       leave `mcp` off.
#       Needs jq.
#
#       Usage:
#         TO_MCP_SETTING=on  PROJECT_MCP=/path/.mcp.json sh mount_mcp.sh   # mount
#         TO_MCP_SETTING=off PROJECT_MCP=/path/.mcp.json sh mount_mcp.sh   # unmount
#         sh mount_mcp.sh                                                  # read mcp from config

set -e

PROJECT_MCP="${PROJECT_MCP:-.mcp.json}"
SERVER_KEY="ast-grep"

command -v jq >/dev/null 2>&1 || { printf 'mount_mcp.sh: jq is required\n' >&2; exit 1; }

# Read a flat scalar from a file's leading YAML frontmatter (the `---` ... `---` block),
# or nothing if the file or key is absent. Mirrors how session-start-policy.sh treats the
# .local.md frontmatter; read-only, so no churn risk.
read_frontmatter_scalar() {
  [ -f "$1" ] || return 0
  sed -n '1{/^---$/!q;}; /^---$/,/^---$/p' "$1" \
    | grep -m1 "^[[:space:]]*$2[[:space:]]*:" \
    | sed "s/^[[:space:]]*$2[[:space:]]*:[[:space:]]*//; s/[[:space:]]*\$//; s/^[\"']//; s/[\"']\$//"
}

# --- resolve the desired state ---
if [ -n "${TO_MCP_SETTING+x}" ]; then
  setting="$TO_MCP_SETTING"
else
  # `mcp` is a user setting → read it from the .local.md frontmatter, NOT the inventory JSON
  # (detect.sh overwrites that). Project frontmatter wins; fall back to global.
  PROJECT_SETTINGS="${PROJECT_SETTINGS:-.claude/tool-optimizer.local.md}"
  GLOBAL_SETTINGS="${GLOBAL_SETTINGS:-${HOME}/.claude/tool-optimizer/tool-optimizer.local.md}"
  setting=$(read_frontmatter_scalar "$PROJECT_SETTINGS" mcp)
  [ -n "$setting" ] || setting=$(read_frontmatter_scalar "$GLOBAL_SETTINGS" mcp)
fi

case "$setting" in
  on|On|ON|true|True|TRUE|1|yes|Yes|YES) want_on=1 ;;
  *) want_on=0 ;;
esac

# The server entry — no-clone uvx form. [sourced — unverified]
SERVER_JSON='{"command":"uvx","args":["--from","git+https://github.com/ast-grep/ast-grep-mcp","ast-grep-server"],"env":{}}'

# --- load current .mcp.json: missing/empty/blank => {}; malformed => refuse (don't clobber) ---
# jq emits zero outputs (and exits 0) on empty/whitespace input, so a blank file would
# otherwise yield current="" and either write a lone-newline non-mount or leave litter.
if [ ! -f "$PROJECT_MCP" ] || [ ! -s "$PROJECT_MCP" ]; then
  current='{}'
elif ! current=$(jq -c '.' "$PROJECT_MCP" 2>/dev/null); then
  printf 'mount_mcp.sh: %s is not valid JSON; refusing to modify it\n' "$PROJECT_MCP" >&2
  exit 1
fi
[ -n "$current" ] || current='{}'   # whitespace-only file => jq emitted nothing => treat as {}

if [ "$want_on" = "1" ]; then
  # Ensure mcpServers[SERVER_KEY] = entry, preserving every other server and top-level key.
  updated=$(printf '%s' "$current" \
    | jq --arg k "$SERVER_KEY" --argjson e "$SERVER_JSON" \
        '.mcpServers = ((.mcpServers // {}) | .[$k] = $e)')
  mkdir -p "$(dirname "$PROJECT_MCP")"
  printf '%s\n' "$updated" > "$PROJECT_MCP"
else
  # Unmount: nothing to do if the file is absent.
  [ -f "$PROJECT_MCP" ] || exit 0
  # Remove only our entry; drop an emptied mcpServers; remove the file only if it then
  # holds nothing else (off mounts nothing, no empty litter).
  updated=$(printf '%s' "$current" \
    | jq --arg k "$SERVER_KEY" \
        'if .mcpServers then .mcpServers |= del(.[$k]) else . end
         | if (.mcpServers == {}) then del(.mcpServers) else . end')
  if [ "$(printf '%s' "$updated" | jq -c '.')" = "{}" ]; then
    rm -f "$PROJECT_MCP"
  else
    printf '%s\n' "$updated" > "$PROJECT_MCP"
  fi
fi
