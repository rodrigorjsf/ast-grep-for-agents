#!/bin/sh
# WHAT: Seam test for session-start-policy.sh — drives the SessionStart hook and asserts
#       (1) stdout is valid JSON, (2) the SessionStart event shape is correct,
#       (3) the policy/block content survives escaping, and (4) the fallback path (no .local.md)
#       still emits valid JSON with the static Policy text.
# WHY:  Guards against silent truncation / escaping drift that still emits valid JSON, and
#       ensures the fallback path keeps working even after the hot-path was updated to read
#       from the pre-rendered .local.md.
# WHEN: Run by the CI gate (any *.seam.sh under tool-optimizer/).
# HOW:  Case 1 — no .local.md (TO_LOCAL_MD points to an absent file): fallback path, expects
#       static Policy in additionalContext.
#       Case 2 — .local.md with synthetic block (TO_LOCAL_MD points to a temp file): expects
#       the block content in additionalContext.
#       POSIX sh only — no bash arrays, no [[ ]], no bashisms.

set -e

here="$(CDPATH= cd -- "$(dirname "$0")" && pwd)"
here="$(printf '%s' "$here" | sed 's#/tests/tool-optimizer/#/tool-optimizer/#')"
HOOK_SH="$here/session-start-policy.sh"

tmpdir=$(mktemp -d)
trap 'rm -rf "$tmpdir"' EXIT

# Point breadcrumb at a temp path so seams never touch .claude/
BREADCRUMB="$tmpdir/policy.breadcrumb"
export TO_BREADCRUMB="$BREADCRUMB"

fail=0

# ============================================================================
# Case 1: fallback path — .local.md absent → static Policy emitted
# ============================================================================
absent_path="$tmpdir/nonexistent.md"
out=$(TO_LOCAL_MD="$absent_path" sh "$HOOK_SH") || { echo "FAIL [fallback]: script exited non-zero"; fail=1; }

printf '%s' "$out" | jq empty 2>/dev/null || { echo "FAIL [fallback]: stdout is not valid JSON"; fail=1; }

printf '%s' "$out" | jq -er '.hookSpecificOutput.hookEventName=="SessionStart"' >/dev/null \
  || { echo "FAIL [fallback]: missing/incorrect hookEventName"; fail=1; }

printf '%s' "$out" | jq -er '.hookSpecificOutput.additionalContext | contains("Local tool policy (token-first)")' >/dev/null \
  || { echo "FAIL [fallback]: policy title missing from additionalContext"; fail=1; }

printf '%s' "$out" | jq -er '.hookSpecificOutput.additionalContext | contains("novelty is never the reason")' >/dev/null \
  || { echo "FAIL [fallback]: policy tail missing from additionalContext"; fail=1; }

# Self-report trigger clause must be present on the FALLBACK path.
printf '%s' "$out" | jq -er '.hookSpecificOutput.additionalContext | contains("report-error")' >/dev/null \
  || { echo "FAIL [fallback]: self-report trigger clause missing from static Policy"; fail=1; }
printf '%s' "$out" | jq -er '.hookSpecificOutput.additionalContext | contains("rodrigorjsf/ast-grep-for-agents")' >/dev/null \
  || { echo "FAIL [fallback]: upstream tracker missing from self-report clause"; fail=1; }

echo "  [ok] fallback path: absent .local.md emits static Policy (with self-report clause)"

# ============================================================================
# Case 2: hot path — .local.md with synthetic block → block content emitted
# ============================================================================
synthetic_md="$tmpdir/synthetic.local.md"
cat > "$synthetic_md" <<'ENDMD'
## Local tool policy (token-first) — extends the code-search policy

### Available tools on this machine

- ripgrep
- ast-grep

### Preference order & guardrails

Guardrail: a non-standard tool must beat the standard tool (Read/Grep/rg) for THIS task on
tokens or capability — novelty is never the reason. No standard tool is deny-listed.
ENDMD

out2=$(TO_LOCAL_MD="$synthetic_md" sh "$HOOK_SH") || { echo "FAIL [hot-path]: script exited non-zero"; fail=1; }

printf '%s' "$out2" | jq empty 2>/dev/null || { echo "FAIL [hot-path]: stdout is not valid JSON"; fail=1; }

printf '%s' "$out2" | jq -er '.hookSpecificOutput.hookEventName=="SessionStart"' >/dev/null \
  || { echo "FAIL [hot-path]: missing/incorrect hookEventName"; fail=1; }

printf '%s' "$out2" | jq -er '.hookSpecificOutput.additionalContext | contains("Local tool policy (token-first)")' >/dev/null \
  || { echo "FAIL [hot-path]: policy title missing from additionalContext"; fail=1; }

printf '%s' "$out2" | jq -er '.hookSpecificOutput.additionalContext | contains("ripgrep")' >/dev/null \
  || { echo "FAIL [hot-path]: tool name missing from additionalContext"; fail=1; }

printf '%s' "$out2" | jq -er '.hookSpecificOutput.additionalContext | contains("novelty is never the reason")' >/dev/null \
  || { echo "FAIL [hot-path]: guardrail tail missing from additionalContext"; fail=1; }

echo "  [ok] hot path: .local.md content injected"

# ============================================================================
# Case 3: hot path — .local.md with YAML frontmatter → frontmatter stripped
# ============================================================================
frontmatter_md="$tmpdir/frontmatter.local.md"
cat > "$frontmatter_md" <<'ENDMD'
---
version: 1
---
## Local tool policy (token-first) — extends the code-search policy

Available tools: ripgrep, ast-grep

Guardrail: novelty is never the reason.
ENDMD

out3=$(TO_LOCAL_MD="$frontmatter_md" sh "$HOOK_SH") || { echo "FAIL [frontmatter]: script exited non-zero"; fail=1; }

printf '%s' "$out3" | jq empty 2>/dev/null || { echo "FAIL [frontmatter]: stdout is not valid JSON"; fail=1; }

printf '%s' "$out3" | jq -er '.hookSpecificOutput.additionalContext | contains("Local tool policy (token-first)")' >/dev/null \
  || { echo "FAIL [frontmatter]: policy title missing after frontmatter strip"; fail=1; }

# Frontmatter itself should not leak into the output
if printf '%s' "$out3" | jq -r '.hookSpecificOutput.additionalContext' | grep -q '^---'; then
  echo "FAIL [frontmatter]: YAML delimiter leaked into output"
  fail=1
fi

echo "  [ok] frontmatter stripped from .local.md content"

# ============================================================================
# Case 4 (AC1): force a crash → exactly one breadcrumb line with no path
# Crash mechanism: TO_FORCE_CRASH=1 triggers a deliberate `false` inside the
# hook under set -e, producing a non-zero exit that the trap catches.
# ============================================================================
crumb4="$tmpdir/ac1.breadcrumb"
rm -f "$crumb4"
out4=$(TO_FORCE_CRASH=1 TO_BREADCRUMB="$crumb4" sh "$HOOK_SH" 2>/dev/null) || true

if [ ! -f "$crumb4" ]; then
  echo "FAIL [ac1-crash]: breadcrumb file was not created after forced crash"
  fail=1
else
  line_count4=$(wc -l < "$crumb4" | tr -d ' ')
  if [ "$line_count4" -ne 1 ]; then
    echo "FAIL [ac1-crash]: expected exactly 1 breadcrumb line, got $line_count4"
    fail=1
  fi

  bc4_line=$(cat "$crumb4")
  if ! printf '%s' "$bc4_line" | grep -qE '^hooks/session-start-policy\.sh#[0-9]+$'; then
    echo "FAIL [ac1-crash]: breadcrumb line does not match expected pattern: '$bc4_line'"
    fail=1
  fi

  # Assert no path/content leak
  if printf '%s' "$bc4_line" | grep -q '/home\|/tmp\|/var\|Users'; then
    echo "FAIL [ac1-crash]: breadcrumb line contains a filesystem path: '$bc4_line'"
    fail=1
  fi
fi
echo "  [ok] ac1 crash: exactly one breadcrumb line with no path"

# ============================================================================
# Case 5 (AC2): pre-seeded non-empty breadcrumb → pointer appears in context
# ============================================================================
seeded_crumb="$tmpdir/seeded.breadcrumb"
printf 'hooks/nudge.sh#1\n' > "$seeded_crumb"

out5=$(TO_LOCAL_MD="$tmpdir/nonexistent-ac2.md" TO_BREADCRUMB="$seeded_crumb" sh "$HOOK_SH") \
  || { echo "FAIL [ac2-seeded]: script exited non-zero"; fail=1; }

printf '%s' "$out5" | jq empty 2>/dev/null \
  || { echo "FAIL [ac2-seeded]: stdout is not valid JSON"; fail=1; }

printf '%s' "$out5" | jq -er '.hookSpecificOutput.additionalContext | contains("report-error")' >/dev/null \
  || { echo "FAIL [ac2-seeded]: pending-defect pointer referencing report-error skill not found"; fail=1; }

printf '%s' "$out5" | jq -er '.hookSpecificOutput.additionalContext | contains("pending hook defect")' >/dev/null \
  || { echo "FAIL [ac2-seeded]: pending-defect phrase not found in context"; fail=1; }

echo "  [ok] ac2 pre-seeded breadcrumb: pending-defect pointer injected in context"

# ============================================================================
# Case 6 (AC2 inverse): absent breadcrumb → NO pointer in context
# ============================================================================
rm -f "$BREADCRUMB"
out6=$(TO_LOCAL_MD="$tmpdir/nonexistent-ac2b.md" TO_BREADCRUMB="$tmpdir/absent.breadcrumb" sh "$HOOK_SH") \
  || { echo "FAIL [ac2-absent]: script exited non-zero"; fail=1; }

if printf '%s' "$out6" | jq -er '.hookSpecificOutput.additionalContext | contains("pending hook defect")' >/dev/null 2>&1; then
  echo "FAIL [ac2-absent]: pending-defect pointer present even with no breadcrumb file"
  fail=1
fi
echo "  [ok] ac2 absent breadcrumb: no pointer injected (clean path)"

# ============================================================================
# Cursor hook seam cases
# ============================================================================
# Resolve cursor hook path: same worktree, different plugin dir.
cursor_hook="$(printf '%s' "$here" | sed 's#/tool-optimizer/#/cursor-tool-optimizer/#')/session-start-policy.sh"

# Case C1: absent .cursor/...local.md → static Policy emitted, envelope is
#           additional_context (NOT hookSpecificOutput), env is {}
c1_absent="$tmpdir/c1_nonexistent.md"
c1_crumb="$tmpdir/c1.breadcrumb"
out_c1=$(TO_LOCAL_MD="$c1_absent" TO_BREADCRUMB="$c1_crumb" sh "$cursor_hook") \
  || { echo "FAIL [cursor-fallback]: cursor hook exited non-zero"; fail=1; }

printf '%s' "$out_c1" | jq empty 2>/dev/null \
  || { echo "FAIL [cursor-fallback]: stdout is not valid JSON"; fail=1; }

# Must NOT have hookSpecificOutput (Claude envelope)
if printf '%s' "$out_c1" | jq -e '.hookSpecificOutput' >/dev/null 2>&1; then
  echo "FAIL [cursor-fallback]: hookSpecificOutput key must NOT be present in Cursor envelope"
  fail=1
fi

# Must have additional_context at top level
printf '%s' "$out_c1" | jq -er '.additional_context' >/dev/null 2>&1 \
  || { echo "FAIL [cursor-fallback]: additional_context key missing from Cursor envelope"; fail=1; }

# Must have env key
printf '%s' "$out_c1" | jq -er '.env' >/dev/null 2>&1 \
  || { echo "FAIL [cursor-fallback]: env key missing from Cursor envelope"; fail=1; }

# Static Policy must be present in additional_context
printf '%s' "$out_c1" | jq -er '.additional_context | contains("Local tool policy (token-first)")' >/dev/null \
  || { echo "FAIL [cursor-fallback]: policy title missing from additional_context"; fail=1; }

printf '%s' "$out_c1" | jq -er '.additional_context | contains("novelty is never the reason")' >/dev/null \
  || { echo "FAIL [cursor-fallback]: policy tail missing from additional_context"; fail=1; }

printf '%s' "$out_c1" | jq -er '.additional_context | contains("report-error")' >/dev/null \
  || { echo "FAIL [cursor-fallback]: self-report clause missing from additional_context"; fail=1; }

echo "  [ok] cursor C1: absent local.md → static Policy in additional_context (no hookSpecificOutput)"

# Case C2: seeded breadcrumb → pending-defect pointer folded into additional_context
c2_crumb="$tmpdir/c2.breadcrumb"
printf 'hooks/session-start-policy.sh#1\n' > "$c2_crumb"
c2_absent="$tmpdir/c2_nonexistent.md"
out_c2=$(TO_LOCAL_MD="$c2_absent" TO_BREADCRUMB="$c2_crumb" sh "$cursor_hook") \
  || { echo "FAIL [cursor-breadcrumb]: cursor hook exited non-zero"; fail=1; }

printf '%s' "$out_c2" | jq empty 2>/dev/null \
  || { echo "FAIL [cursor-breadcrumb]: stdout is not valid JSON"; fail=1; }

printf '%s' "$out_c2" | jq -er '.additional_context | contains("pending hook defect")' >/dev/null \
  || { echo "FAIL [cursor-breadcrumb]: pending-defect phrase not found in additional_context"; fail=1; }

printf '%s' "$out_c2" | jq -er '.additional_context | contains("report-error")' >/dev/null \
  || { echo "FAIL [cursor-breadcrumb]: report-error pointer missing from additional_context"; fail=1; }

echo "  [ok] cursor C2: seeded breadcrumb → pending-defect pointer in additional_context"

# Case C3: inventory present (via TO_STATE_DIR) → injected in additional_context
# Use TO_STATE_DIR so the hook derives LOCAL_MD automatically from the state dir.
c3_state="$tmpdir/c3_state"
mkdir -p "$c3_state"
c3_crumb="$tmpdir/c3.breadcrumb"
cat > "$c3_state/tool-optimizer.local.md" <<'ENDMD'
## Local tool policy (token-first) — extends the code-search policy

### Available tools on this machine

- ripgrep
- ast-grep
- jq

### Preference order & guardrails

Guardrail: a non-standard tool must beat the standard tool (Read/Grep/rg) for THIS task on
tokens or capability — novelty is never the reason. No standard tool is deny-listed.
ENDMD

out_c3=$(TO_STATE_DIR="$c3_state" TO_BREADCRUMB="$c3_crumb" sh "$cursor_hook") \
  || { echo "FAIL [cursor-inventory]: cursor hook exited non-zero"; fail=1; }

printf '%s' "$out_c3" | jq empty 2>/dev/null \
  || { echo "FAIL [cursor-inventory]: stdout is not valid JSON"; fail=1; }

printf '%s' "$out_c3" | jq -er '.additional_context | contains("ast-grep")' >/dev/null \
  || { echo "FAIL [cursor-inventory]: tool name missing from additional_context"; fail=1; }

printf '%s' "$out_c3" | jq -er '.additional_context | contains("ripgrep")' >/dev/null \
  || { echo "FAIL [cursor-inventory]: ripgrep missing from additional_context"; fail=1; }

# Must NOT have hookSpecificOutput
if printf '%s' "$out_c3" | jq -e '.hookSpecificOutput' >/dev/null 2>&1; then
  echo "FAIL [cursor-inventory]: hookSpecificOutput key must NOT be present in Cursor envelope"
  fail=1
fi

echo "  [ok] cursor C3: TO_STATE_DIR inventory injected into additional_context"

# ============================================================================
# Summary
# ============================================================================
if [ "$fail" -eq 0 ]; then
  echo "policy-json seam ok"
  exit 0
else
  echo "policy-json seam FAILED"
  exit 1
fi
