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
# Summary
# ============================================================================
if [ "$fail" -eq 0 ]; then
  echo "policy-json seam ok"
  exit 0
else
  echo "policy-json seam FAILED"
  exit 1
fi
