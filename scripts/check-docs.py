#!/usr/bin/env python3
# WHAT: Gating/render check for the docs/ book — verifies (1) every relative
#       markdown link resolves to a file on disk, (2) every cross-doc
#       `file.md#anchor` jump resolves to a real heading using GitHub's slug
#       rules, and (3) no `[verified]` label sits on a custom-grammar file
#       extension (.so/.dylib/.dll) — those are never run here, so they must be
#       `[sourced]`. Exits non-zero if any check fails.
# WHY:  These were re-derived by hand 4+ times in one session. Two traps cost
#       real time and are baked in here so they are never re-suffered:
#         - GitHub's slugger STRIPS markdown emphasis markers (`_[verified]_`
#           -> `verified`) and brackets, but KEEPS in-word underscores
#           (`AST_GREP_CONFIG`). A naive slugifier gets both wrong.
#         - Fanned-out subagents laundered `[verified]` onto .dylib/.dll claims
#           that were never run on this machine. This audit catches that class.
# WHEN: Run after any docs/ change, before committing, and in CI. It is the
#       "are the docs internally consistent and honestly labelled?" gate.
# HOW:  python3 scripts/check-docs.py        (run from repo root)
#       exit 0 = clean; exit 1 = problems printed to stdout.
import os, re, sys, glob, subprocess

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
os.chdir(ROOT)
FILES = [f for f in glob.glob("docs/**/*.md", recursive=True)
         if "docs/handoffs/" not in f.replace("\\", "/")] + ["README.md", "CLAUDE.md"]
# Note: docs/handoffs/ holds local, gitignored handoff meta-docs — not book content, so it is not gated.


def github_slug(heading: str) -> str:
    """Mimic github-slugger on a raw heading line's text."""
    h = heading.strip().lower()
    h = h.replace("`", "").replace("*", "")     # strip code/bold markers
    h = h.replace("_[", "").replace("]_", "")    # strip emphasis-wrapped labels
    h = re.sub(r"[\[\]()]", "", h)               # strip remaining brackets/parens
    h = re.sub(r"[^\w\s-]", "", h)               # drop other punctuation, keep in-word _
    return re.sub(r"\s+", "-", h.strip())


def headings(path: str):
    out = set()
    for line in open(path, encoding="utf-8"):
        m = re.match(r"#{1,6}\s+(.*)", line)
        if m:
            out.add(github_slug(m.group(1)))
    return out


def main() -> int:
    head = {os.path.normpath(f): headings(f) for f in FILES}
    broken_files, broken_anchors, laundered = [], [], []

    for f in FILES:
        base = os.path.dirname(f)
        text = open(f, encoding="utf-8").read()
        for m in re.finditer(r"\]\(([^)]+)\)", text):
            link = m.group(1).strip()
            if link.startswith(("http", "#", "mailto")):
                continue
            path, _, anchor = link.partition("#")
            target = os.path.normpath(os.path.join(base, path)) if path else os.path.normpath(f)
            if path and not os.path.exists(target):
                broken_files.append(f"{f} -> {link}")
            elif anchor and target in head and anchor not in head[target]:
                broken_anchors.append(f"{f} -> {link}")
        # [verified] laundering on grammar extensions
        for m in re.finditer(r".*\[verified[^\]]*\].*", text):
            if re.search(r"\.(so|dylib|dll)`?", m.group(0)):
                laundered.append(f"{f}: {m.group(0).strip()[:90]}")

    # --- Cursor plugin .mdc Rule checks ---
    mdc_problems = check_cursor_policy_mdc()

    ok = True
    for label, items in (("broken file links", broken_files),
                         ("broken anchors", broken_anchors),
                         ("[verified] on grammar extension (should be [sourced])", laundered),
                         ("cursor policy .mdc rule violations", mdc_problems)):
        if items:
            ok = False
            print(f"\n{len(items)} {label}:")
            for it in sorted(set(items)):
                print("  ", it)

    # --- Cursor single-source byte-identity drift gate ---
    # The drift gate is the SOLE CI entrypoint for the single-source contract: check-docs.py
    # shells out to it rather than reimplementing the byte-compare. A non-zero exit (a synced
    # Cursor copy diverged from its tool-optimizer/ source) fails the docs check too.
    if not run_cursor_drift_gate():
        ok = False

    print("docs check: OK" if ok else "\ndocs check: FAILED")
    return 0 if ok else 1


def run_cursor_drift_gate() -> bool:
    """Shell out to the byte-identity drift gate. Returns True iff it exits 0."""
    gate = os.path.join(ROOT, "scripts", "check-cursor-drift.sh")
    if not os.path.exists(gate):
        print(f"\ncursor drift gate missing: {gate}")
        return False
    proc = subprocess.run(["sh", gate], capture_output=True, text=True)
    out = (proc.stdout or "") + (proc.stderr or "")
    if proc.returncode != 0:
        print("\ncursor single-source drift gate FAILED:")
        for line in out.strip().splitlines():
            print("  ", line)
        return False
    return True


def check_cursor_policy_mdc() -> list:
    """Check the Cursor plugin Policy .mdc Rule for required content and forbidden repo-doc refs."""
    MDC_PATH = "cursor-tool-optimizer/rules/tool-optimizer-policy.mdc"
    problems = []

    if not os.path.exists(MDC_PATH):
        problems.append(f"{MDC_PATH}: file not found")
        return problems

    text = open(MDC_PATH, encoding="utf-8").read()

    # 1. Must not reference repo doc paths (self-contained-artifact rule).
    FORBIDDEN_PATTERNS = [
        r"docs/adr",
        r"docs/tools",
        r"CONTEXT\.md",
        r"\.\./",
    ]
    for pat in FORBIDDEN_PATTERNS:
        if re.search(pat, text):
            problems.append(f"{MDC_PATH}: references repo doc path matching '{pat}' (self-contained-artifact rule violated)")

    # 2. Must contain the guardrail line.
    GUARDRAIL = "a non-standard tool must beat the standard tool"
    if GUARDRAIL not in text:
        problems.append(f"{MDC_PATH}: missing guardrail line ('{GUARDRAIL}')")

    # 3. Must contain the self-report clause.
    SELF_REPORT = "report-error"
    if SELF_REPORT not in text:
        problems.append(f"{MDC_PATH}: missing self-report clause ('{SELF_REPORT}')")

    # 4. Must contain the hardcoded upstream tracker.
    UPSTREAM = "rodrigorjsf/ast-grep-for-agents"
    if UPSTREAM not in text:
        problems.append(f"{MDC_PATH}: missing upstream tracker string ('{UPSTREAM}')")

    return problems


if __name__ == "__main__":
    sys.exit(main())
