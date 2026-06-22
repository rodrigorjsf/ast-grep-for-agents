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

## preToolUse Nudge hook

The `hooks/nudge.sh` script fires before every Read tool call and redirects the agent
toward a cheaper specialized tool when the file matches a known expensive pattern
(tabular data, PDFs, Office docs, or a file larger than 100 KB).

### Soft-deny behavior

The hook implements the **soft-deny branch** from ADR-0010: the first time a matching
file path is seen in the session, the hook **denies the Read** and emits an
`agent_message` pointing at the cheaper tool (DuckDB/qsv for tabular data, the pdf
skill for PDFs, markitdown for Office docs, ripgrep for large files). The second time
the same path is seen, the hook allows silently (once-per-path — no repeat deny).
Non-triggering reads and reads on non-matching extensions always get a silent allow.

This is a **gate** (blocks the first Read) rather than a pure guide. The ADR-0010
rationale is that blocking the one wasteful call preserves the Nudge's actual value.
The "never blocks" property from the Claude Code variant does **not** carry over to
this Cursor fork — this asymmetry is documented in ADR-0010.

### Output envelope

```json
{ "permission": "deny", "agent_message": "<redirect message>" }
```

for a first trigger touch, and:

```json
{ "permission": "allow" }
```

for a second touch of the same path, a non-trigger, or when nudge is disabled.

`[sourced — unverified]`: the `preToolUse` output envelope and the behavior of
`agent_message` on deny vs. allow are cited from `cursor.com/docs/hooks` (2026-06-21).
A real Cursor runtime is required to confirm this schema.

### Tuning / disabling

Set `TO_NUDGE=off` (or write `nudge: off` in the bootstrap settings, which the render
script forwards as an env variable) to suppress all nudges. The default is `soft`.

### MANUAL CHECK 5 — (a) spike: does `agent_message` fire on `permission: "allow"`?

**Prerequisite:** a live Cursor runtime with the plugin installed.

This is the deferred spike from ADR-0010 decision point 1. If it turns out that
`agent_message` is also delivered to the agent when `permission: "allow"` (not just on
deny), the hook should be updated to use `allow` + `agent_message` instead of `deny` +
`agent_message` for the first trigger touch — that would make the Nudge non-blocking.

1. Write a temporary preToolUse hook that emits
   `{"permission":"allow","agent_message":"NUDGE-TEST-PROBE"}` for any Read.
2. Open a project in Cursor where the plugin is installed.
3. Trigger a Read tool call (ask the model to read any file).
4. Check whether the model received or acknowledged the `NUDGE-TEST-PROBE` string.
5. **If yes:** update `hooks/nudge.sh` to use `allow` instead of `deny` on first
   trigger touch (non-blocking nudge). Update this README and ADR-0010 accordingly.
6. **If no:** the soft-deny branch is correct as implemented. No change needed.

`[sourced — unverified]`: ADR-0010 §Decision, 2026-06-21.

### MANUAL CHECK 6 — (b) preToolUse envelope re-verification

**Prerequisite:** a live Cursor runtime.

The `{ "permission": "...", "agent_message": "..." }` preToolUse output envelope was
cited from `cursor.com/docs/hooks` (2026-06-21) and has not been confirmed against a
live Cursor runtime. Run the hook in real Cursor and verify:

1. That `permission: "deny"` actually blocks the Read tool call.
2. That `agent_message` is shown to / received by the agent when the call is denied.
3. That `permission: "allow"` (second touch or non-trigger) lets the Read proceed.

If the field names differ from the above, update `deny_with_msg` and `allow_silent`
in `hooks/nudge.sh` and re-run the seam tests.

`[sourced — unverified]`: cursor.com/docs/hooks, 2026-06-21.
