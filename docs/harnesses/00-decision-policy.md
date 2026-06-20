# Agent Decision Policy — when to use ast-grep

> Part of the ast-grep learning book — see [INDEX](../INDEX.md). ↑ Up: [03 · Agentic](../03-agentic.md)

This is the **canonical, copy-pasteable rule** you give an LLM agent so it picks
the right tool for the task — saving tokens and avoiding wrong results. The
per-harness pages ([Claude Code](claude-code.md), [Cursor](cursor.md),
[Codex](codex.md), [Pi](pi.md), [Hermes](hermes.md)) only tell you *where to paste
it* and *how to mount the MCP server*. The policy itself is here, once.

## The two mechanisms

1. **A rules / instruction file** — where the decision policy below lives. Each
   harness reads a different file (`AGENTS.md`, `CLAUDE.md`, `.cursor/rules/*.mdc`,
   `.windsurfrules`, `GEMINI.md`, `.github/copilot-instructions.md`).
2. **MCP** — the [`ast-grep/ast-grep-mcp`](https://github.com/ast-grep/ast-grep-mcp)
   server mounts the actual tools (`dump_syntax_tree`, `test_match_code_rule`,
   `find_code`, `find_code_by_rule`) into any MCP-capable harness.

Use the rules file to teach *judgement*; use MCP (or the CLI directly) to give
*capability*.

## The policy (paste this into your agent's rules file)

```markdown
## Code search & refactor tool policy

Pick the tool by the SHAPE of the task, in this order:

1. Literal string / identifier / log line → use ripgrep (`rg`). Cheapest.
2. Syntax-aware search in ONE language (calls, nesting, node kinds, "code that
   looks like X") → use ast-grep:
   `ast-grep run -p '<pattern>' -l <lang>`  (default to plain output; it is far
   smaller than reading whole files, and the saving grows with file size).
   - Add `--json` ONLY when you must act on exact ranges/captures. `--json` is
     ~5x larger than plain output — it buys structure, not token savings.
   - Deterministic edit → write a rule with `fix:` and apply with `-U`
     (preview without `-U` first).
3. Needs TYPE info, cross-file DATAFLOW, or TAINT → ast-grep CANNOT do this.
   Use Semgrep Pro / CodeQL (dataflow/taint) or OpenRewrite / the IDE
   (type-aware Java/JVM refactor). Do not fake it with ast-grep.

ast-grep guardrails (non-negotiable):
- Invoke `ast-grep`, never `sg` (the alias collides with Linux setgroups).
- A no-match exits 1 with NO error message — an empty result is NOT proof the
  code is clean. Before trusting "no matches", run `ast-grep run -p '<pattern>'
  -l <lang> --debug-query=ast` to confirm the pattern parsed as intended (it may
  have parsed to an ERROR node and matched nothing).
- Some constructs are not valid stand-alone code (empty catch, bare except, some
  Go calls). Use a YAML rule with `kind` + `not: has`, or `pattern: { context,
  selector }`. Test rules with `ast-grep test`.
- For complex rules, fetch https://ast-grep.github.io/llms.txt for reference.
```

Keep it that short. A 2000-token policy pasted into every `AGENTS.md` defeats its
own token-saving purpose.

## Where each harness reads its rules file

| Harness | Rules / instruction file | MCP config | Dedicated page |
| --- | --- | --- | --- |
| Claude Code | `CLAUDE.md` (bridge `AGENTS.md` via `@AGENTS.md` import) | `.mcp.json` / `claude mcp add` | [claude-code.md](claude-code.md) |
| Cursor | `.cursor/rules/*.mdc` | `.cursor/mcp.json` | [cursor.md](cursor.md) |
| OpenAI Codex CLI | `AGENTS.md` | `~/.codex/config.toml` | [codex.md](codex.md) |
| Pi (Pi Harness) | see [pi.md](pi.md) | see [pi.md](pi.md) | [pi.md](pi.md) |
| Hermes Agent | see [hermes.md](hermes.md) | see [hermes.md](hermes.md) | [hermes.md](hermes.md) |
| Gemini CLI | `GEMINI.md` | MCP-capable → mount ast-grep-mcp | — (use this policy) |
| Windsurf | `.windsurfrules` | MCP-capable → mount ast-grep-mcp | — (use this policy) |
| GitHub Copilot | `.github/copilot-instructions.md` | — | — (use this policy) |

> **`AGENTS.md` is the portable baseline** _[sourced]_. It's the cross-tool standard
> (originated by OpenAI, now under the Linux Foundation's Agentic AI Foundation).
> Put the policy in `AGENTS.md` and most agents — Codex natively, and others — will
> read it. Claude Code does **not** auto-read `AGENTS.md`; you bridge it with an
> `@AGENTS.md` import inside `CLAUDE.md` (see [claude-code.md](claude-code.md)).
> Per-harness native files (`CLAUDE.md`, `.cursor/rules`) are richer where you need them.

## Beyond ast-grep — extending the policy to the whole tool shelf

This page covers the *code-search* decision. The same logic — **pick by the shape of
the task; a non-standard tool must beat the standard one on tokens or capability;
never deny-list `Read`/`Grep`/`rg`** — extends to the rest of the agent bench: ripgrep,
Semgrep, Repomix, files-to-prompt, MarkItDown, DuckDB, qsv, and universal-ctags. The
extended token-first snippet and the per-tool chapters (with `[verified]` benchmarks)
live on the [tools shelf](../tools/00-overview.md). Paste that snippet into the **same
rules file** your harness uses above — the placement is identical; only the policy text
is longer. _[sourced]_

---

[← Previous: Windows](../os/windows.md) · [Next: Claude Code →](claude-code.md)
