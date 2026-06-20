# The ast-grep Learning Book

> A progressive, hands-on guide to the [`ast-grep`](https://github.com/ast-grep/ast-grep)
> CLI — how it works, how to use it well, and how to wire it into LLM-agent
> workflows. Focus languages: **Java (primary), Python, Go.**
>
> Everything marked _[verified]_ was **run against `ast-grep 0.42.3`** on this
> machine (WSL2, x86_64) with the output captured. Claims marked _[sourced]_ come
> from official docs/repos; _[sourced — unverified]_ means it could not be
> confirmed. The high-level overview lives in the repo [README](../README.md).

## How to read this book

Read the **spine** (01 → 05) in order — it teaches the tool from the ground up.
Then dip into the **reference shelves** (languages, OS, harnesses) for the variant
that matches your stack. Every page has a `← Previous | Next →` footer following
one master reading order, so you can also just keep pressing *Next*.

```mermaid
flowchart LR
  I([INDEX]) --> C1[01 Foundations] --> C2[02 CLI & Rules] --> C3[03 Agentic] --> C4[04 When to use] --> C5[05 Best practices]
  C5 --> L[languages/*]
  L --> O[os/*]
  O --> H[harnesses/*]
  classDef spine fill:#1e3a5f,stroke:#4a90d9,color:#fff;
  classDef shelf fill:#1f4d2e,stroke:#46b06b,color:#fff;
  class C1,C2,C3,C4,C5 spine;
  class L,O,H shelf;
  I e1@--> C1
  e1@{ animate: true }
```

## Table of contents

### Spine — the linear course
1. [Foundations](01-foundations.md) — Tree-sitter, the parse→match→rewrite model, the per-language dependency model
2. [CLI & Rules](02-cli-and-rules.md) — `run`/`scan`/`test`, pattern syntax, rule YAML, project config, snapshot tests
3. [Agentic workflows](03-agentic.md) — why agents love it, `--json`, deterministic codemods, the MCP server, **token-efficiency benchmarks**
4. [When to use ast-grep — and when not to](04-when-to-use.md) — the boundary, and the comparison vs ripgrep/Semgrep/Comby/CodeQL/OpenRewrite/LSP
5. [Best practices](05-best-practices.md) — good vs bad usage, the checklist, limitations & methodology

### Reference shelf — languages
- [Java](languages/java.md) (primary, deepest — includes the OpenRewrite tradeoff)
- [Python](languages/python.md)
- [Go](languages/go.md)

### Reference shelf — operating systems
- [Linux](os/linux.md) (canonical — everything was verified here on WSL2)
- [WSL](os/wsl.md) · [macOS](os/macos.md) · [Windows](os/windows.md)

### Reference shelf — agent harnesses
- [Agent Decision Policy](harnesses/00-decision-policy.md) — the canonical, copy-pasteable "when ast-grep vs another tool" rule
- [Claude Code](harnesses/claude-code.md) · [Cursor](harnesses/cursor.md) · [Codex](harnesses/codex.md) · [Pi](harnesses/pi.md) · [Hermes](harnesses/hermes.md)

## The POC this book documents

The repo is a runnable proof-of-concept. The pages cite these real fixtures:

```text
sgconfig.yml              # project config
rules/                    # java-no-sysout, python-is-none, go-no-fmt-println
rule-tests/__snapshots__/ # accepted snapshot baselines
examples/{java,python,go} # sample sources the rules fire on
examples/bench/           # benchmark fixtures (token-efficiency measurements)
```

---

[Next: 01 · Foundations →](01-foundations.md)
