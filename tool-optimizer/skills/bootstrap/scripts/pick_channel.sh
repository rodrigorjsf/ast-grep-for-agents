#!/bin/sh
# WHAT: Picks the install channel for ONE missing tool: a non-privileged command to run,
#       or a manual (text-only) fallback when nothing eligible is installed.
# WHY:  ADR-0003 — the bootstrap may install a missing tool, but only through a
#       non-privileged channel it can run on confirmation. It must NEVER auto-run `sudo`
#       or `curl … | sh`; those are surfaced as text for the user to run themselves. This
#       script is the canonical, deterministic (tool, managers, OS) -> channel decision
#       that the bootstrap skill consults per tool. It does NOT install, prompt, or probe;
#       it only decides — the HITL consent + execution + re-probe lives in SKILL.md.
# WHEN: Called once per Missing tool by the bootstrap skill, after package-manager
#       detection has produced the available-managers set.
# HOW:  Usage: sh pick_channel.sh <tool> <managers-csv> <os>
#         <tool>         one of the 10 core tools (ripgrep, ast-grep, semgrep, repomix,
#                        files-to-prompt, markitdown, duckdb, qsv, universal-ctags, rtk).
#         <managers-csv> comma-separated installed managers, e.g. "brew,cargo" (may be "").
#                        Recognised: brew npm pipx uv cargo scoop winget.
#         <os>           linux | wsl | macos | windows  (wsl is treated as linux).
#       Output (one line, fields TAB-separated):
#         RUN<TAB><command>     a non-privileged command the bootstrap may run on consent.
#         MANUAL<TAB><command>  advice only — never auto-run (covers the sudo / curl|sh /
#                               from-source paths, and the "no eligible manager" case).
#       Exit: 0 on a decision (RUN or MANUAL); 2 on an unknown tool.
#
#       Channel + privilege model (all commands sourced from docs/tools/*.md and the
#       recommended-stack table in docs/tools/00-overview.md):
#         - Non-privileged, auto-runnable managers: brew npm pipx uv cargo scoop winget
#           (the exact set ADR-0003 names). `pip`, `sudo apt/dnf`, and `curl … | sh` are
#           MANUAL-only by rule.
#         - OS eligibility: brew is excluded on Windows; scoop/winget are Windows-only.
#         - Preference order (first eligible installed manager wins): brew > cargo > pipx
#           > uv > npm > scoop > winget.

set -e

TOOL="$1"
MANAGERS="$2"
OS="$3"

if [ -z "$TOOL" ]; then
  printf 'pick_channel: usage: pick_channel.sh <tool> <managers-csv> <os>\n' >&2
  exit 2
fi

# Normalise WSL to Linux (same channels, same manual fallback).
[ "$OS" = "wsl" ] && OS="linux"

# chan <tool> <manager> -> prints the install command for that pair, or nothing.
# Empty output means "this tool has no channel via this manager" (e.g. files-to-prompt
# has no brew channel — the manager-present-but-wrong-tool case).
chan() {
  case "$1" in
    ripgrep) case "$2" in
        brew)   echo "brew install ripgrep" ;;
        cargo)  echo "cargo install ripgrep" ;;
        scoop)  echo "scoop install ripgrep" ;;
        winget) echo "winget install BurntSushi.ripgrep.MSVC" ;;
      esac ;;
    ast-grep) case "$2" in
        brew)   echo "brew install ast-grep" ;;
        cargo)  echo "cargo install ast-grep --locked" ;;
        npm)    echo "npm install -g @ast-grep/cli" ;;
        scoop)  echo "scoop install ast-grep" ;;
      esac ;;
    semgrep) case "$2" in
        brew)   echo "brew install semgrep" ;;
        pipx)   echo "pipx install semgrep" ;;
        uv)     echo "uv tool install semgrep" ;;
      esac ;;
    repomix) case "$2" in
        brew)   echo "brew install repomix" ;;
        npm)    echo "npm install -g repomix" ;;
      esac ;;
    files-to-prompt) case "$2" in
        pipx)   echo "pipx install files-to-prompt" ;;
        uv)     echo "uv tool install files-to-prompt" ;;
      esac ;;
    markitdown) case "$2" in
        pipx)   echo "pipx install 'markitdown[all]'" ;;
        uv)     echo "uv tool install 'markitdown[all]'" ;;
      esac ;;
    duckdb) case "$2" in
        brew)   echo "brew install duckdb" ;;
        scoop)  echo "scoop install duckdb" ;;
        winget) echo "winget install DuckDB.cli" ;;
      esac ;;
    qsv) case "$2" in
        brew)   echo "brew install qsv" ;;
        scoop)  echo "scoop install qsv" ;;
      esac ;;
    universal-ctags) case "$2" in
        brew)   echo "brew install universal-ctags" ;;
        scoop)  echo "scoop install universal-ctags" ;;
      esac ;;
    rtk) case "$2" in
        cargo)  echo "cargo install rtk" ;;
      esac ;;
    *) return 2 ;;
  esac
}

# manual <tool> <os> -> the text-only fallback when no eligible manager is installed.
# May reference sudo / curl|sh / pip / from-source: those are advice, never auto-run.
manual() {
  case "$1" in
    ripgrep)         case "$2" in macos) echo "brew install ripgrep" ;; windows) echo "winget install BurntSushi.ripgrep.MSVC" ;; *) echo "sudo apt install ripgrep" ;; esac ;;
    ast-grep)        case "$2" in windows) echo "scoop install ast-grep" ;; *) echo "brew install ast-grep" ;; esac ;;
    semgrep)         echo "python3 -m pip install semgrep" ;;
    repomix)         echo "npx repomix@latest" ;;
    files-to-prompt) echo "pip install files-to-prompt" ;;
    markitdown)      echo "pip install 'markitdown[all]'" ;;
    duckdb)          case "$2" in macos) echo "brew install duckdb" ;; windows) echo "winget install DuckDB.cli" ;; *) echo "curl https://install.duckdb.org | sh" ;; esac ;;
    qsv)             case "$2" in macos) echo "brew install qsv" ;; windows) echo "scoop install qsv" ;; *) echo "cargo build --release --locked --bin qsv --features all_features" ;; esac ;;
    universal-ctags) case "$2" in macos) echo "brew install universal-ctags" ;; windows) echo "scoop install universal-ctags" ;; *) echo "sudo apt install universal-ctags" ;; esac ;;
    rtk)             echo "cargo install rtk" ;;
  esac
}

# Validate the tool up front (unknown tool -> exit 2, distinct from a MANUAL decision).
if ! chan "$TOOL" "__probe__" >/dev/null 2>&1; then
  printf 'pick_channel: unknown tool: %s\n' "$TOOL" >&2
  exit 2
fi

# os_eligible <manager> <os> -> 0 if this manager is usable on this OS.
os_eligible() {
  case "$2" in
    windows) [ "$1" = "brew" ] && return 1 ;;            # no Homebrew on Windows
    *)       case "$1" in scoop|winget) return 1 ;; esac ;;  # scoop/winget are Windows-only
  esac
  return 0
}

# Walk managers in preference order; first installed + OS-eligible one that has a channel
# for this tool wins.
for m in brew cargo pipx uv npm scoop winget; do
  case ",$MANAGERS," in *",$m,"*) ;; *) continue ;; esac   # is m in the available set?
  os_eligible "$m" "$OS" || continue
  cmd=$(chan "$TOOL" "$m")
  [ -n "$cmd" ] || continue
  printf 'RUN\t%s\n' "$cmd"
  exit 0
done

printf 'MANUAL\t%s\n' "$(manual "$TOOL" "$OS")"
