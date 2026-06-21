#!/bin/sh
# seam: SessionStart policy script emits valid JSON carrying the policy verbatim.
# Runs the real hook script and asserts (1) stdout is valid JSON, (2) the
# SessionStart event shape is correct, (3) the policy content survives escaping
# (guards against silent truncation / escaping drift that still emits valid JSON).
here=$(dirname "$0")
out=$(sh "$here/session-start-policy.sh") || { echo "script exited non-zero"; exit 1; }
printf '%s' "$out" | jq empty || { echo "stdout is not valid JSON"; exit 1; }
printf '%s' "$out" | jq -er '.hookSpecificOutput.hookEventName=="SessionStart"' >/dev/null \
  || { echo "missing/incorrect hookEventName"; exit 1; }
printf '%s' "$out" | jq -er '.hookSpecificOutput.additionalContext | contains("Local tool policy (token-first)")' >/dev/null \
  || { echo "policy title missing from additionalContext"; exit 1; }
printf '%s' "$out" | jq -er '.hookSpecificOutput.additionalContext | contains("novelty is never the reason")' >/dev/null \
  || { echo "policy tail missing from additionalContext"; exit 1; }
echo "policy-json seam ok"
