## Deepning

- Always ask yourself: "Is this concept/theme/description clear to a beginner?" If the answer is anything other than YES, elaborate, add examples, tables, diagrams, e.g.

## Documentation

Study deliverable: docs are living, not write-once.

- `README.md` must stay in sync with the learnings. Update them in the **same commit** that changes behavior, scope, or run steps — never let them drift.
- Use **Mermaid diagrams** whenever they make a flow, architecture, or state clearer. Apply colors (`classDef`/`style`) and animated edges (`e1@{ animate: true }`) where the renderer supports them; colors are the baseline, animation is best-effort.

## Documentation Architecture

The learning material is a progressive technical book under `docs/`. These conventions are binding for every future evolution — add chapters, languages, OS, or harnesses by following them, not by inventing a new shape.

**README.md = slim hub.** Study context + ONE overview Mermaid diagram + a summary "when to use" table + a strong link to `docs/INDEX.md`. The deep teaching content does **not** live in the README — it lives in `docs/`. Each topic has a single source of truth; never duplicate deep content between README and `docs/` (drift is forbidden).

**`docs/` layout.**
- `docs/INDEX.md` — table of contents + introduction + the master reading order.
- **Spine (the linear book):** `01-foundations.md`, `02-cli-and-rules.md`, `03-agentic.md`, `04-when-to-use.md`, `05-best-practices.md`.
- **`docs/languages/`** — `java.md` (primary, deepest), `python.md`, `go.md`.
- **`docs/os/`** — `linux.md`, `wsl.md`, `macos.md`, `windows.md`.
- **`docs/harnesses/`** — `00-decision-policy.md` (the canonical, copy-pasteable "when ast-grep vs other tool" agent policy), then dedicated `claude-code.md`, `cursor.md`, `codex.md`, `pi.md`, `hermes.md`, plus a short table pointing Gemini CLI / Windsurf / Copilot to the canonical policy.
- **`docs/tools/`** — the companion **tool shelf** (the rest of the agent bench beside ast-grep): `00-overview.md` (taxonomy + decision matrix + recommended stack + the token-first tool policy), then one delta chapter per tool — `ripgrep.md`, `semgrep.md`, `repomix.md`, `files-to-prompt.md`, `markitdown.md`, `duckdb.md`, `qsv.md`, `ctags.md`. No `ast-grep.md` chapter (structural peers extend `04-when-to-use.md`). Each carries a `[verified]` benchmark from `scripts/bench-*.sh`.

**Progressive navigation.** One master linear order threads through everything: `INDEX → 01 → 02 → 03 → 04 → 05 → languages/* → os/* → harnesses/* → tools/*`. Every teaching doc ends with a manual `← Previous | Next →` footer following that order, so each has a real previous/next. In addition, reference docs cross-link siblings (java ↔ python ↔ go) and link back up to the spine chapter that introduced them (`↑ §03-agentic`).

**Separation by language & OS = deltas, not copies.** Canonical content lives once (usually in the spine or the primary language doc). Language- and OS-specific docs hold only the *deltas* and point to the canonical doc for depth (e.g. `os/macos.md` = install channel + `.dylib` + no `sg` collision, then "see: os/linux.md / §02 for the rest"). Do not reword a canonical chapter into a near-duplicate per OS/language.

**Verification labeling is load-bearing.** Mark every non-trivial claim `[verified]` (ran the tool on this machine, output captured) or `[sourced]` (official docs/repo) or `[sourced — unverified]` (could not confirm). **A `[verified]` label may only be applied to a pattern/command actually executed in the main thread** — never let a parallel/fanned-out subagent stamp `[verified]`, because subagents cannot reliably run the tool. Subagents draft prose, structure, and sourced comparisons; all tool execution stays in the main thread. Migrate real captured output (scan diagnostics, `--debug-query` dumps, JSON) verbatim — never paraphrase tool output.

**Harness config blocks are fetched-and-quoted, not recalled.** Config file paths and MCP-mount syntax churn fast and are easy to hallucinate — quote the official doc with its URL and a date stamp; if it can't be found, the block is `[sourced — unverified]`.

## Automation scripts (`scripts/`)

Deterministic, repeatable agent-ops procedures live in [`scripts/`](./scripts/). **Prefer the
script over re-deriving the steps** — each one encodes hard-won traps so they are not re-suffered.
Every script carries a `WHAT / WHY / WHEN / HOW` header comment; read it before first use.

| Script | Use it when |
|---|---|
| [`check-docs.py`](scripts/check-docs.py) | after any `docs/` change — gates relative links, GitHub anchors, and `[verified]`-label honesty |
| [`bench-tokens.sh`](scripts/bench-tokens.sh) | to (re)generate the token-efficiency fixtures and print the search + context-packing comparison tables (grep/rg/ast-grep/ctags + Repomix/files-to-prompt) |
| [`bench-tabular.sh`](scripts/bench-tabular.sh) | to measure DuckDB/qsv "query-don't-load" savings on a generated 100k-row CSV (+ a small XLSX) |
| [`bench-docs.sh`](scripts/bench-docs.sh) | to measure MarkItDown doc→Markdown size + table fidelity on generated docx/pptx/xlsx/pdf fixtures |
| [`semgrep-taint-demo.sh`](scripts/semgrep-taint-demo.sh) | to (re)confirm the Semgrep taint capability (1 finding on the unsanitized path, 0 on the sanitized control) |

**Standing rule — export repeatable procedures.** Whenever you hit a multi-step procedure that is
deterministic and likely to recur (release, registry verification, a gating/render check, an
environment workaround), **capture it as a `scripts/` script** with a `WHAT / WHY / WHEN / HOW`
header comment instead of re-deriving it inline, and add a row to the table above. If the script is
also useful to a human maintainer, the header comment is its documentation. This saves tokens and
makes the procedure auditable and reproducible.

## Agent skills

### Issue tracker

Issues and PRDs live as GitHub issues in `rodrigorjsf/ast-grep-for-agents` (use the `gh` CLI). See `docs/agents/issue-tracker.md`.

### Triage labels

The five canonical triage roles use their default label strings (`needs-triage`, `needs-info`, `ready-for-agent`, `ready-for-human`, `wontfix`). See `docs/agents/triage-labels.md`.

### Domain docs

Single-context: one `CONTEXT.md` + `docs/adr/` at the repo root. See `docs/agents/domain.md`.

## Applied Learning

When something fails repeatedly, when User has to re-explain, or when a workaround is found for a platform/tool limitation, add a one-line bullet here. Keep each bullet under 15 words. No explanations. Only add things that will save time in future sessions.

- Agents fail silently on wrong paths. Always verify hardcoded paths.
- ast-grep: invoke as `ast-grep`, never `sg` (collides with Linux setgroups).
- ast-grep Go: bare call patterns mis-parse; use `context`+`selector`.
- ast-grep no-match exits 1 (not 0); empty result ≠ error. Use `--debug-query`.
- WSL clones get CRLF; `.gitattributes` `eol=lf` or shell scripts break (`set -o pipefail\r`).
- Project `.venv` is uv-managed (no pip); use `uv pip install --python .venv/bin/python <pkg>`.
- `curl|sh` installers are sandbox-blocked; install via `brew` (no sudo) instead.
