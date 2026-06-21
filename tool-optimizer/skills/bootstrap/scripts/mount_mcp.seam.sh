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

SCRIPT_DIR="$(dirname "$0")"
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
# Case 9: a malformed resolved config must ABORT, never silently unmount
# ============================================================================
badcfg="$tmpdir/bad-config.json"; printf '{ this is not json' > "$badcfg"
cat > "$MCP" <<'ENDJSON'
{ "mcpServers": { "ast-grep": { "command": "uvx", "args": [], "env": {} }, "other": { "command": "x", "args": [] } } }
ENDJSON
if env -u TO_MCP_SETTING GLOBAL_CONFIG="$tmpdir/no-global.json" PROJECT_CONFIG="$badcfg" PROJECT_MCP="$MCP" \
     "$SH_BIN" "$MOUNT_SH" 2>/dev/null; then
  fail "case9: malformed config should abort non-zero, not 'succeed' as off"
fi
jq -e '.mcpServers["ast-grep"]' "$MCP" >/dev/null \
  || fail "case9: ast-grep entry must survive when config resolution fails"
echo "  [ok] malformed config: aborts without silently unmounting"

echo "mount_mcp seam ok"
exit 0
