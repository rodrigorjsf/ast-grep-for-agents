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
| **Self-report** | When one of the plugin's *own* Bootstrap scripts is genuinely defective, the `report-error` skill files one **sanitized** issue on the plugin's upstream tracker — no user data, no repo name. |

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

## Self-report (the plugin reports its OWN defects)

If one of the plugin's *own* Bootstrap scripts (`detect.sh`, `census.sh`, `rank.sh`,
`render.sh`, `resolve.sh`, `pick_channel.sh`, `mount_mcp.sh`) is **genuinely defective** —
it crashes or emits clearly garbage output — the `report-error` skill files **exactly one**
GitHub issue on the plugin's **hardcoded** upstream tracker, `rodrigorjsf/ast-grep-for-agents`,
no matter which repo the plugin is installed in. (It does **not** infer the tracker from your
git remote — that would be the wrong destination and a privacy leak.)

**Hook on-failure breadcrumb.** Hook crashes are harder to surface than Bootstrap script
crashes — a `PreToolUse` crash only reaches the agent via the blocking exit code, and a
`SessionStart` crash is entirely silent until the next session. Each registered hook
(`session-start-policy.sh`, `nudge.sh`) installs a POSIX `EXIT` trap that, on any *unexpected*
non-zero exit, appends a single sanitized line — `artifact-identity#exit-code` — to a local,
gitignored breadcrumb file (`.claude/tool-optimizer.breadcrumb`). No paths, no file contents,
no network calls run on the hook hot path. The `SessionStart` hook reads this file at the start
of the next session; when non-empty, it appends a one-line pointer to the injected context
so the agent knows to invoke `report-error` to file the pending defect(s) upstream. This
mechanism recovers even the silent `SessionStart`-crash case across session boundaries.

The report is **sanitized by construction**: the main thread builds the report struct from an
**allowlist** of facts only —

- the failing script's **plugin-relative** path (your absolute path is stripped),
- the exit code / signal,
- the script's own error message, **scrubbed** of paths/secrets,
- an error class + a stable **fingerprint**,
- the **OS class**, the **plugin version** (read from the manifest), and the detected
  **package-manager set**,
- a **labeled synthetic reproduction** (no user paths/code/data) —

and hands the background filing subagent **only that struct**. Everything on the **denylist**
(your triggering path, file contents, repo name/remote/org, home dir/username/absolute paths,
env-var values, secrets) is synthesized or omitted, never copied. The `sanitize.sh` seam is the
single inspectable place that guarantee lives, and `sanitize.seam.sh` proves it by seeding a
user path, a home dir, a fake secret, and a repo name and asserting none of them survive.

An **expected outcome** — a documented no-match exit, an expected empty result, a genuinely
missing tool the bootstrap degrades around, or a declined consented install — is **not** a
defect and files nothing. The `needs-triage` label is applied when it can be; if it cannot,
the issue is filed anyway.

**Deduplication (best-effort).** Before filing, the skill searches the upstream tracker for an
open issue whose title carries the same `fp:<fingerprint>` marker. On a match:

- **Same context** (same `osClass`, `pluginVersion`, `packageManagers`): file nothing, add no
  comment — the defect is already tracked.
- **Meaningfully different context** (at least one of those three fields differs): add
  **one sanitized comment** to the existing issue instead of opening a duplicate.

The comment is built by `render-comment.sh` from the already-sanitized struct — the same trust
boundary as the issue body, provably no raw context.

> **Dedup is best-effort, not airtight.** GitHub search indexing lags by seconds, and the
> `fp:` marker tokenizes on punctuation — rapid double-fires can still occasionally create a
> duplicate. Do not rely on dedup as a hard guarantee.

## Files & `.gitignore`

The plugin keeps its state under your repo's `.claude/` and never writes to `CLAUDE.md` /
`AGENTS.md`:

| File | What | Commit it? |
|---|---|---|
| `.claude/tool-optimizer.local.json` | machine-detected tool inventory (regenerated by the bootstrap) | no — user-local |
| `.claude/tool-optimizer.local.md` | rendered SessionStart block + your settings | no — user-local |
| `.claude/tool-optimizer.breadcrumb` | hook on-failure breadcrumb (written by the EXIT trap; read and cleared by the agent after filing) | no — user-local |
| `.mcp.json` | the opt-in MCP mount (only when `mcp: on`) | your call — it's a normal project file |

Add the user-local files to `.gitignore`:

```gitignore
.claude/*.local.json
.claude/*.local.md
.claude/tool-optimizer.breadcrumb
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
