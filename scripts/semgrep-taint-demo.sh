#!/usr/bin/env bash
# WHAT: Capability check (NOT a token bench) for Semgrep OSS taint/dataflow mode.
#       Runs a SQL-injection taint rule (source: HttpServletRequest.getParameter,
#       sink: Statement.executeQuery, sanitizer: sanitize()) over
#       examples/bench/TaintDemo.java and asserts exactly ONE finding -- the
#       unsanitized path in vulnerable(). The sanitized() control must be clean.
# WHY:  ast-grep matches syntax; it cannot follow a value across statements, so it
#       flags executeQuery() in BOTH methods or neither. This proves the one thing
#       Semgrep adds as a complement: interprocedural taint tracking. Sourced in
#       docs/tools/semgrep.md. The rule is inlined here so the capability claim and
#       the rule that backs it live in one auditable artifact.
# WHEN: Run to (re)confirm the Semgrep capability claim after editing the fixture
#       or upgrading semgrep.
# HOW:  scripts/semgrep-taint-demo.sh    (needs semgrep on PATH; e.g. .venv/bin)
#       exit 0 = exactly 1 finding on the tainted path (or semgrep absent -> skip);
#       exit 1 = unexpected finding count (regression).
set -euo pipefail
cd "$(dirname "$0")/.."
[ -d .venv/bin ] && export PATH="$PWD/.venv/bin:$PATH"
command -v semgrep >/dev/null || {
  echo "semgrep not on PATH -- skipping (docs/tools/semgrep.md stays [sourced])."
  echo "Install: pip install semgrep   (LGPL-2.1 engine; no native Windows binary -> use WSL)"
  exit 0
}

FIX=examples/bench/TaintDemo.java
RULE=$(mktemp --suffix=.yaml)
trap 'rm -f "$RULE"' EXIT
cat > "$RULE" <<'YAML'
rules:
  - id: tainted-sql-from-request
    languages: [java]
    severity: ERROR
    message: getParameter() flows into executeQuery() without sanitization (SQL injection).
    mode: taint
    pattern-sources:
      - pattern: $REQ.getParameter(...)
    pattern-sanitizers:
      - pattern: sanitize(...)
    pattern-sinks:
      - pattern: $STMT.executeQuery(...)
YAML

echo "== semgrep taint scan: $FIX =="
OUT=$(semgrep scan --config "$RULE" --json --quiet "$FIX" 2>/dev/null)
N=$(printf '%s' "$OUT" | python3 -c 'import sys,json; print(len(json.load(sys.stdin)["results"]))')
echo "findings: $N (expected 1 -- the unsanitized path; sanitized control must be clean)"
printf '%s' "$OUT" | python3 -c 'import sys,json
for r in json.load(sys.stdin)["results"]:
    print("  -> line %d: %s" % (r["start"]["line"], r["check_id"]))'
if [ "$N" = "1" ]; then
  echo "PASS: taint tracking isolated the unsanitized source->sink path."
else
  echo "FAIL: expected 1 finding, got $N"; exit 1
fi
