#!/bin/sh
# WHAT: Drift gate for the Cursor port. Asserts TRUE BYTE-IDENTITY between each of the 10
#       harness-agnostic source scripts in tool-optimizer/ and its committed copy in
#       cursor-tool-optimizer/. Exits 0 when every copy is byte-identical to its source;
#       exits non-zero (printing the offenders) if ANY copy is missing or differs by even one
#       byte. It is the SOLE CI entrypoint for the single-source contract — scripts/check-docs.py
#       shells out to it.
# WHY:  The Cursor plugin must carry its own committed copies of the agnostic scripts (plugin
#       installs git-clone the whole dir; a runtime ../shared/ reference would dangle — see
#       docs/adr/0009-...). Committed copies drift the instant a source is edited without a
#       re-sync. The whole transitive-privacy chain (sanitize.sh, file-or-pend.sh) and the
#       relevance pipeline depend on the copy being EXACTLY the audited source — so the check
#       must be byte-identity (cmp -s), NOT a content-normalizing/line-count/marker heuristic.
#       A one-byte perturbation MUST fail this gate.
# WHEN: Run in CI and before committing, after scripts/sync-cursor-plugin.sh. To recover from a
#       reported drift, re-run the sync (`sh scripts/sync-cursor-plugin.sh`), never hand-edit the
#       copy (a manual edit can leave a stray byte; re-sync guarantees byte-identity).
# HOW:  sh scripts/check-cursor-drift.sh   (run from anywhere; self-locates via $0).
#       Compares with `cmp -s` (silent exact byte compare). POSIX sh only — no bashisms.
#       exit 0 = no drift; exit 1 = drift (missing or differing copies printed to stdout).

set -e

# --- self-locate the repo root (this script lives at <root>/scripts/) ---
SCRIPT_DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
ROOT=$(CDPATH= cd -- "$SCRIPT_DIR/.." && pwd)

SRC_PLUGIN="$ROOT/tool-optimizer"
DST_PLUGIN="$ROOT/cursor-tool-optimizer"

# --- the 10 harness-agnostic scripts (must match sync-cursor-plugin.sh exactly) ---
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

drift=0
checked=0
# Iterate the canonical SOURCE list (not the copies) so a copy that was never synced is
# caught as MISSING, not silently skipped.
for rel in $AGNOSTIC_SCRIPTS; do
  src="$SRC_PLUGIN/$rel"
  dst="$DST_PLUGIN/$rel"
  if [ ! -f "$src" ]; then
    printf 'DRIFT: source missing: tool-optimizer/%s\n' "$rel"
    drift=1
    continue
  fi
  if [ ! -f "$dst" ]; then
    printf 'DRIFT: copy missing: cursor-tool-optimizer/%s (run scripts/sync-cursor-plugin.sh)\n' "$rel"
    drift=1
    continue
  fi
  # cmp -s: silent, exact byte-for-byte compare. A one-byte difference fails.
  if cmp -s "$src" "$dst"; then
    checked=$((checked + 1))
  else
    printf 'DRIFT: cursor-tool-optimizer/%s differs from tool-optimizer/%s (run scripts/sync-cursor-plugin.sh)\n' "$rel" "$rel"
    drift=1
  fi
done

if [ "$drift" -eq 0 ]; then
  printf 'cursor drift check: OK (%d agnostic script(s) byte-identical)\n' "$checked"
  exit 0
else
  printf 'cursor drift check: FAILED\n'
  exit 1
fi
