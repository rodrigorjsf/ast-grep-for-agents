# 02 · CLI & Rules

> Part of the ast-grep learning book — see [INDEX](INDEX.md).

Now that you know *what* ast-grep does ([Chapter 01](01-foundations.md)), here's
*how to drive it*: the subcommands, the pattern syntax, the rule file format, and
how to turn a one-off pattern into a tested, reusable project rule.

## `run` vs `scan` vs `test`

```text
$ ast-grep --help        # [verified]
Commands:
  run    Run one time search or rewrite in command line. (default command)
  scan   Scan and rewrite code by configuration
  test   Test ast-grep rules
  new    Create new ast-grep project or items like rules/tests
  lsp    Start language server
```

| Subcommand | Use it for | Driven by |
| --- | --- | --- |
| `run` (default) | one-off ad-hoc pattern search / rewrite | `-p/--pattern` on the command line |
| `scan` | repeatable linting with named, documented rules | rule YAML files / `sgconfig.yml` |
| `test` | regression-proof your rules with snapshot tests | `rule-tests/` |
| `new` | scaffold a project / rule / test | interactive |
| `lsp` | run ast-grep as an editor language server | `sgconfig.yml` |

### Flags worth knowing (all _[verified]_)

| Flag | What it does |
| --- | --- |
| `--json[=pretty\|stream\|compact]` | structured output. **Must use `=`.** `stream` = NDJSON (one match per line, ideal for piping to an agent). |
| `--rewrite/-r '<fix>'` | show a **diff preview** of the rewrite |
| `--update-all/-U` | actually **apply** the rewrite to disk (without it, nothing is written) |
| `--debug-query[=ast\|cst\|pattern\|sexp]` | print the tree your pattern parsed to — the antidote to silent no-match |
| `--strictness <cst\|smart\|ast\|relaxed\|signature\|template>` | how strict the match is (default `smart` ignores trivia) |
| `--selector <kind>` | with a `context`, pick the sub-node that is the real matcher |
| `scan -r <file>` / `--inline-rules '<yaml>'` | run a single rule from a file or inline string |
| `scan --filter <regex>` | run only rules whose id matches |
| `scan --error[=ID]` / `--warning` / `--info` | override severity; **`--error` makes findings fail CI** (exit 1) |
| `scan --report-style <rich\|medium\|short>` | diagnostic verbosity |

### Exit codes _[verified — this matters for agents and CI]_

```text
match found            -> exit 0
no match               -> exit 1   (grep-like; an empty result is NOT exit 0)
test without baseline  -> exit 4
unparseable pattern    -> exit 8
scan with --error and findings -> exit 1
```

> **Beginner note.** An agent or CI script that treats "no output" as success is
> wrong here: a malformed pattern (exit 8) and a genuinely clean file (exit 1) and
> a match (exit 0) are all distinguishable by exit code — and *only* `--debug-query`
> tells you whether an empty result means "clean" or "your pattern is broken."

## Pattern syntax

### Meta-variables _[verified]_

| Syntax | Matches | Captured? |
| --- | --- | --- |
| `$VAR` | exactly one named node | yes, as `VAR` |
| `$$$VAR` | zero or more nodes (e.g. all arguments) | yes, as a list |
| `$_` | one node, **not** captured | no |
| `$$VAR` | one *unnamed* node | yes |

The JSON output exposes captures so an agent can act on them _[verified,
`--json=compact` trimmed]_:

```json
{"text":"System.out.println(\"debug: \" + input)",
 "range":{"start":{"line":7,"column":8}},
 "metaVariables":{"single":{"MSG":{"text":"\"debug: \" + input"}},"multi":{}}}
```

## Rule YAML schema

```yaml
id: my-rule              # required
language: java           # required
severity: warning        # error | warning | info | hint | off
message: Short finding.  # shown in scan output
note: Longer guidance.   # optional
rule:                    # the matcher (atomic / relational / composite)
  pattern: System.out.println($$$ARGS)
  # or: kind: method_invocation
  # relational: inside: {...}  has: {...}  follows: {...}  precedes: {...}
  # composite:  all: [...]  any: [...]  not: {...}  matches: util-id
constraints: {}          # restrict what a meta-variable may match
fix: logger.info($$$ARGS)  # optional rewrite
```

### The `context` + `selector` technique (you *will* need this)

Some patterns are **not valid stand-alone code**, so Tree-sitter mis-parses them
(the [Go chapter](languages/go.md) shows `fmt.Println($$$A)` parsing to an *error
node*). The fix is to embed the pattern in a minimal valid `context` and `selector`
the node you actually want _[verified]_:

```yaml
rule:
  pattern:
    context: "v := fmt.Println($$$A)"   # a valid Go statement
    selector: call_expression           # ...but match only the call
```

And some constructs (an empty `catch`, a bare `except:`) can't be a pattern at all
— they need `kind` + `not: has`. The [Java](languages/java.md) and
[Python](languages/python.md) chapters have the verified rules.

## From one-off to a tested project rule

This repo is a working POC. The layout:

```text
sgconfig.yml                 # project root config (ast-grep walks up to find it)
rules/
  java-no-sysout.yml         # pattern + fix
  python-is-none.yml         # pattern + fix
  go-no-fmt-println.yml      # context+selector, detection-only
rule-tests/
  java-no-sysout-test.yml    # valid/invalid cases
  __snapshots__/             # accepted baselines (commit these)
examples/{java,python,go}/   # sample sources the rules fire on
```

```yaml
# sgconfig.yml  [verified working]
ruleDirs:
  - rules
testConfigs:
  - testDir: rule-tests
```

**Run every rule across the project** — `ast-grep scan` auto-discovers
`sgconfig.yml` _[verified]_:

```text
$ ast-grep scan
warning[go-no-fmt-println]: Remove debug fmt.Println before committing.
  ┌─ examples/go/sample.go:9:2
9 │     fmt.Println("debug:", input)
  │     ^^^^^^^^^^^^^^^^^^^^^^^^^^^^

warning[java-no-sysout]: Avoid System.out.println in production code.
  ┌─ examples/java/Sample.java
8 │-        System.out.println("debug: " + input);
  │+        logger.info("debug: " + input);
...
```

**Snapshot-test your rules** — `test` is how rules stay correct as they evolve.
Tests need an accepted baseline _[verified]_:

```text
$ ast-grep test                # first run: no baseline
FAIL java-no-sysout            # exit 4 — "No baseline found"

$ ast-grep test --update-all   # accept the generated snapshot
PASS java-no-sysout

$ ast-grep test                # now regression-proof
test result: ok. 1 passed; 0 failed;   # exit 0
```

```yaml
# rule-tests/java-no-sysout-test.yml
id: java-no-sysout
valid:
  - logger.info("ok");
  - System.err.println("different call");
invalid:
  - System.out.println("debug");
```

---

[← Previous: 01 · Foundations](01-foundations.md) · [Next: 03 · Agentic →](03-agentic.md)
