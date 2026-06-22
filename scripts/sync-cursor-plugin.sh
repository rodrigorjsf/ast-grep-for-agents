#!/bin/sh
# WHAT: Single-source sync for the Cursor port. Copies the 10 harness-AGNOSTIC shell
#       scripts from the canonical Claude plugin (tool-optimizer/) into the sibling Cursor
#       plugin (cursor-tool-optimizer/) as COMMITTED, byte-identical copies.
# WHY:  Plugin installs git-clone the WHOLE plugin directory and the self-contained-artifact
#       rule forbids a runtime reference outside a plugin's own dir, so the two plugins cannot
#       share scripts by symlink or ../shared/ at runtime — each must carry its own committed
#       copy (see docs/adr/0009-...). "Sharing" therefore means single source + copy step.
#       The 10 scripts are made harness-agnostic by env-var parameterization (TO_STATE_DIR
#       umbrella + granular overrides + TO_MCP_CONFIG), so ONE source works in both harnesses;
#       the host hook/skill sets the env. The forked, harness-COUPLED artifacts
#       (session-start-policy.sh, nudge.sh, hooks.json, the .mdc Rule, plugin.json) are NOT
#       synced — they live independently in cursor-tool-optimizer/.
# WHEN: Run after editing ANY of the 10 agnostic source scripts, BEFORE committing. The drift
#       gate (scripts/check-cursor-drift.sh, also wired into scripts/check-docs.py) FAILS the
#       build if a committed copy diverges from its source, so a forgotten re-sync is caught.
# HOW:  sh scripts/sync-cursor-plugin.sh   (run from the repo root; self-locates via $0).
#       Copies are made with `cp -p` to preserve content AND mode (+x). The destination dirs
#       are created as needed. census.sh is the "prove the pipe" exemplar — copied FIRST.
#       POSIX sh only — no bashisms, no [[ ]], no arrays. Exits non-zero on any copy failure.

set -e

# --- self-locate the repo root (this script lives at <root>/scripts/) ---
SCRIPT_DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
ROOT=$(CDPATH= cd -- "$SCRIPT_DIR/.." && pwd)

SRC_PLUGIN="$ROOT/tool-optimizer"
DST_PLUGIN="$ROOT/cursor-tool-optimizer"

# --- the 10 harness-agnostic scripts (plugin-relative paths shared by both plugins) ---
# census.sh is the genuinely-pure "prove the pipe" exemplar — synced FIRST (AC6).
# bootstrap: census(pure exemplar) detect rank pick_channel render resolve mount_mcp
# report-error: sanitize file-or-pend render-comment
AGNOSTIC_SCRIPTS="
skills/bootstrap/scripts/census.sh
skills/bootstrap/scripts/detect.sh
skills/bootstrap/scripts/rank.sh
skills/bootstrap/scripts/pick_channel.sh
skills/bootstrap/scripts/render.sh
skills/bootstrap/scripts/resolve.sh
skills/bootstrap/scripts/mount_mcp.sh
skills/report-error/scripts/sanitize.sh
skills/report-error/scripts/file-or-pend.sh
skills/report-error/scripts/render-comment.sh
"

count=0
for rel in $AGNOSTIC_SCRIPTS; do
  src="$SRC_PLUGIN/$rel"
  dst="$DST_PLUGIN/$rel"
  if [ ! -f "$src" ]; then
    printf 'sync-cursor-plugin: source missing: %s\n' "$src" >&2
    exit 1
  fi
  mkdir -p "$(dirname -- "$dst")"
  # cp -p preserves content AND mode (+x), so the committed copy is byte-identical.
  cp -p "$src" "$dst"
  count=$((count + 1))
  printf 'synced: %s\n' "$rel"
done

printf 'sync-cursor-plugin: synced %d agnostic script(s) into %s\n' "$count" "cursor-tool-optimizer/"
