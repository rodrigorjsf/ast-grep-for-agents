#!/bin/sh
# WHAT: Probes the 10 core tool-optimizer tools and writes a deterministic inventory JSON.
# WHY:  The SessionStart hook and bootstrap skill need a machine-local snapshot of which
#       tools are available, their versions, and where they live — without re-probing on
#       every session start.
# WHEN: Run once per machine (or after installing new tools) to refresh the inventory.
#       Re-running produces a byte-identical file except for the detectedAt timestamp.
# HOW:  Set TO_OUTPUT to override the output path (default: ${TO_STATE_DIR}/tool-optimizer.local.json).
#       TO_STATE_DIR is the harness-agnostic state-dir umbrella (default: .claude), so the
#       shipped Claude plugin is UNCHANGED; the Cursor host sets TO_STATE_DIR=.cursor. An
#       explicitly-set TO_OUTPUT still wins (granular beats umbrella).
#       Set TO_NOW to pin the detectedAt value (used by seam tests for determinism).
#       The PATH is read from the environment, so stubbing PATH in tests changes results.
#       Usage: sh detect.sh
#              TO_OUTPUT=/tmp/out.json TO_NOW="2026-01-01T00:00:00Z" sh detect.sh
#              TO_STATE_DIR=.cursor sh detect.sh   # writes .cursor/tool-optimizer.local.json

set -e

STATE_DIR="${TO_STATE_DIR:-.claude}"
OUTPUT="${TO_OUTPUT:-${STATE_DIR}/tool-optimizer.local.json}"
DETECTED_AT="${TO_NOW:-$(date -u +"%Y-%m-%dT%H:%M:%SZ")}"

# probe_tool: resolve a binary and capture its version.
# Prints a JSON fragment: "available": bool, "version": str, "path": str
# $1 = binary name
# $2 = version flag(s) passed to the binary (e.g. "--version")
probe_tool() {
  _bin="$1"
  _vflag="$2"
  _path=""
  _path=$(command -v "$_bin" 2>/dev/null) || true
  if [ -n "$_path" ]; then
    _ver=""
    _ver=$("$_bin" "$_vflag" 2>/dev/null | head -1) || true
    # Strip leading words/prefixes, keep the first version-like token (digits + dots + suffix)
    _ver=$(printf '%s' "$_ver" | sed 's/^[^0-9]*\([0-9][0-9a-zA-Z._-]*\).*/\1/')
    printf '"available": true, "version": "%s", "path": "%s"' \
      "$(printf '%s' "$_ver" | sed 's/\\/\\\\/g; s/"/\\"/g')" \
      "$(printf '%s' "$_path" | sed 's/\\/\\\\/g; s/"/\\"/g')"
  else
    printf '"available": false, "version": "", "path": ""'
  fi
}

# probe_ctags: ctags is Available only when Universal AND json-capable.
probe_ctags() {
  _path=""
  _path=$(command -v ctags 2>/dev/null) || true
  if [ -n "$_path" ]; then
    _is_universal=0
    _is_json=0
    ctags --version 2>/dev/null | grep -qi "universal" && _is_universal=1 || true
    ctags --list-features 2>/dev/null | grep -q "json" && _is_json=1 || true
    if [ "$_is_universal" -eq 1 ] && [ "$_is_json" -eq 1 ]; then
      _ver=""
      _ver=$(ctags --version 2>/dev/null | head -1 | sed 's/^[^0-9]*\([0-9][0-9a-zA-Z._-]*\).*/\1/')
      printf '"available": true, "version": "%s", "path": "%s"' \
        "$(printf '%s' "$_ver" | sed 's/\\/\\\\/g; s/"/\\"/g')" \
        "$(printf '%s' "$_path" | sed 's/\\/\\\\/g; s/"/\\"/g')"
      return
    fi
  fi
  printf '"available": false, "version": "", "path": ""'
}

# Probe all 10 core tools.
# Binary names: ripgrep->rg, ast-grep->ast-grep, semgrep->semgrep,
#   repomix->repomix, files-to-prompt->files-to-prompt, markitdown->markitdown,
#   duckdb->duckdb, qsv->qsv, universal-ctags->ctags, rtk->rtk
ast_grep_f=$(probe_tool "ast-grep" "--version")
duckdb_f=$(probe_tool "duckdb" "--version")
ftp_f=$(probe_tool "files-to-prompt" "--version")
markitdown_f=$(probe_tool "markitdown" "--version")
qsv_f=$(probe_tool "qsv" "--version")
repomix_f=$(probe_tool "repomix" "--version")
ripgrep_f=$(probe_tool "rg" "--version")
rtk_f=$(probe_tool "rtk" "--version")
semgrep_f=$(probe_tool "semgrep" "--version")
ctags_f=$(probe_ctags)

# Ensure the output directory exists.
mkdir -p "$(dirname "$OUTPUT")"

# Emit deterministic JSON: tool keys in alphabetical order, detectedAt last.
# Keys sorted: ast-grep, duckdb, files-to-prompt, markitdown, qsv, repomix, ripgrep, rtk, semgrep, universal-ctags, detectedAt
cat > "$OUTPUT" <<ENDJSON
{
  "ast-grep": { ${ast_grep_f}, "category": "structural", "installHint": "brew install ast-grep" },
  "duckdb": { ${duckdb_f}, "category": "tabular", "installHint": "brew install duckdb" },
  "files-to-prompt": { ${ftp_f}, "category": "context-packing", "installHint": "pip install files-to-prompt" },
  "markitdown": { ${markitdown_f}, "category": "doc", "installHint": "pip install markitdown" },
  "qsv": { ${qsv_f}, "category": "tabular", "installHint": "brew install qsv" },
  "repomix": { ${repomix_f}, "category": "context-packing", "installHint": "brew install repomix" },
  "ripgrep": { ${ripgrep_f}, "category": "text", "installHint": "brew install ripgrep" },
  "rtk": { ${rtk_f}, "category": "persistence-or-codenav", "installHint": "cargo install rtk" },
  "semgrep": { ${semgrep_f}, "category": "structural", "installHint": "brew install semgrep" },
  "universal-ctags": { ${ctags_f}, "category": "persistence-or-codenav", "installHint": "brew install universal-ctags" },
  "detectedAt": "${DETECTED_AT}"
}
ENDJSON
