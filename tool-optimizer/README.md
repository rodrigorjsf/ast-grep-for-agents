# tool-optimizer

A Claude Code plugin that makes the agent **reach for the cheapest tool that fits the
task** — a token-first policy injected every session, a one-command shelf bootstrap, and an
opt-in `ast-grep` MCP mount. No tool is deny-listed; the policy only changes the *default
reach* so the agent stops `cat`-ing whole files and grepping a tree when a structural or
indexed tool answers in a fraction of the tokens.

## What it does

| Piece | How it shows up |
|---|---|
| **Token-first policy** | A `SessionStart` hook injects a short "pick the tool by the shape of the task" policy + the list of tools actually installed on this machine. |
| **Soft nudge** | A `PreToolUse` hook gives a one-time, non-blocking reminder when a cheaper specialized tool would fit — never blocks the call. |
| **Bootstrap** | The `bootstrap` skill detects the 10 core tools, ranks each by relevance to *this* codebase, and offers a consented, non-privileged install of the missing ones. |
| **Opt-in MCP** | When the `mcp` setting is on, the bootstrap mounts the `ast-grep` MCP server via a project `.mcp.json`. Off by default. |

## Install

This is a standard Claude Code plugin. Add the marketplace that ships it, then enable the
plugin from the `/plugin` menu:

```
/plugin marketplace add <owner>/<repo>
/plugin install tool-optimizer
```

Enabling the plugin activates the `SessionStart` policy and the `PreToolUse` nudge
immediately — no repo files are written until you run the bootstrap.

## Bootstrap the tool shelf

Run the `bootstrap` skill (ask: *"bootstrap the tool-optimizer tools"* / *"check my tool
shelf"*). It works at two **Scopes**:

- **Project** (default) — run it inside a repo. It censuses the codebase (`git ls-files`,
  no full-tree walk) and ranks each tool by relevance *to this project* ("1,240 `.java` →
  structural search pays off"; "0 tabular files → DuckDB low relevance here"). Writes the
  project inventory to `.claude/tool-optimizer.local.json`.
- **Global** — no codebase, so it gives generic recommendations and points you to run a
  project bootstrap for codebase-specific advice. Writes `~/.claude/tool-optimizer/config.json`.

For every **Missing** tool the bootstrap shows where the agent would use it, asks for
explicit consent, and runs only a **non-privileged** install channel (`brew`/`pipx`/`uv`/…);
`sudo` and `curl … | sh` are shown as text for you to run, never auto-run. A failed or
impossible install degrades to advice and the bootstrap continues.

## Settings & Scopes

Settings live in the **YAML frontmatter** of the settings file — `.claude/tool-optimizer.local.md`
for the project, `~/.claude/tool-optimizer/tool-optimizer.local.md` for the global default.
They sit in frontmatter (not the inventory JSON) precisely so re-running the bootstrap never
churns them. Settings resolve across the two Scopes **key-by-key — `project[key] ?? global[key]`** —
so a repo can specialize one key without restating the whole config.

```markdown
---
mcp: on
---
## (the rest of this file is the bootstrap-rendered policy block — leave it alone)
```

| Setting | Values | Default | Status | Effect |
|---|---|---|---|---|
| `mcp` | `on` · `off` | `off` | **wired** | `on` mounts the `ast-grep` MCP server (see below); `off` mounts nothing and removes a mount it previously wrote. |
| `nudge` | `soft` · `off` | `soft` | partial | The `PreToolUse` reminder defaults to `soft`; it is tunable via the hook's `TO_NUDGE` env. Reading it from frontmatter is planned. |
| `overrides` | map | *(none)* | planned | Reserved for per-project overrides of the fixed config — e.g. remap the tool→category mapping. Not yet implemented. |

## Opt-in `ast-grep` MCP

The lightweight default is the `ast-grep` **CLI on `PATH`** plus the policy line — no MCP
process. Turn the server on only when you want the four MCP tools (`dump_syntax_tree`,
`test_match_code_rule`, `find_code`, `find_code_by_rule`) wired directly into the agent.

Set `mcp: on` in the `.claude/tool-optimizer.local.md` frontmatter and re-run the bootstrap.
On explicit consent it writes a **project-scope** `.mcp.json` at the repo root, adding only
the `ast-grep` server and preserving any other servers you already have:

```json
{
  "mcpServers": {
    "ast-grep": {
      "command": "uvx",
      "args": ["--from", "git+https://github.com/ast-grep/ast-grep-mcp", "ast-grep-server"],
      "env": {}
    }
  }
}
```

The command runs the upstream server (<https://github.com/ast-grep/ast-grep-mcp>) straight
from git, so the committable `.mcp.json` carries no machine-specific path. (The assembled
invocation is sourced from the upstream repo but not verified end-to-end here; for a pinned
or custom command, use `claude mcp add --scope project` instead and leave `mcp` off.)

**Writing `.mcp.json` does not auto-start the server.** Claude Code prompts for approval the
first time it sees a project-scoped server, or you pre-approve it with the
`enableAllProjectMcpServers` / `enabledMcpjsonServers` settings; the file is read at session
start, so restart the session after it changes.
`[sourced — https://code.claude.com/docs/en/mcp, 2026-06-21]`

Setting `mcp: off` and re-running the bootstrap removes the `ast-grep` entry again (and
deletes `.mcp.json` if nothing else is left in it).

## Files & `.gitignore`

The plugin keeps its state under your repo's `.claude/` and never writes to `CLAUDE.md` /
`AGENTS.md`:

| File | What | Commit it? |
|---|---|---|
| `.claude/tool-optimizer.local.json` | machine-detected tool inventory (regenerated by the bootstrap) | no — user-local |
| `.claude/tool-optimizer.local.md` | rendered SessionStart block + your settings | no — user-local |
| `.mcp.json` | the opt-in MCP mount (only when `mcp: on`) | your call — it's a normal project file |

Add the two user-local files to `.gitignore`:

```gitignore
.claude/*.local.json
.claude/*.local.md
```

The `.mcp.json` is yours: commit it to share the `ast-grep` server with the team (the
project scope is designed to be version-controlled), or ignore it for a personal setup.

## Why it saves tokens

Each tool on the shelf wins on the same axis — return the answer, not the haystack:

- **Structural over text** — `ast-grep -p 'foo($A)'` returns the handful of real call sites
  instead of every line that mentions `foo`; on a large repo that is a few hundred tokens of
  matches versus tens of thousands of grep hits to read past.
- **Query over load** — `duckdb -c "SELECT … FROM 'f.csv'"` answers from a 100k-row CSV
  without ever pulling the file into context.
- **Pack over `cat`** — `repomix` / `files-to-prompt` emit a structured, token-counted view
  of a tree or file-set instead of raw concatenation.

The figures above are illustrative; the project's benchmark suite measures the exact
search-, packing-, and tabular-query savings on generated fixtures.
