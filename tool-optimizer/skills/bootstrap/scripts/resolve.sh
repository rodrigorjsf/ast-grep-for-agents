#!/bin/sh
# WHAT: Merges global and project tool-optimizer configs with key-by-key resolution.
# WHY:  There are two config scopes: global (~/.claude/tool-optimizer/config.json)
#       holds the machine inventory + default policy; project (.claude/tool-optimizer.local.json)
#       holds project-specific overrides. Resolution is shallow/key-by-key: project[key] wins
#       when present; absent project keys fall back to global. This script is the canonical
#       implementation of that resolution rule.
# WHEN: Run to obtain the effective config for the current project context. Called by hooks
#       or skills that need the resolved view (not the raw global or project file alone).
# HOW:  Injectable env vars (all optional):
#         GLOBAL_CONFIG   path to the global config JSON
#                         (default: ${HOME}/.claude/tool-optimizer/config.json)
#         PROJECT_CONFIG  path to the project config JSON
#                         (default: .claude/tool-optimizer.local.json)
#         TO_RESOLVE_OUT  if set, write output to this file instead of stdout
#       Output: the resolved config JSON (stdout, or TO_RESOLVE_OUT if set).
#       Missing files are treated as {} — resolve never errors on absent scope files.
#
#       NOTE on writing to global scope: detect.sh and render.sh already accept injectable
#       output-path env vars (TO_OUTPUT, TO_RENDER_OUT). To write the global scope, invoke
#       them with the global path:
#         TO_OUTPUT="$HOME/.claude/tool-optimizer/config.json" sh detect.sh
#         TO_RENDER_OUT="$HOME/.claude/tool-optimizer/tool-optimizer.local.md" sh render.sh
#       resolve.sh only READS both scopes; it does not write to either.
#
#       Merge rule: jq -s '.[0] + .[1]' global project
#       The jq + operator on objects: right operand (project) wins per key. This is the
#       exact shallow key-by-key merge the resolution rule specifies. Deep merge (*) is NOT used.
#
#       Usage:
#         sh resolve.sh
#         GLOBAL_CONFIG=/tmp/g.json PROJECT_CONFIG=/tmp/p.json sh resolve.sh
#         TO_RESOLVE_OUT=/tmp/resolved.json sh resolve.sh

set -e

GLOBAL_CONFIG="${GLOBAL_CONFIG:-${HOME}/.claude/tool-optimizer/config.json}"
PROJECT_CONFIG="${PROJECT_CONFIG:-.claude/tool-optimizer.local.json}"

# Load each scope, treating missing files as {}.
load_json() {
  _file="$1"
  if [ -f "$_file" ]; then
    cat "$_file"
  else
    printf '{}'
  fi
}

GLOBAL_JSON=$(load_json "$GLOBAL_CONFIG")
PROJECT_JSON=$(load_json "$PROJECT_CONFIG")

# Merge: global is the base (.[0]), project overrides per top-level key (.[1]).
# jq + on objects: right operand wins on collision. Shallow (key-by-key), not deep.
RESOLVED=$(printf '%s\n%s\n' "$GLOBAL_JSON" "$PROJECT_JSON" | jq -s '.[0] + .[1]')

if [ -n "$TO_RESOLVE_OUT" ]; then
  mkdir -p "$(dirname "$TO_RESOLVE_OUT")"
  printf '%s\n' "$RESOLVED" > "$TO_RESOLVE_OUT"
else
  printf '%s\n' "$RESOLVED"
fi
