#!/usr/bin/env bash
# WHAT: Regenerate the token-efficiency benchmark fixtures and print the
#       comparison table (read-whole-file vs grep vs ast-grep plain vs --json)
#       used in docs/03-agentic.md. Tokens are estimated at ~bytes/4.
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
echo "approach                         bytes   ~tokens(/4)   vs full   (file)"
for F in examples/bench/BigService.java examples/bench/HugeService.java; do
  full=$(wc -c < "$F")
  ag=$(ast-grep run -p "$PAT" -l java "$F" | wc -c)
  agj=$(ast-grep run -p "$PAT" -l java "$F" --json=compact | wc -c)
  grp=$(grep -n 'System.out.println' "$F" | wc -c)
  b=$(basename "$F")
  printf "read whole file (no tool)        %6d   %6d        100%%   (%s)\n" "$full" "$((full/4))" "$b"
  printf "grep -n                          %6d   %6d        %3d%%   (%s)\n" "$grp" "$((grp/4))" "$((grp*100/full))" "$b"
  printf "ast-grep (plain matches)         %6d   %6d        %3d%%   (%s)\n" "$ag" "$((ag/4))" "$((ag*100/full))" "$b"
  printf "ast-grep --json=compact          %6d   %6d        %3d%%   (%s)\n" "$agj" "$((agj/4))" "$((agj*100/full))" "$b"
  echo
done
echo "Takeaway: ast-grep plain output stays ~flat per match-count; the bigger the"
echo "file, the larger the saving. --json buys structure, not token savings."
