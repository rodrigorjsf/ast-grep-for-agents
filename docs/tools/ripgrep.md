# ripgrep — the text-search baseline agents should default to
> Part of the ast-grep learning book — see [INDEX](../INDEX.md). ↑ Up: [03 · Agentic](../03-agentic.md)

ripgrep (`rg`) is the fast `grep` replacement an agent should reach for *first*
when the hunt is for a literal string, an identifier, or a log line. It is the
baseline every fancier tool — including ast-grep — is measured against. Verdict:
**KEEP**.

## What it does

`rg` recursively searches a directory tree for a regex pattern. Two habits make it
ideal for agents:

- **It respects `.gitignore` by default.** It skips files ignored by your
  `.gitignore`/`.ignore`/`.rgignore`, hidden files, and binary files — so a search
  never drowns in `node_modules/` or build output. _[sourced — https://github.com/BurntSushi/ripgrep]_
- **It emits structured JSON.** `rg --json` produces a newline-delimited JSON
  stream — one object per event (begin, match, context, end, summary) — so a model
  parses fields (`path`, `line_number`, submatch byte offsets) instead of
  re-parsing colon-delimited text. _[sourced — https://github.com/BurntSushi/ripgrep]_

It also gives you grep-style context lines (`-A` after, `-B` before, `-C` around)
and file-type filters (`rg -tpy foo` limits to Python; `rg -Tjs foo` excludes
JavaScript). _[sourced — https://github.com/BurntSushi/ripgrep]_

| You want… | Command |
|---|---|
| Find a literal, show 2 lines of context | `rg -C2 'TODO' src/` |
| Machine-parseable matches for an agent | `rg --json 'parseConfig'` |
| Only Python files | `rg -tpy 'def load'` |

## Where it comes from

ripgrep was created by Andrew Gallant (BurntSushi) to combine the raw speed of GNU
grep with the ergonomics of ack/ag — recursive, gitignore-aware, smart-case — while
being faster than both. It is written in Rust on top of the `regex` crate (a
finite-automata engine that avoids catastrophic backtracking, with SIMD-accelerated
literal scanning), ships as a single static binary, and has no runtime
dependencies. _[sourced — https://github.com/BurntSushi/ripgrep]_

License: **MIT OR Unlicense** — dual-licensed and fully permissive. _[sourced — https://github.com/BurntSushi/ripgrep]_

## Install (per-OS)

ripgrep ships in every package manager — one command on any OS. _[sourced — https://github.com/BurntSushi/ripgrep/blob/master/README.md]_

| OS | Command |
|---|---|
| Linux (Debian/Ubuntu) | `sudo apt install ripgrep` |
| WSL | same as Linux (`sudo apt install ripgrep`) |
| macOS | `brew install ripgrep` |
| Windows | `winget install BurntSushi.ripgrep.MSVC` (or `scoop install ripgrep`) |
| Any (from source) | `cargo install ripgrep` |

## What it replaces — and what it complements

ripgrep **is** the incumbent. It replaces GNU grep, ack, and even your harness's
native Grep tool (which is itself ripgrep-backed) by being faster, gitignore-aware
out of the box, and JSON-capable. _[sourced — https://github.com/BurntSushi/ripgrep]_

It does **not** replace ast-grep, and ast-grep does not replace it — they split the
work by question type:

| Question | Reach for |
|---|---|
| "Where does the string `parseConfig` appear?" | **ripgrep** (literal / regex / identifier) |
| "Find every `if`-without-`else` returning null" | **ast-grep** (syntax-aware structure) |

For a literal hunt across a tree, a structural tool like ast-grep or Semgrep must
*parse every file* — pure overhead when you only need a string match. That is
exactly where `rg` wins. When the query is about code *shape* rather than text, jump
to the spine: [§03 · Agentic](../03-agentic.md).

## Token economics

The book's benchmark compares `rg` against plain `grep` and against ast-grep on the
same fixtures (the same handful of hits in `BigService.java` / `HugeService.java`),
so `rg --json` is measured head-to-head with `ast-grep --json=compact`.

| approach | `BigService.java` (4 KB) | `HugeService.java` (15 KB) |
|---|---|---|
| read whole file (no tool) | 4191 B · 1047 tok · 100% | 15433 B · 3858 tok · 100% |
| `grep -n` | 354 B · 88 tok · 8% | 249 B · 62 tok · 1% |
| `rg -n` | 354 B · 88 tok · 8% | 249 B · 62 tok · 1% |
| `rg --json` | 2010 B · 502 tok · 47% | 1907 B · 476 tok · 12% |
| `ast-grep` (plain) | 509 B · 127 tok · 12% | 409 B · 102 tok · 2% |
| `ast-grep --json=compact` | 2725 B · 681 tok · 65% | 2593 B · 648 tok · 16% |

_[verified]_ — `scripts/bench-tokens.sh`, ripgrep 15.1.0 / ast-grep 0.42.3 on WSL2 x86_64.

Read it two ways. **`rg -n` is byte-identical to `grep -n`** — ripgrep's win over grep
is speed and gitignore scoping, not fewer tokens. And **`rg --json` (47% / 12%) is
lighter than `ast-grep --json=compact` (65% / 16%)** but both buy *structure*
(parseable fields), not savings — plain matches are far cheaper than either JSON.

## When to reach for it (and when not)

```mermaid
flowchart LR
  Q["Literal / regex / identifier<br/>query from the agent"] --> RG["rg --json '<pattern>'"]
  RG --> P["Parsed matches<br/>(path, line, byte offsets)"]
  P --> CW["Few tokens land in<br/>the context window"]

  classDef q fill:#5f4b1f,stroke:#d9a441,color:#fff;
  classDef tool fill:#1f4d2e,stroke:#46b06b,color:#fff;
  classDef out fill:#1e3a5f,stroke:#4a90d9,color:#fff;
  class Q q;
  class RG tool;
  class P,CW out;
```

- **Reach for it** when you need a literal string, an identifier, a regex, or a log
  line anywhere in the tree — and you want gitignore scoping and parseable output
  for free.
- **Don't** use it when the match depends on *syntax* (a call shape, a node type, an
  expression nested a certain way). A regex over code yields false positives in
  comments and strings; that is ast-grep's job — see the peers table in
  [04 · When to use](../04-when-to-use.md).

## Cross-links

- ast-grep peers and the "which tool" matrix — [04 · When to use](../04-when-to-use.md)
- The token benchmark these numbers come from — [03 · Agentic](../03-agentic.md)
- The tools shelf overview — [00 · Tools overview](00-overview.md)
- Back to the book index — [INDEX](../INDEX.md)

---
[← Previous: Tools overview](00-overview.md) · [Next: Semgrep →](semgrep.md)
