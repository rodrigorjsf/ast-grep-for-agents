#!/bin/sh
# WHAT: Sanitizer seam for the self-report (phone-home) feature. Turns the raw context of a
#       genuinely defective tool-optimizer Bootstrap-script run into a SANITIZED defect-report
#       struct (JSON) that carries ONLY allowlisted fields and PROVABLY none of the denylisted
#       strings (user paths, home dir, username, file contents, repo/org/remote, env-var
#       values, secrets).
# WHY:  The report is filed as a public GitHub issue on the plugin's HARDCODED upstream tracker
#       (rodrigorjsf/ast-grep-for-agents). "Sanitize-by-construction" means the struct is BUILT
#       from allowlisted fields only — the raw transcript/paths/code are never copied in, they
#       are synthesized or scrubbed. This script is the single inspectable seam where that
#       guarantee lives, so the filing subagent can be handed ONLY the struct.
# WHEN: Run by the report-error skill (SKILL.md) on the main thread, BEFORE spawning the
#       background filing subagent. The skill passes the emitted struct (and nothing else) to
#       that subagent.
# HOW:  Injectable env vars (all optional; the skill sets them from the failing run):
#         TO_ERR_ARTIFACT   absolute path to the failing Bootstrap script (e.g.
#                           /home/alice/proj/tool-optimizer/skills/bootstrap/scripts/detect.sh).
#                           Scrubbed to a PLUGIN-RELATIVE path (everything up to and including
#                           the last "tool-optimizer/" is dropped).
#         TO_ERR_EXIT       exit code or signal of the failing run (e.g. 127, or "SIGSEGV").
#         TO_ERR_MESSAGE    the tool's OWN error message (stderr tail). Scrubbed line-by-line.
#         TO_ERR_CLASS      short error class (e.g. "crash", "garbage-output", "exit-nonzero").
#         TO_OS_CLASS       OS class: macos | wsl | linux | windows (skill computes via uname).
#         TO_PKG_MGRS       detected package-manager set, comma-joined (e.g. "brew,npm,uv").
#         TO_PLUGIN_JSON    path to the plugin manifest the version is read from
#                           (default: the plugin root's .claude-plugin/plugin.json,
#                           resolved three dirs up from this script).
#         TO_SCRUB_HOME     home dir to scrub (default: $HOME). Replaced with <home>.
#         TO_SCRUB_USER     username to scrub (default: $USER, else basename of home).
#         TO_REPORT_OUT     if set, write the struct here instead of stdout.
#       Output: the sanitized defect-report struct (JSON) on stdout (or TO_REPORT_OUT).
#       POSIX sh only — no bashisms, no [[ ]], no arrays. Deterministic given fixed inputs.

set -e

ARTIFACT="${TO_ERR_ARTIFACT:-}"
EXITCODE="${TO_ERR_EXIT:-}"
RAW_MSG="${TO_ERR_MESSAGE:-}"
ERR_CLASS="${TO_ERR_CLASS:-exit-nonzero}"
OS_CLASS="${TO_OS_CLASS:-}"
PKG_MGRS="${TO_PKG_MGRS:-}"
SCRUB_HOME="${TO_SCRUB_HOME:-$HOME}"
SCRUB_USER="${TO_SCRUB_USER:-${USER:-}}"
SCRUB_REPO="${TO_SCRUB_REPO:-}"
REPORT_OUT="${TO_REPORT_OUT:-}"

# Resolve the plugin manifest the version is read from. This script lives at
# <plugin>/skills/report-error/scripts/sanitize.sh, so the manifest is three dirs up.
_here=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
PLUGIN_JSON="${TO_PLUGIN_JSON:-$_here/../../../.claude-plugin/plugin.json}"

# --- derive the username fallback from the home dir if $USER is empty ---
if [ -z "$SCRUB_USER" ] && [ -n "$SCRUB_HOME" ]; then
  SCRUB_USER=$(basename -- "$SCRUB_HOME")
fi

# ===========================================================================
# scrub_line: the central denylist scrubber. Given a single line of text on
# stdin, emit it with every denylisted shape replaced by a synthetic token:
#   - secret-like assignments (TOKEN=… / SECRET=… / API_KEY=…)  -> <key>=<redacted>
#   - long high-entropy runs (>= 20 chars)                       -> <redacted>
#   - the supplied repo slug / remote (owner/name or a URL)      -> <repo>
#   - the home directory                                          -> <home>
#   - the username (whole word)                                   -> <user>
#   - any remaining absolute path                                 -> <path>
# Order matters: secrets and the repo slug are masked FIRST so they are caught
# even when embedded in what would otherwise become a <path>. The absolute-path
# catch-all runs LAST as the backstop for any user path the named rules missed.
# Target platform is GNU sed (Linux/WSL2), matching the repo's existing scripts.
# ===========================================================================
scrub_line() {
  _h=$(printf '%s' "$SCRUB_HOME" | sed 's/[.[\*^$/]/\\&/g')
  _u=$(printf '%s' "$SCRUB_USER" | sed 's/[.[\*^$/]/\\&/g')
  _r=$(printf '%s' "$SCRUB_REPO" | sed 's/[.[\*^$/]/\\&/g')
  sed \
    -e 's/\([Tt][Oo][Kk][Ee][Nn]\|[Ss][Ee][Cc][Rr][Ee][Tt]\|[Aa][Pp][Ii][_-]\?[Kk][Ee][Yy]\|[Pp][Aa][Ss][Ss][Ww]\?[Oo]\?[Rr]\?[Dd]\?\)\([[:space:]]*[=:][[:space:]]*\)[^[:space:]"'\'']\+/\1\2<redacted>/g' \
    -e 's/[A-Za-z0-9+\/_=-]\{20,\}/<redacted>/g' \
    -e "${_r:+s|$_r|<repo>|g}" \
    -e "${_h:+s|$_h|<home>|g}" \
    -e "${_u:+s/\\b$_u\\b/<user>/g}" \
    -e 's#/[A-Za-z0-9._-]\+\(/[A-Za-z0-9._-]\+\)\+#<path>#g'
}

# scrub_text: scrub a multi-line blob line-by-line (preserves line structure).
scrub_text() {
  printf '%s\n' "$1" | while IFS= read -r _l; do
    printf '%s' "$_l" | scrub_line
    printf '\n'
  done
}

# json_escape: escape a string for embedding in a JSON value (reuse the
# detect.sh/nudge.sh idiom + newline handling).
json_escape() {
  printf '%s' "$1" | sed 's/\\/\\\\/g; s/"/\\"/g; s/	/\\t/g' | awk '{printf "%s\\n", $0}' | sed '$ s/\\n$//'
}

# --- ALLOWLIST FIELD 1: plugin-relative path of the failing artifact ---------
# Drop everything up to and including the last "tool-optimizer/" so no user path
# or home dir survives. If the marker is absent, fall back to the basename only.
rel_artifact=""
if [ -n "$ARTIFACT" ]; then
  case "$ARTIFACT" in
    */tool-optimizer/*)
      rel_artifact="tool-optimizer/$(printf '%s' "$ARTIFACT" | sed 's#.*/tool-optimizer/##')"
      ;;
    *)
      rel_artifact=$(basename -- "$ARTIFACT")
      ;;
  esac
fi

# --- ALLOWLIST FIELD 2: exit code / signal (digits or SIG* only) -------------
# Keep only a safe shape; anything else is dropped.
case "$EXITCODE" in
  ''|*[!0-9A-Za-z]*) exit_safe=$(printf '%s' "$EXITCODE" | sed 's/[^0-9A-Za-z]//g') ;;
  *) exit_safe="$EXITCODE" ;;
esac

# --- ALLOWLIST FIELD 3: the tool's own error message (SCRUBBED) --------------
scrubbed_msg=$(scrub_text "$RAW_MSG")
# Drop a trailing blank line introduced by the per-line loop.
scrubbed_msg=$(printf '%s' "$scrubbed_msg" | sed '$ { /^$/d; }')

# --- ALLOWLIST FIELD 4: error class + fingerprint ----------------------------
# The fingerprint is a stable hash of (error class + plugin-relative artifact +
# exit code) — never of user data. It is the dedup key later slices key on.
err_class_safe=$(printf '%s' "$ERR_CLASS" | sed 's/[^A-Za-z0-9._-]//g')
fp_src=$(printf '%s|%s|%s' "$err_class_safe" "$rel_artifact" "$exit_safe")
if command -v sha256sum >/dev/null 2>&1; then
  fingerprint=$(printf '%s' "$fp_src" | sha256sum | cut -c1-16)
elif command -v shasum >/dev/null 2>&1; then
  fingerprint=$(printf '%s' "$fp_src" | shasum -a 256 | cut -c1-16)
else
  fingerprint=$(printf '%s' "$fp_src" | cksum | tr -d ' ' | cut -c1-16)
fi

# --- ALLOWLIST FIELD 5: OS class (constrained set) ---------------------------
case "$OS_CLASS" in
  macos|wsl|linux|windows) os_safe="$OS_CLASS" ;;
  *) os_safe="unknown" ;;
esac

# --- ALLOWLIST FIELD 6: plugin version (read from the manifest) --------------
plugin_version="unknown"
if [ -f "$PLUGIN_JSON" ]; then
  if command -v jq >/dev/null 2>&1; then
    plugin_version=$(jq -r '.version // "unknown"' "$PLUGIN_JSON" 2>/dev/null || echo unknown)
  else
    plugin_version=$(grep '"version"' "$PLUGIN_JSON" | sed 's/.*"version"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/' | head -1)
  fi
fi
plugin_version=$(printf '%s' "$plugin_version" | sed 's/[^0-9A-Za-z._-]//g')
[ -n "$plugin_version" ] || plugin_version="unknown"

# --- ALLOWLIST FIELD 7: detected package-manager set (constrained) -----------
# Keep only known manager names; drop anything else (no free-form leakage).
pkg_safe=""
_IFS_SAVE=$IFS
IFS=','
for _m in $PKG_MGRS; do
  case "$_m" in
    brew|npm|pipx|uv|cargo|scoop|winget)
      if [ -z "$pkg_safe" ]; then pkg_safe="$_m"; else pkg_safe="$pkg_safe,$_m"; fi
      ;;
  esac
done
IFS=$_IFS_SAVE

# --- SYNTHETIC reproduction (synthesized, NOT derived from user data) --------
# References only the plugin-relative artifact + exit code. No user path, no
# code, no data. This is the "labeled synthetic reproduction" of AC1/AC4.
synthetic_repro="Synthetic reproduction (no user paths/code/data):
1. Install the tool-optimizer plugin.
2. Run the failing Bootstrap artifact: \`sh \${CLAUDE_PLUGIN_ROOT}/${rel_artifact}\`
3. Observe it terminate abnormally (class: ${err_class_safe}, exit: ${exit_safe})."

# --- TITLE (carries the [tool-optimizer] prefix + fingerprint) ---------------
title="[tool-optimizer] ${err_class_safe} in ${rel_artifact} (fp:${fingerprint})"

# --- emit the struct (allowlisted fields ONLY) -------------------------------
struct=$(cat <<ENDJSON
{
  "schema": "tool-optimizer/defect-report@1",
  "titlePrefix": "[tool-optimizer]",
  "title": "$(json_escape "$title")",
  "fingerprint": "${fingerprint}",
  "errorClass": "${err_class_safe}",
  "artifact": "$(json_escape "$rel_artifact")",
  "exitCode": "$(json_escape "$exit_safe")",
  "toolMessage": "$(json_escape "$scrubbed_msg")",
  "osClass": "${os_safe}",
  "pluginVersion": "${plugin_version}",
  "packageManagers": "${pkg_safe}",
  "syntheticReproduction": "$(json_escape "$synthetic_repro")",
  "upstreamRepo": "rodrigorjsf/ast-grep-for-agents",
  "label": "needs-triage"
}
ENDJSON
)

if [ -n "$REPORT_OUT" ]; then
  mkdir -p "$(dirname -- "$REPORT_OUT")"
  printf '%s\n' "$struct" > "$REPORT_OUT"
else
  printf '%s\n' "$struct"
fi
