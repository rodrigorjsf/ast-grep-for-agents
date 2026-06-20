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
import os, re, sys, glob

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
os.chdir(ROOT)
FILES = glob.glob("docs/**/*.md", recursive=True) + ["README.md", "CLAUDE.md"]


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

    ok = True
    for label, items in (("broken file links", broken_files),
                         ("broken anchors", broken_anchors),
                         ("[verified] on grammar extension (should be [sourced])", laundered)):
        if items:
            ok = False
            print(f"\n{len(items)} {label}:")
            for it in sorted(set(items)):
                print("  ", it)
    print("docs check: OK" if ok else "\ndocs check: FAILED")
    return 0 if ok else 1


if __name__ == "__main__":
    sys.exit(main())
