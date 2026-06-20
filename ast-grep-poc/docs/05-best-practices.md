# 05 · Best practices

> Part of the ast-grep learning book — see [INDEX](INDEX.md).

Good and bad usage, distilled — all examples _[verified]_. After this chapter, the
book branches into the reference shelves: [languages](languages/java.md),
[OS](os/linux.md), and [agent harnesses](harnesses/00-decision-policy.md).

## ❌ Bad: trusting an empty result (the agent killer)

```text
$ ast-grep run -p 'fmt.Println($$$A)' -l go examples/go/sample.go
$ echo $?
1                       # nothing matched, no error — looks like "clean code"
```

`fmt.Println` is called twice in that file. The pattern was wrong: in Go's grammar
it parsed to an **ERROR node**. `--debug-query` reveals it _[verified]_:

```text
$ ast-grep run -p 'fmt.Println($$$A)' -l go --debug-query=ast file.go
Debug AST:
  type_conversion_expression          # ← NOT a call!
    type: qualified_type (fmt.Println)
    ERROR                             # ← $$$A could not be parsed
```

The fix (and the full lesson) is in the [Go chapter](languages/go.md).

## ✅ Good: verify the parse, then use `context`/`selector`

```text
$ ast-grep scan --inline-rules 'id: x
language: go
rule:
  pattern:
    context: "v := fmt.Println($$$A)"
    selector: call_expression' examples/go/sample.go
# matches BOTH fmt.Println("debug:", input) AND fmt.Println(out)
```

## ❌ Bad: over-broad / type-blind patterns

`$A == $B` to "find String comparison bugs" matches **every** `==` (ints, enums,
chars). ast-grep can't filter by type — you'd drown in false positives. Narrow it
(`$X == "literal"`) and accept it's a heuristic, or use a type-aware tool.

## ❌ Bad: rewriting with `-U` before previewing

Always preview (`-r` without `-U`) or run `ast-grep test` first; `-U` writes to
disk immediately.

## Good-usage rules of thumb

- Prefer `kind:` or `context`/`selector` over fragile literal patterns.
- Pin rules with `ast-grep test` snapshots so refactors can't regress them.
- Use `--json=stream` when piping to another program or an agent.
- Gate CI with `scan --error` so violations actually fail the build.

## The checklist

- [ ] Invoke `ast-grep`, never `sg` (see the [OS shelf](os/linux.md)).
- [ ] One language per pattern (`-l`); ast-grep is single-language per run.
- [ ] `--debug-query` whenever a pattern matches nothing unexpectedly.
- [ ] Keep rules in `rules/`, tests in `rule-tests/`, wired by `sgconfig.yml`.
- [ ] Commit `__snapshots__/`; run `ast-grep test` in CI.
- [ ] Preview rewrites before `-U`.
- [ ] For agents: system-prompt the `ast-grep -p` default + feed `llms.txt`; make
      the harness verify parses before trusting empty results.
- [ ] Stop and switch tools when you need types, dataflow, or cross-file reach.

## Limitations, methodology & sources

**Methodology.** CLI behaviour, flags, exit codes, and every Java/Python/Go example
in this book were executed against **ast-grep 0.42.3** on **WSL2 (x86_64)**, with
output captured (the `examples/`, `rules/`, `rule-tests/`, `examples/bench/` trees
are the fixtures). ast-grep's *own* ecosystem facts — language list, MCP server,
custom-language schema, install commands, AI guide — were fetched from official
docs/repo and marked _[sourced]_. The **comparison verdicts** for other tools
([Chapter 04](04-when-to-use.md)) summarize each tool's *documented design*, not a
fresh benchmark. macOS/Windows-specific notes were **not reproduced** on those OSes
(only WSL2 was available) and are marked accordingly.

**Known limitations of ast-grep itself:** no type information, no cross-file
dataflow/taint, single-language per run, and patterns can mis-parse when not valid
stand-alone code (mitigated by `context`/`selector`).

**Sources**

- ast-grep repo & docs — <https://github.com/ast-grep/ast-grep>, <https://ast-grep.github.io>
- Built-in languages — <https://ast-grep.github.io/reference/languages.html>
- Using ast-grep with AI Tools — <https://ast-grep.github.io/advanced/prompting.html>
- Tooling overview — <https://ast-grep.github.io/guide/tooling-overview.html>
- Official MCP server — <https://github.com/ast-grep/ast-grep-mcp>
- LLM-friendly docs bundle — <https://ast-grep.github.io/llms.txt>

---

[← Previous: 04 · When to use](04-when-to-use.md) · [Next: Java →](languages/java.md)
