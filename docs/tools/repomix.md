# Repomix — pack a whole repo into one agent-ready prompt
> Part of the ast-grep learning book — see [INDEX](../INDEX.md). ↑ Up: [03 · Agentic](../03-agentic.md)

Repomix is the **repo-map / context-packer** for agents: one command walks a whole
directory tree and emits it as a single, structured, AI-friendly document — a
directory map plus a per-file summary plus the packed contents. It fills a real gap
in the toolbox: nothing else turns an *entire tree* into compact, agent-ready
context in one shot. Verdict: **ADD**.

## What it does

Repomix concatenates the text files under a path into **one** document the model can
parse as a unit. The pack is not a flat dump — it emits a repo **MAP**: a directory
tree, a per-file summary, then the packed file contents. _[sourced — https://github.com/yamadashy/repomix/blob/main/README.md]_

Three knobs matter most for an agent:

- **`--style`** chooses the wrapper: `--style xml` (default, recommended for Claude
  for best parsing accuracy), `--style markdown`, or `--style json` (machine-parseable
  object). _[sourced — https://repomix.com/guide/output]_
- **`--compress`** uses Tree-sitter to keep function/class signatures while dropping
  bodies — genuine shrinkage on large trees. _[sourced — https://github.com/yamadashy/repomix/blob/main/README.md]_
- **`--token-count-tree`** reports token counts per file, so the agent can size the
  context *before* sending it. _[sourced — https://github.com/yamadashy/repomix/blob/main/README.md]_

It is also `.gitignore`-aware, so lockfiles, vendored code, and build output never
leak into the context. _[sourced — https://github.com/yamadashy/repomix/blob/main/README.md]_

| You want… | Command |
|---|---|
| Pack a tree for Claude (default) | `repomix src/ --style xml` |
| Shrink a big tree to signatures | `repomix src/ --compress` |
| A machine-parseable pack | `repomix src/ --style json` |
| See where the tokens go | `repomix src/ --token-count-tree` |

## Where it comes from

Repomix automates the "feed a whole codebase to an LLM" workflow that people used to
do by hand. Doing it manually blows the context window on noise and is error-prone;
Repomix packs the repo into one AI-friendly file instead. _[sourced — https://github.com/yamadashy/repomix/blob/main/README.md]_

License: **MIT**. _[sourced — https://github.com/yamadashy/repomix/blob/main/README.md]_

## Install (per-OS)

No global install is required — `npx` runs it on demand. _[sourced — https://github.com/yamadashy/repomix/blob/main/README.md]_

| OS | Command |
|---|---|
| Linux | `npx repomix@latest` (or `npm install -g repomix`) |
| WSL | same as Linux |
| macOS | `brew install repomix` (or `npx repomix@latest`) |
| Windows | `npx repomix@latest` (or `npm install -g repomix`) |

## What it replaces — and what it complements

Repomix **replaces** manually `cat`-ing many files into a prompt: instead of pasting
file after file, you get one structured pack with a map the model can navigate.

It **complements** [files-to-prompt](files-to-prompt.md): Repomix packs a
*whole tree* with structure (tree + summary), while files-to-prompt is a lighter
wrapper around an explicit file **subset**. Pick by scope.

It does **not** replace native `Read` for a single known file. Packing a whole repo
to look at one file you already know the path to is pure waste — read it directly.

| Question | Reach for |
|---|---|
| "Give the agent the *whole tree* as context" | **Repomix** (tree + summary + contents) |
| "Give it just *these few* files" | **files-to-prompt** (explicit subset) |
| "Read one file I already know" | native **Read** |

## Token economics

The book's benchmark packs a small multi-language sample directory and compares
Repomix styles (`xml`, `xml --compress`, `json`) against a raw `cat` of the same
tree.

Packing `examples/{java,python,go}` (three small sample files, one per language):

| approach | bytes | ~tokens | vs `cat` |
|---|---|---|---|
| `cat` (raw concatenation) | 1734 | 433 | 100% |
| `files-to-prompt --markdown` | 1845 | 461 | 106% |
| `files-to-prompt --cxml` | 2103 | 525 | 121% |
| `repomix --style markdown` | 3504 | 876 | 202% |
| `repomix --style xml --compress` | 3448 | 862 | 198% |
| `repomix --style xml` | 3660 | 915 | 211% |

_[verified]_ — `scripts/bench-tokens.sh`, repomix 1.15.0 / files-to-prompt 0.6 on WSL2.

A repo map is not free: the tree + per-file summary wrapping adds structure, and so
adds overhead. On a tiny file set that overhead dominates and the wrapper loses to a
plain `cat`. Its value shows on real repos — and especially with `--compress`, where
dropping function bodies is the real token saver.

## When to reach for it (and when not)

```mermaid
flowchart LR
  T["Repo tree<br/>(src/, many files)"] --> RX["repomix<br/>--style xml/md/json<br/>--compress"]
  RX --> P["Packed context<br/>(map + summary + files)"]
  P --> CW["Context window"]

  classDef tree fill:#5f4b1f,stroke:#d9a441,color:#fff;
  classDef tool fill:#1f4d2e,stroke:#46b06b,color:#fff;
  classDef out fill:#1e3a5f,stroke:#4a90d9,color:#fff;
  class T tree;
  class RX tool;
  class P,CW out;
```

- **Reach for it** when an agent needs a whole tree (or a large subtree) as context
  and you want a navigable map, gitignore filtering, and token counts for free —
  reach for `--compress` once the tree is big.
- **Don't** use it for a single known file (use `Read`), for a tiny handful of files
  (use [files-to-prompt](files-to-prompt.md)), or to find one symbol — packing a
  repo to locate a pattern is wasteful; jump to ast-grep / ripgrep instead, per
  [04 · When to use](../04-when-to-use.md).

## Cross-links

- The lighter, file-subset packer — [files-to-prompt.md](files-to-prompt.md)
- The token-efficiency chapter these numbers come from — [03 · Agentic](../03-agentic.md)
- The tools shelf overview — [00 · Tools overview](00-overview.md)
- Back to the book index — [INDEX](../INDEX.md)

---
[← Previous: Semgrep](semgrep.md) · [Next: files-to-prompt →](files-to-prompt.md)
