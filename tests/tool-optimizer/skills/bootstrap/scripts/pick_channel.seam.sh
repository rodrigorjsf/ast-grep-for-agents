#!/bin/sh
# WHAT: Seam test for pick_channel.sh — asserts the EXACT channel string for fixed
#       (tool, managers, OS) inputs, the manual fallback when no eligible manager exists,
#       and the manager-present-but-wrong-tool case.
# WHY:  pick_channel is the one deterministic, harness-verifiable piece of slice #7 (the
#       present/consent/install/re-probe flow around it is HITL and cannot be driven
#       here). These assertions pin the channel rules: a non-privileged command is chosen
#       when one is installed; sudo / curl|sh / from-source paths only ever appear as
#       MANUAL text, never RUN; OS eligibility excludes brew on Windows and scoop/winget
#       off Windows; preference order is brew > cargo > pipx > uv > npm > scoop > winget.
# WHEN: Run by the test gate automatically (filename contains "seam"). No jq needed.
# HOW:  POSIX sh. Each case asserts the full "<RUN|MANUAL>\t<command>" line verbatim, so
#       a wrong manager, a wrong command, or a leaked privileged auto-run all fail loudly.

set -e

SCRIPT_DIR="$(CDPATH= cd -- "$(dirname "$0")" && pwd)"
SCRIPT_DIR="$(printf '%s' "$SCRIPT_DIR" | sed 's#/tests/tool-optimizer/#/tool-optimizer/#')"
PICK="$SCRIPT_DIR/pick_channel.sh"

fails=0

# expect <tool> <managers> <os> <expected-line>
# Runs pick_channel and asserts the output equals the expected "PREFIX<TAB>command".
expect() {
  _got=$(sh "$PICK" "$1" "$2" "$3")
  _want=$(printf '%s' "$4")
  if [ "$_got" != "$_want" ]; then
    printf 'FAIL: pick_channel %s "%s" %s\n  want: %s\n  got:  %s\n' \
      "$1" "$2" "$3" "$_want" "$_got" >&2
    fails=$((fails + 1))
  fi
}

T() { printf 'RUN\t%s' "$1"; }     # build an expected RUN line
M() { printf 'MANUAL\t%s' "$1"; }  # build an expected MANUAL line

# AC2: Consented install via non-privileged channels only.
#   RUN lines are non-privileged commands the bootstrap may run after explicit consent.
#   MANUAL lines are advice-only — covers sudo/curl|sh/from-source and no-eligible-manager
#   cases. A MANUAL line is NEVER auto-run by the bootstrap.

# --- preference order: brew wins over cargo when both installed ---
expect ripgrep "brew,cargo" linux "$(T 'brew install ripgrep')"

# --- falls to the next preferred manager when brew absent ---
expect ripgrep "cargo" linux "$(T 'cargo install ripgrep')"

# --- no eligible manager -> MANUAL, OS-specific fallback (privileged, text only) ---
expect ripgrep "" linux "$(M 'sudo apt install ripgrep')"
expect ripgrep "" macos "$(M 'brew install ripgrep')"

# --- manager installed but it has NO channel for this tool -> MANUAL (not a false RUN) ---
# brew is available, but files-to-prompt is pip-family only; must fall through to MANUAL.
expect files-to-prompt "brew" linux "$(M 'pip install files-to-prompt')"

# --- pipx / uv channels for the Python-family tools ---
expect files-to-prompt "pipx" linux "$(T 'pipx install files-to-prompt')"
expect markitdown "uv" linux "$(T "uv tool install 'markitdown[all]'")"
expect semgrep "brew,pipx" macos "$(T 'brew install semgrep')"   # brew preferred over pipx

# --- privileged / remote-script channels are MANUAL-only, never auto-run ---
expect duckdb "" linux "$(M 'curl https://install.duckdb.org | sh')"
expect duckdb "brew" macos "$(T 'brew install duckdb')"
expect qsv "" linux "$(M 'cargo build --release --locked --bin qsv --features all_features')"

# --- OS eligibility: scoop is Windows-only, so it is ignored on Linux ---
expect ripgrep "scoop" linux "$(M 'sudo apt install ripgrep')"
expect ripgrep "scoop" windows "$(T 'scoop install ripgrep')"
# brew is excluded on Windows even if reported installed -> next eligible, else MANUAL.
expect ripgrep "brew" windows "$(M 'winget install BurntSushi.ripgrep.MSVC')"

# --- WSL is treated as Linux ---
expect universal-ctags "" wsl "$(M 'sudo apt install universal-ctags')"

# --- rtk: cargo-only channel ---
expect rtk "cargo" linux "$(T 'cargo install rtk')"
expect rtk "" linux "$(M 'cargo install rtk')"

# --- ast-grep via npm; repomix via npm ---
expect ast-grep "npm" linux "$(T 'npm install -g @ast-grep/cli')"
expect repomix "npm" linux "$(T 'npm install -g repomix')"

# --- unknown tool -> exit 2 (not a RUN/MANUAL decision) ---
if sh "$PICK" not-a-tool "brew" linux >/dev/null 2>&1; then
  printf 'FAIL: unknown tool should exit non-zero\n' >&2
  fails=$((fails + 1))
fi

if [ "$fails" -ne 0 ]; then
  printf 'pick_channel seam: %d assertion(s) failed\n' "$fails" >&2
  exit 1
fi

echo "pick_channel seam ok"
