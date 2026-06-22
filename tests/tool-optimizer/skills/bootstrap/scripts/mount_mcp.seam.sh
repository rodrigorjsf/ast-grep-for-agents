#!/bin/sh
# WHAT: Seam test for mount_mcp.sh — verifies the opt-in MCP mount/unmount contract.
# WHY:  mount_mcp.sh writes a committable project .mcp.json. The contract that gates
#       correctness: `on` adds the ast-grep server entry, `off` removes ONLY that entry,
#       other servers and unrelated top-level keys are always preserved, and the file is
#       deleted only when nothing else remains (off mounts nothing, no empty litter).
# WHEN: Run by the CI/test gate automatically (filename contains "seam").
# HOW:  Drives mount_mcp.sh with TO_MCP_SETTING + PROJECT_MCP pointed at a temp file, so it
#       never touches a real .mcp.json or the resolved config. Asserts with jq. Cleans up on
#       exit. POSIX sh only.

set -e

SCRIPT_DIR="$(CDPATH= cd -- "$(dirname "$0")" && pwd)"
SCRIPT_DIR="$(printf '%s' "$SCRIPT_DIR" | sed 's#/tests/tool-optimizer/#/tool-optimizer/#')"
MOUNT_SH="$SCRIPT_DIR/mount_mcp.sh"
SH_BIN=$(command -v sh)

command -v jq >/dev/null 2>&1 || { echo "  [skip] jq not present — mount_mcp needs jq"; echo "mount_mcp seam ok"; exit 0; }

tmpdir=$(mktemp -d)
trap 'rm -rf "$tmpdir"' EXIT

fail() { printf 'FAIL: %s\n' "$1" >&2; exit 1; }

MCP="$tmpdir/.mcp.json"

# ============================================================================
# Case 1: off + no pre-existing file → file stays absent (off mounts nothing)
# ============================================================================
TO_MCP_SETTING=off PROJECT_MCP="$MCP" "$SH_BIN" "$MOUNT_SH" || fail "off/no-file exited non-zero"
[ ! -f "$MCP" ] || fail "case1: .mcp.json should be absent when off and none existed"
echo "  [ok] off + no file: nothing written"

# ============================================================================
# Case 2: on (no pre-existing) → file present, ast-grep entry with command uvx
# ============================================================================
TO_MCP_SETTING=on PROJECT_MCP="$MCP" "$SH_BIN" "$MOUNT_SH" || fail "on exited non-zero"
[ -f "$MCP" ] || fail "case2: .mcp.json should exist after on"
jq -e '.mcpServers["ast-grep"].command == "uvx"' "$MCP" >/dev/null || fail "case2: ast-grep command should be uvx"
jq -e '.mcpServers["ast-grep"].args | index("git+https://github.com/ast-grep/ast-grep-mcp")' "$MCP" >/dev/null \
  || fail "case2: ast-grep args should reference the upstream git source"
echo "  [ok] on: ast-grep server entry written (uvx, upstream git source)"

# ============================================================================
# Case 3: on with a pre-existing OTHER server → both preserved
# ============================================================================
cat > "$MCP" <<'ENDJSON'
{ "mcpServers": { "other": { "command": "other-bin", "args": [] } } }
ENDJSON
TO_MCP_SETTING=on PROJECT_MCP="$MCP" "$SH_BIN" "$MOUNT_SH" || fail "on/with-other exited non-zero"
jq -e '.mcpServers["ast-grep"].command == "uvx"' "$MCP" >/dev/null || fail "case3: ast-grep entry missing"
jq -e '.mcpServers["other"].command == "other-bin"' "$MCP" >/dev/null || fail "case3: other server clobbered"
echo "  [ok] on: ast-grep added, pre-existing 'other' server preserved"

# ============================================================================
# Case 4: off with a pre-existing OTHER server → only ours removed, file kept
# ============================================================================
TO_MCP_SETTING=off PROJECT_MCP="$MCP" "$SH_BIN" "$MOUNT_SH" || fail "off/with-other exited non-zero"
[ -f "$MCP" ] || fail "case4: file should survive (it still has 'other')"
jq -e '.mcpServers["ast-grep"] == null' "$MCP" >/dev/null || fail "case4: ast-grep entry should be gone"
jq -e '.mcpServers["other"].command == "other-bin"' "$MCP" >/dev/null || fail "case4: other server should remain"
echo "  [ok] off: only ast-grep removed, 'other' server preserved, file kept"

# ============================================================================
# Case 5: on then off when ours is the ONLY content → file removed
# ============================================================================
rm -f "$MCP"
TO_MCP_SETTING=on  PROJECT_MCP="$MCP" "$SH_BIN" "$MOUNT_SH" || fail "case5 on exited non-zero"
[ -f "$MCP" ] || fail "case5: file should exist after on"
TO_MCP_SETTING=off PROJECT_MCP="$MCP" "$SH_BIN" "$MOUNT_SH" || fail "case5 off exited non-zero"
[ ! -f "$MCP" ] || fail "case5: file should be removed when only ours remained"
echo "  [ok] on then off (only ours): file removed cleanly"

# ============================================================================
# Case 6: off preserves an unrelated top-level key → file kept
# ============================================================================
cat > "$MCP" <<'ENDJSON'
{ "mcpServers": { "ast-grep": { "command": "uvx", "args": [], "env": {} } }, "someOtherKey": 1 }
ENDJSON
TO_MCP_SETTING=off PROJECT_MCP="$MCP" "$SH_BIN" "$MOUNT_SH" || fail "case6 off exited non-zero"
[ -f "$MCP" ] || fail "case6: file should survive (it has someOtherKey)"
jq -e '.someOtherKey == 1' "$MCP" >/dev/null || fail "case6: unrelated key should be preserved"
jq -e 'has("mcpServers") | not' "$MCP" >/dev/null || fail "case6: emptied mcpServers should be dropped"
echo "  [ok] off: emptied mcpServers dropped, unrelated key preserved, file kept"

# ============================================================================
# Case 7: on over an EMPTY pre-existing file → entry still written (not a silent no-op)
# ============================================================================
: > "$MCP"   # empty file (exists, 0 bytes)
TO_MCP_SETTING=on PROJECT_MCP="$MCP" "$SH_BIN" "$MOUNT_SH" || fail "case7 on/empty exited non-zero"
jq -e '.mcpServers["ast-grep"].command == "uvx"' "$MCP" >/dev/null \
  || fail "case7: on over an empty file must still write the ast-grep entry"
echo "  [ok] on over empty file: entry written (no silent no-op)"

# ============================================================================
# Case 8: off over an EMPTY pre-existing file → removed, no lone-newline litter
# ============================================================================
printf '   \n' > "$MCP"   # whitespace-only file
TO_MCP_SETTING=off PROJECT_MCP="$MCP" "$SH_BIN" "$MOUNT_SH" || fail "case8 off/blank exited non-zero"
[ ! -f "$MCP" ] || fail "case8: off over a blank file must delete it (no empty litter)"
echo "  [ok] off over blank file: deleted (no litter)"

# ============================================================================
# Case 9: the REAL user switch — `mcp: on` in the .local.md settings frontmatter, with
#         TO_MCP_SETTING UNSET, mounts the server (drives the config-file path, not the
#         injected override).
# ============================================================================
rm -f "$MCP"
proj_md="$tmpdir/project.local.md"
printf '%s\n' '---' 'enabled: true' 'mcp: on' '---' '## body block (rendered)' > "$proj_md"
env -u TO_MCP_SETTING PROJECT_SETTINGS="$proj_md" GLOBAL_SETTINGS="$tmpdir/none.md" PROJECT_MCP="$MCP" \
  "$SH_BIN" "$MOUNT_SH" || fail "case9: frontmatter mcp:on exited non-zero"
jq -e '.mcpServers["ast-grep"].command == "uvx"' "$MCP" >/dev/null \
  || fail "case9: 'mcp: on' in .local.md frontmatter must mount the server"
echo "  [ok] switch on: 'mcp: on' in .local.md frontmatter mounts (no injected setting)"

# ============================================================================
# Case 10: `mcp: off` (and absent) in frontmatter unmounts / mounts nothing.
# ============================================================================
printf '%s\n' '---' 'mcp: off' '---' '## body' > "$proj_md"
env -u TO_MCP_SETTING PROJECT_SETTINGS="$proj_md" GLOBAL_SETTINGS="$tmpdir/none.md" PROJECT_MCP="$MCP" \
  "$SH_BIN" "$MOUNT_SH" || fail "case10: frontmatter mcp:off exited non-zero"
[ ! -f "$MCP" ] || fail "case10: 'mcp: off' must remove our entry (file gone, only ours)"
echo "  [ok] switch off: 'mcp: off' in frontmatter unmounts"

# ============================================================================
# Case 11: project frontmatter wins over global (project mcp:on beats global mcp:off).
# ============================================================================
rm -f "$MCP"
glob_md="$tmpdir/global.local.md"
printf '%s\n' '---' 'mcp: off' '---' > "$glob_md"
printf '%s\n' '---' 'mcp: on' '---' > "$proj_md"
env -u TO_MCP_SETTING PROJECT_SETTINGS="$proj_md" GLOBAL_SETTINGS="$glob_md" PROJECT_MCP="$MCP" \
  "$SH_BIN" "$MOUNT_SH" || fail "case11 exited non-zero"
jq -e '.mcpServers["ast-grep"]' "$MCP" >/dev/null \
  || fail "case11: project 'mcp: on' must win over global 'mcp: off'"
echo "  [ok] resolution: project frontmatter wins over global"

# ============================================================================
# Case 12: STATE-DIR CONTRACT — TO_STATE_DIR drives the PROJECT_SETTINGS default
#   (where `mcp:` is read from), but does NOT move PROJECT_MCP. The cases above
#   pin PROJECT_SETTINGS, which does NOT exercise its default. Here PROJECT_SETTINGS
#   and TO_MCP_SETTING are UNSET and mount runs from a tmp CWD, so the derived
#   PROJECT_SETTINGS default is observable. GLOBAL_SETTINGS is pointed at a tmp
#   nonexistent path so the test never reads the real $HOME. PROJECT_MCP is always
#   pinned into the tmpdir so nothing touches the worktree's .mcp.json.
#     - TO_STATE_DIR unset   -> reads mcp from .claude/tool-optimizer.local.md (backward-compat).
#     - TO_STATE_DIR=.cursor -> reads mcp from .cursor/tool-optimizer.local.md  (Cursor port).
# ============================================================================
SD_CWD="$tmpdir/sd-cwd"
NO_GLOBAL_MD="$tmpdir/no_such_global.md"   # nonexistent -> read_frontmatter_scalar returns nothing
SD_MCP="$tmpdir/sd.mcp.json"

# --- default (umbrella unset): seed `mcp: on` under .claude -> server mounts ---
mkdir -p "$SD_CWD/.claude"
printf '%s\n' '---' 'mcp: on' '---' '## body' > "$SD_CWD/.claude/tool-optimizer.local.md"
rm -f "$SD_MCP"
( cd "$SD_CWD" && env -u TO_MCP_SETTING -u PROJECT_SETTINGS -u TO_STATE_DIR \
    GLOBAL_SETTINGS="$NO_GLOBAL_MD" PROJECT_MCP="$SD_MCP" "$SH_BIN" "$MOUNT_SH" ) \
  || fail "state-dir/default: mount_mcp.sh exited non-zero with TO_STATE_DIR unset"
jq -e '.mcpServers["ast-grep"].command == "uvx"' "$SD_MCP" >/dev/null \
  || fail "state-dir/default: 'mcp: on' in the .claude default settings must mount the server"
echo "  [ok] state-dir default: PROJECT_SETTINGS resolves under .claude with umbrella unset"

# --- umbrella=.cursor: seed `mcp: on` under .cursor -> server mounts ---
mkdir -p "$SD_CWD/.cursor"
printf '%s\n' '---' 'mcp: on' '---' '## body' > "$SD_CWD/.cursor/tool-optimizer.local.md"
# Make the .claude default mcp:off so a mount can ONLY come from the .cursor file.
printf '%s\n' '---' 'mcp: off' '---' '## body' > "$SD_CWD/.claude/tool-optimizer.local.md"
rm -f "$SD_MCP"
( cd "$SD_CWD" && env -u TO_MCP_SETTING -u PROJECT_SETTINGS TO_STATE_DIR=".cursor" \
    GLOBAL_SETTINGS="$NO_GLOBAL_MD" PROJECT_MCP="$SD_MCP" "$SH_BIN" "$MOUNT_SH" ) \
  || fail "state-dir/cursor: mount_mcp.sh exited non-zero with TO_STATE_DIR=.cursor"
jq -e '.mcpServers["ast-grep"].command == "uvx"' "$SD_MCP" >/dev/null \
  || fail "state-dir/cursor: 'mcp: on' in the .cursor default settings must mount the server"
echo "  [ok] state-dir cursor: PROJECT_SETTINGS resolves under .cursor with TO_STATE_DIR=.cursor"

# --- granular wins: explicit PROJECT_SETTINGS beats the umbrella ---
GRAN_MD="$tmpdir/granular-settings.md"
printf '%s\n' '---' 'mcp: on' '---' '## body' > "$GRAN_MD"
# .cursor default is mcp:off, so a mount proves the explicit PROJECT_SETTINGS won.
printf '%s\n' '---' 'mcp: off' '---' '## body' > "$SD_CWD/.cursor/tool-optimizer.local.md"
rm -f "$SD_MCP"
( cd "$SD_CWD" && env -u TO_MCP_SETTING TO_STATE_DIR=".cursor" PROJECT_SETTINGS="$GRAN_MD" \
    GLOBAL_SETTINGS="$NO_GLOBAL_MD" PROJECT_MCP="$SD_MCP" "$SH_BIN" "$MOUNT_SH" ) \
  || fail "state-dir/granular: mount_mcp.sh exited non-zero with PROJECT_SETTINGS + TO_STATE_DIR"
jq -e '.mcpServers["ast-grep"].command == "uvx"' "$SD_MCP" >/dev/null \
  || fail "state-dir/granular: explicit PROJECT_SETTINGS must win over the .cursor umbrella default"
echo "  [ok] state-dir granular: explicit PROJECT_SETTINGS wins over umbrella"

# ============================================================================
# Case 13: PROJECT_MCP is a path MOVE (TO_MCP_CONFIG), NOT a .claude->.cursor swap.
#   TO_STATE_DIR=.cursor must NOT move the MCP config default — it stays .mcp.json
#   at the repo root (per ADR-0009 the Cursor host sets TO_MCP_CONFIG explicitly).
#   This guards against a naive ${STATE_DIR}/mcp.json prefix.
# ============================================================================
SD_MCP_CWD="$tmpdir/sd-mcp-cwd"
mkdir -p "$SD_MCP_CWD"
( cd "$SD_MCP_CWD" && env -u PROJECT_MCP -u TO_MCP_CONFIG TO_STATE_DIR=".cursor" \
    TO_MCP_SETTING=on "$SH_BIN" "$MOUNT_SH" ) \
  || fail "case13: mount_mcp.sh exited non-zero (default MCP path, TO_STATE_DIR=.cursor)"
[ -f "$SD_MCP_CWD/.mcp.json" ] \
  || fail "case13: TO_STATE_DIR=.cursor must NOT move the MCP config — it must stay .mcp.json at root"
[ ! -e "$SD_MCP_CWD/.cursor/mcp.json" ] \
  || fail "case13: TO_STATE_DIR must NOT prefix the MCP config into .cursor/ (path MOVE, not swap)"
echo "  [ok] case13: TO_STATE_DIR does NOT move PROJECT_MCP default (stays .mcp.json)"

# --- TO_MCP_CONFIG performs the explicit path MOVE (Cursor host sets it) ---
MOVED_MCP="$tmpdir/moved/mcp.json"
rm -rf "$tmpdir/moved"
env TO_MCP_CONFIG="$MOVED_MCP" TO_MCP_SETTING=on "$SH_BIN" "$MOUNT_SH" \
  || fail "case13: mount_mcp.sh exited non-zero with TO_MCP_CONFIG move"
jq -e '.mcpServers["ast-grep"].command == "uvx"' "$MOVED_MCP" >/dev/null \
  || fail "case13: TO_MCP_CONFIG must write the MCP config to the moved path"
# PROJECT_MCP wins over TO_MCP_CONFIG when both are set (most-specific alias).
ALIAS_MCP="$tmpdir/alias.mcp.json"
rm -f "$ALIAS_MCP"
env PROJECT_MCP="$ALIAS_MCP" TO_MCP_CONFIG="$tmpdir/should-not-be-used.json" TO_MCP_SETTING=on \
  "$SH_BIN" "$MOUNT_SH" \
  || fail "case13: mount_mcp.sh exited non-zero with PROJECT_MCP + TO_MCP_CONFIG"
[ -f "$ALIAS_MCP" ] || fail "case13: PROJECT_MCP must win over TO_MCP_CONFIG when both set"
[ ! -e "$tmpdir/should-not-be-used.json" ] || fail "case13: TO_MCP_CONFIG must NOT be used when PROJECT_MCP is set"
echo "  [ok] case13: TO_MCP_CONFIG moves the MCP config; PROJECT_MCP alias wins when both set"

echo "mount_mcp seam ok"
exit 0
