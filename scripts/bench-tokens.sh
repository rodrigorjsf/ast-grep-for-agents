#!/usr/bin/env bash
# WHAT: Regenerate the token-efficiency benchmark fixtures and print two tables:
#       (1) match search — read-whole-file vs grep/rg/ast-grep/comby/ctags; and
#       (2) context-packing — cat vs files-to-prompt vs Repomix over a multi-file
#       dir. Used in docs/03-agentic.md and docs/tools/*.md. Tokens ~ bytes/4.
#       Optional tools are command-v guarded; absent ones are skipped.
# WHY:  The user explicitly wants ast-grep's token/char savings documented with
#       REAL measurements. This encodes two findings so they are not re-derived:
#         - ast-grep plain output is ~flat per match-count, so the % saving GROWS
#           with file size (12% on a 4 KB file -> 2% on a 15 KB file, same 5 hits).
#         - --json is ~5x heavier than plain (parseability tradeoff, NOT a saver).
# WHEN: Run to refresh the numbers after changing the fixtures or upgrading
#       ast-grep, or to re-confirm the claims in docs/03-agentic.md.
# HOW:  scripts/bench-tokens.sh        (needs ast-grep on PATH, e.g. .venv/bin)
set -euo pipefail
cd "$(dirname "$0")/.."
[ -d .venv/bin ] && export PATH="$PWD/.venv/bin:$PATH"
command -v ast-grep >/dev/null || { echo "ast-grep not on PATH (try: pip install ast-grep-cli)"; exit 1; }

mkdir -p examples/bench
# Deterministic fixtures: BigService = 5 println among 40 methods; HugeService =
# same 5 println but 160 methods (isolates the file-size effect at fixed hits).
python3 - <<'PY'
def gen(path, n, cls, cond, doc, note):
    L=["package com.example.bench;",""]
    if doc: L.append("/** Generated benchmark fixture: a mid-size service. */")
    L+=[f"public class {cls} {{",""]
    for i in range(n):
        L+=[f"    public int compute{i}(int a, int b) {{", f"        int r = a * {i} + b;"]
        if cond(i): L.append(f'        System.out.println("compute{i} = " + r);'+note)
        L+=["        return r;","    }",""]
    L.append("}")
    open(path,"w").write("\n".join(L)+"\n")
# BigService: doc comment + per-line note -> 4191 B, 5 hits, ast-grep plain 509 B (12%)
gen("examples/bench/BigService.java", 40, "BigService", lambda i: i%8==0, True, "  // stray debug log")
# HugeService: plain, same 5 hits in a 4x-bigger file -> 15433 B, ast-grep plain 409 B (2%)
gen("examples/bench/HugeService.java",160,"HugeService",lambda i: i<5, False, "")
PY

PAT='System.out.println($$$A)'
# All optional-tool rows are command-v guarded so the bench degrades to the
# ast-grep/grep core when rg/comby/ctags/files-to-prompt/npx are absent. Every
# byte count is captured with `|| n=0` so a non-zero exit (e.g. ripgrep exits 1
# on no-match) never kills the whole run under `set -euo pipefail`.
cnt() { local n; n=$("$@" 2>/dev/null | wc -c) || n=0; printf '%s' "$n"; }
row() { printf "%-32s %6d   %6d        %3d%%   (%s)\n" "$1" "$2" "$(( $2 / 4 ))" "$(( $2 * 100 / full ))" "$b"; }

echo "=== match search (locate 5 hits in one file) ==="
echo "approach                         bytes   ~tokens(/4)   vs full   (file)"
for F in examples/bench/BigService.java examples/bench/HugeService.java; do
  full=$(wc -c < "$F"); b=$(basename "$F")
  printf "%-32s %6d   %6d        100%%   (%s)\n" "read whole file (no tool)" "$full" "$((full/4))" "$b"
  row "grep -n" "$(cnt grep -n 'System.out.println' "$F")"
  if command -v rg >/dev/null; then
    row "rg -n" "$(cnt rg -n 'System.out.println' "$F")"
    row "rg --json" "$(cnt rg --json 'System.out.println' "$F")"
  fi
  row "ast-grep (plain matches)" "$(cnt ast-grep run -p "$PAT" -l java "$F")"
  row "ast-grep --json=compact" "$(cnt ast-grep run -p "$PAT" -l java "$F" --json=compact)"
  if command -v comby >/dev/null; then
    cb=$(comby 'System.out.println(:[a])' '' -stdin -matcher .java -json-lines -match-only < "$F" 2>/dev/null | wc -c) || cb=0
    row "comby -match-only -json-lines" "$cb"
  fi
  # ctags = symbol map, not a match search: full json index vs a single-symbol lookup.
  if command -v ctags >/dev/null; then
    row "ctags json (full symbol index)" "$(cnt ctags --output-format=json -f - "$F")"
    c1=$(ctags --output-format=json -f - "$F" 2>/dev/null | grep '"name": "compute0"' | head -1 | wc -c) || c1=0
    row "ctags json (1-symbol lookup)" "$c1"
  fi
  echo
done
echo "Takeaway: ast-grep plain output stays ~flat per match-count; the bigger the"
echo "file, the larger the saving. rg --json and ast-grep --json buy structure,"
echo "not token savings. ctags' full index is heavier than a small file, but a"
echo "single-symbol lookup is tiny — the symbol map pays off across repeated reads."
echo

# Context-packing: directory -> one LLM prompt. Compared vs raw `cat` of the same
# files. Packers ADD structure/overhead; the point is wrapping, not token saving.
echo "=== context-packing (multi-file dir -> one prompt) ==="
echo "approach                         bytes   ~tokens(/4)   vs cat"
PD="examples/java examples/python examples/go"
catb=$(cat examples/java/*.java examples/python/*.py examples/go/*.go 2>/dev/null | wc -c) || catb=0
prow() { printf "%-32s %6d   %6d        %3d%%\n" "$1" "$2" "$(( $2 / 4 ))" "$(( catb ? $2 * 100 / catb : 0 ))"; }
prow "cat (raw concatenation)" "$catb"
if command -v files-to-prompt >/dev/null; then
  prow "files-to-prompt --cxml" "$(cnt files-to-prompt $PD --cxml)"
  prow "files-to-prompt --markdown" "$(cnt files-to-prompt $PD --markdown)"
fi
if command -v npx >/dev/null; then
  v=$(npx --yes repomix@latest $PD --style xml --stdout 2>/dev/null | wc -c) || v=0; prow "repomix --style xml" "$v"
  v=$(npx --yes repomix@latest $PD --style xml --compress --stdout 2>/dev/null | wc -c) || v=0; prow "repomix xml --compress" "$v"
  v=$(npx --yes repomix@latest $PD --style markdown --stdout 2>/dev/null | wc -c) || v=0; prow "repomix --style markdown" "$v"
fi
echo
echo "Takeaway (packing): files-to-prompt is a thin delimiter wrapper (small overhead"
echo "over cat); Repomix adds a repo-map (tree + summary + guidance) whose value shows"
echo "on real repos and with --compress, not on a 3-file sample set."
