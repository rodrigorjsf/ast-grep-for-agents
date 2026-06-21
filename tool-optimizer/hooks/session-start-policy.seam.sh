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

here=$(dirname "$0")
HOOK_SH="$here/session-start-policy.sh"

tmpdir=$(mktemp -d)
trap 'rm -rf "$tmpdir"' EXIT

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
# Summary
# ============================================================================
if [ "$fail" -eq 0 ]; then
  echo "policy-json seam ok"
  exit 0
else
  echo "policy-json seam FAILED"
  exit 1
fi
