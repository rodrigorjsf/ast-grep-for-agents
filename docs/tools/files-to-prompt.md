# files-to-prompt — pack an explicit file subset, minimally
> Part of the ast-grep learning book — see [INDEX](../INDEX.md). ↑ Up: [03 · Agentic](../03-agentic.md)

When you already know *which* handful of files the agent needs, `files-to-prompt`
is the lightest way to bundle exactly those into one prompt. It is a thin wrapper
around the set of files and directories you name on the command line — no whole-repo
map, no parser, just a clean concatenation in a model-friendly shape. Verdict:
**ADD**.

## What it does

`files-to-prompt` takes the files and directories you list and concatenates them
into a single block of text suitable for pasting into an LLM prompt. You choose the
output shape:

- **`--cxml`** — a Claude-friendly XML format that wraps each file in document tags
  (a `<documents>` block with a `<source>` path and `<document_content>` per file),
  so the model parses file boundaries cleanly. _[sourced — https://github.com/simonw/files-to-prompt]_
- **`--markdown`** — each file inside a fenced code block. _[sourced — https://github.com/simonw/files-to-prompt]_
- **default** — the file path followed by `---` separators between files. _[sourced — https://github.com/simonw/files-to-prompt]_

The point is that it is *explicit*: you hand it a subset you already chose, and it
adds minimal overhead on top of simply pasting those files. It is not a discovery
tool — it does not map a repo for you.

| You want… | Command |
|---|---|
| Bundle a chosen set as Claude XML | `files-to-prompt fileA.java fileB.py --cxml` |
| Bundle the same set as Markdown | `files-to-prompt fileA.java fileB.py --markdown` |
| Default path + `---` separators | `files-to-prompt fileA.java fileB.py` |

## Where it comes from

`files-to-prompt` was built by Simon Willison to solve the everyday task of pasting
a curated handful of files into an LLM prompt without hand-assembling them by
`cat`. It is a small Python CLI — a straightforward filesystem walk plus
formatting, with no engine or parser behind it. _[sourced — https://github.com/simonw/files-to-prompt]_

License: **Apache-2.0**. _[sourced — https://github.com/simonw/files-to-prompt]_

## Install (per-OS)

Installation is **pip-only** — that is the one path documented upstream, and it is
the same on every OS because this is a pure-Python PyPI package with no OS-specific
steps. _[sourced — https://github.com/simonw/files-to-prompt]_

| OS | Command |
|---|---|
| Linux | `pip install files-to-prompt` |
| WSL | same as Linux (`pip install files-to-prompt`) |
| macOS | `pip install files-to-prompt` |
| Windows | `pip install files-to-prompt` |

`pipx install files-to-prompt` and `uv tool install files-to-prompt` are generically
true for PyPI CLIs but are **not** documented as official install paths upstream, so
they are not recommended here. _[sourced — unverified]_

## What it replaces — and what it complements

`files-to-prompt` replaces manually `cat`-ing a chosen subset of files into a
prompt — same job, but with a one-flag Claude-shaped wrapper instead of hand-glued
text.

It does **not** replace native `Read` of a single file, and it does not replace
Repomix. The three split by scope:

| You need… | Reach for |
|---|---|
| One file's contents, right now | native **`Read`** |
| An explicit subset you already chose, minimal overhead | **files-to-prompt** |
| A whole-repo map with directory tree + summary | **Repomix** ([repomix.md](repomix.md)) |

files-to-prompt and Repomix are complements: files-to-prompt is the curated
file-SET case; Repomix is the whole-repo case. Different jobs, no overlap.

## Token economics

The book's benchmark packs the same small sample directory used for Repomix and
compares `files-to-prompt --cxml` and `files-to-prompt --markdown` against a raw
`cat` baseline — so the wrapper's overhead is measured head-to-head. Qualitatively,
files-to-prompt is a much thinner wrapper than Repomix: it adds little beyond `cat`,
because it concatenates rather than building a tree-plus-summary map.

Packing `examples/{java,python,go}` (three small sample files, one per language):

| approach | bytes | ~tokens | vs `cat` |
|---|---|---|---|
| `cat` (raw concatenation) | 1734 | 433 | 100% |
| `files-to-prompt --markdown` | 1845 | 461 | 106% |
| `files-to-prompt --cxml` | 2103 | 525 | 121% |
| `repomix --style xml` (for contrast) | 3660 | 915 | 211% |

_[verified]_ — `scripts/bench-tokens.sh`, files-to-prompt 0.6 / repomix 1.15.0 on WSL2.
`--markdown` adds ~6% over `cat`; `--cxml` ~21% (the document tags). Both are far
lighter than Repomix's repo-map (211%), because files-to-prompt concatenates instead
of building a tree-plus-summary. It buys clean file boundaries, not a map.

## When to reach for it (and when not)

```mermaid
flowchart LR
  CF["Chosen files<br/>you already picked"] --> FTP["files-to-prompt<br/>(--cxml / --markdown)"]
  FTP --> PC["Packed context<br/>(document-tagged subset)"]
  PC --> W["Lands in the<br/>context window"]

  classDef pick fill:#5f4b1f,stroke:#d9a441,color:#fff;
  classDef tool fill:#1f4d2e,stroke:#46b06b,color:#fff;
  classDef out fill:#1e3a5f,stroke:#4a90d9,color:#fff;
  class CF pick;
  class FTP tool;
  class PC,W out;
```

- **Reach for it** when you already know the specific files to hand the agent and
  want a minimal, Claude-shaped bundle of exactly that subset.
- **Don't** use it to explore or map a repo you don't know yet — that is Repomix's
  job — and don't reach past native `Read` when you only need one file.

## Cross-links

- The whole-repo packer it complements — [repomix.md](repomix.md)
- The token-efficiency chapter these measurements come from — [03 · Agentic](../03-agentic.md)
- The tools shelf overview — [00 · Tools overview](00-overview.md)
- Back to the book index — [INDEX](../INDEX.md)

---
[← Previous: Repomix](repomix.md) · [Next: MarkItDown →](markitdown.md)
