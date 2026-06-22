# cursor-tool-optimizer

Cursor port of the `tool-optimizer` plugin. Delivers the token-first **Policy** as a
native Cursor **Rule** (`alwaysApply: true`), so the agent always has standing guidance
on which tool fits each task shape.

This is the tracer-bullet slice: the Plugin manifest, the Policy Rule, and the repo's
Cursor marketplace manifest. Hooks, skills, and the MCP mount are added in sibling slices.

## Install

Cursor installs plugins by pointing at a local path or a GitHub repository containing a
`.cursor-plugin/plugin.json`. To install from this repository locally:

```
~/.cursor/plugins/local/cursor-tool-optimizer/
```

Copy (or symlink during development) the `cursor-tool-optimizer/` directory to that path,
then restart Cursor. The marketplace manifest at `.cursor-plugin/marketplace.json` in the
repo root lists this plugin.

## Uninstall

Remove the plugin directory from `~/.cursor/plugins/local/`. The plugin writes **nothing**
into the user's repo (no `.cursor/` files, no config), so removal is clean.

## Manual verification checks

The Policy Rule (`.mdc`) is a declarative Cursor artifact — there is no programmatic
seam to assert it is active. These checks must be run manually after install/update.

### Check 1 — Plugin is installed

1. Open Cursor Settings → Plugins.
2. Confirm `cursor-tool-optimizer` appears in the installed list.

### Check 2 — Policy Rule is always-applied in a session

1. Open any project in Cursor.
2. Open a new chat (Ctrl+L / Cmd+L).
3. Ask the model: "What is your current tool policy?" or "Summarize any tool-use
   guidelines you have been given."
4. The model's response should reference the token-first heuristics: ripgrep for
   literal/regex search, ast-grep for syntax-aware search, repomix/files-to-prompt for
   packing context, the guardrail ("a non-standard tool must beat the standard tool on
   tokens or capability"), and the self-report clause (`rodrigorjsf/ast-grep-for-agents`).

### Why these are manual-only

The `.mdc` rule is applied by Cursor's runtime at session start. There is no hook or
script output to assert in CI — the guarantee is structural: a `.mdc` file with
`alwaysApply: true` in a correctly installed plugin is always injected. If the rule text
changes, `scripts/check-docs.py` will catch it via the content-presence assertions.

## sessionStart hook

The `hooks/session-start-policy.sh` script emits the per-machine tool inventory (if
bootstrapped) into Cursor's `additional_context` channel at every session start.

The output envelope used by the hook is:

```json
{ "env": {}, "additional_context": "<context to add to conversation>" }
```

`[sourced — unverified]`: this envelope shape is cited in ADR-0007 from
`cursor.com/docs/hooks` (2026-06-21). **A real Cursor runtime is required to confirm
it.** The hook is not testable in CI without a live Cursor process.

### MANUAL CHECK 3 — sessionStart hook injects inventory

**Prerequisite:** run the bootstrap skill (`cursor-tool-optimizer` → `bootstrap`) so
`.cursor/tool-optimizer.local.md` exists.

1. Open a project in Cursor where the plugin is installed and the bootstrap has run.
2. Open a new chat (Ctrl+L / Cmd+L).
3. Ask the model: "What tools do you have available on this machine?" or "Summarize
   the tool-optimizer inventory you received at session start."
4. The model should list the tools from the bootstrapped inventory (e.g. `ripgrep`,
   `ast-grep`) rather than guessing.

### MANUAL CHECK 4 — graceful degradation without bootstrap

1. Remove or rename `.cursor/tool-optimizer.local.md`.
2. Open a new chat.
3. Ask the model the same question.
4. The model should still quote the static Policy (token-first guardrails) because
   the hook falls back to it when the pre-rendered file is absent.

### Why these hook checks are manual-only

Cursor's `sessionStart` output envelope schema (`additional_context`) is
`[sourced — unverified]` — it was cited from `cursor.com/docs/hooks` (2026-06-21) but
could not be confirmed against a live Cursor runtime during development. The seam test
(`tests/tool-optimizer/hooks/session-start-policy.seam.sh`) asserts the envelope shape
programmatically; this manual check closes the remaining gap by running the hook in the
actual Cursor process.
