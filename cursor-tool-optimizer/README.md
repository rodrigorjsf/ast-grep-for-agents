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

## Bootstrap logic layer

The bootstrap's decision-making is implemented by three harness-agnostic scripts
(`skills/bootstrap/scripts/`). Each behaviour corresponds to an acceptance criterion
and has a passing seam test — see `tests/tool-optimizer/skills/bootstrap/scripts/`.

### Relevance reported with evidence (AC1)

`rank.sh` runs `census.sh` internally to count file types in the tracked-file list, then
assigns every tool a verdict (`HIGH`, `MED`, `LOW`, `NA`, `GEN-core`, `GEN-conditional`)
**with evidence sourced from the census** — e.g. `"0 tabular files → DuckDB low relevance
here"` or `"60 java → structural search pays off"`. The evidence is written into the
`relevance[].evidence` field and is never improvised by the agent; it is always read back
from the inventory JSON. No tool is omitted: every run produces exactly 10 `relevance[]`
entries. See the rank scenarios in `rank.seam.sh` (scenarios A–E + idempotency properties).

### Consented install via non-privileged channels only (AC2)

`pick_channel.sh` chooses an install command for each tool given the available package
managers (`brew`, `npm`, `pipx`, `uv`, `cargo`, `scoop`, `winget`) and the detected OS.
It prints one TAB-separated line:

- `RUN<TAB><command>` — a non-privileged command the bootstrap is allowed to run **after
  explicit, per-tool user consent**.
- `MANUAL<TAB><command>` — advice shown to the user as text only, **never auto-run**.
  Covers `sudo apt`, `curl … | sh`, `pip`, from-source builds, and any case where no
  eligible package manager is installed.

`curl … | sh` and `sudo` paths are always `MANUAL`, never `RUN`. See
`pick_channel.seam.sh` for the full channel matrix and OS-eligibility assertions.

### Failed or impossible install degrades to advice; bootstrap continues (AC3)

Step 5 of `skills/bootstrap/SKILL.md` specifies: if `pick_channel.sh` returns `MANUAL`,
or if a `RUN` command exits non-zero, the agent prints the manual command as advice and
**continues** to the next tool. A single locked-down or failing tool never aborts the
run. This degrade-and-continue contract is described in the verbatim `SKILL.md` (shared
from `tool-optimizer/`); the HITL loop is not auto-testable without a live environment
(see manual check below).

### Key-by-key scope resolution: `project[key] ?? global[key]` (AC4)

`resolve.sh` implements a shallow two-scope merge:

1. Read the project-scope config (default: `<TO_STATE_DIR>/tool-optimizer.local.json`).
2. Read the global-scope config (default: `~/.claude/tool-optimizer.global.json`).
3. Merge key-by-key: a project key **wins** over the same global key; a global key with
   no project counterpart **falls through**; a project-only key is included. Missing
   files are treated as `{}`.

`TO_STATE_DIR=.cursor` shifts the project-scope default to `.cursor/` (Cursor port).
`PROJECT_CONFIG` / `GLOBAL_CONFIG` override the defaults explicitly. See
`resolve.seam.sh` cases 1–5 for all three resolution cases plus the state-dir contract.

### Canonical flow

The full present → consent → install → re-probe sequence is described in
`skills/bootstrap/SKILL.md` (the canonical, verbatim skill shared across harnesses).
The scripts above supply its deterministic sub-routines; the HITL loop wraps them.

### MANUAL CHECK 8 — HITL present / consent / install / re-probe loop

The consent-and-install loop cannot be exercised in CI because it requires a live agent
session and real package manager calls. These checks must be run manually after a fresh
install of the plugin.

**Prerequisites:** plugin installed in Cursor; at least one tracked tool missing from
`PATH` (confirm with the bootstrapped `.cursor/tool-optimizer.local.json`).

1. Open a project in Cursor and type `/bootstrap` (or "check my tool shelf") in a new
   chat.
2. Confirm the agent lists **every** missing tool, split into two tiers (recommended and
   "show, don't push"), each with its Relevance verdict and codebase evidence.
   - E.g. a docs-only repo should show ast-grep as `NA` (not recommended), not hide it.
   - A data-heavy repo should show DuckDB as `HIGH` and head the recommended list.
3. For a recommended tool, the agent should ask for per-tool confirmation before running
   any install command. Confirm that the exact `RUN` command from `pick_channel.sh` is
   shown and that a `MANUAL` command is shown as text only (not executed).
4. Approve one install. Confirm the agent runs the install, then re-probes with
   `command -v <binary>` — **not** by re-running `detect.sh` mid-loop.
5. Decline an install. Confirm the agent skips to the next tool without aborting.
6. Simulate a failed install (or choose a tool with a `MANUAL`-only channel). Confirm
   the agent prints the manual advice and continues to the next tool (does not abort).
7. After the loop, confirm `.cursor/tool-optimizer.local.md` is written and contains the
   `## Local tool policy` section.

**Why this is manual-only:** steps 2–6 require a live agent driving the `AskUserQuestion`
consent loop; there is no harness-injectable seam for the HITL flow itself.

## Bootstrap skill + command

The `bootstrap` skill (`skills/bootstrap/SKILL.md`) sets up the local tool shelf: it
runs a census of the tracked-file list, ranks all 10 core tools by relevance to this
codebase, writes the inventory to `.cursor/`, and then drives a HITL present → consent
→ install loop. The skill is shared between harnesses (verbatim from `tool-optimizer/`);
only the command wrapper is Cursor-specific.

### Triggering the bootstrap

**Slash command** — type `/bootstrap` in any Cursor chat.
`[sourced — unverified]`: the `/bootstrap` slash command is registered in
`.cursor-plugin/plugin.json` via the `commands` array. The exact field names and
invocation path derive from `cursor.com/docs/reference/plugins` and
`schemas/plugin.schema.json` (2026-06-21) but have not been confirmed against a live
Cursor runtime.

**Natural language** — phrases like:
- "check my tool shelf"
- "bootstrap tools"
- "set up tool-optimizer"
- "what tools do I have installed?"

The always-applied Policy Rule and the skill description together guide Cursor's agent to
invoke the bootstrap skill in response to these phrases.

### What the bootstrap writes under `.cursor/`

| File | Contents |
|---|---|
| `.cursor/tool-optimizer.local.json` | Full inventory JSON (available/version/path/category + census + relevance) |
| `.cursor/tool-optimizer.local.md` | Pre-rendered markdown policy block (read by the sessionStart hook at every session) |

The command wrapper sets `TO_STATE_DIR=.cursor` so all outputs land under `.cursor/`
instead of the shared-script default (`.claude/`).

### Settings frontmatter stability (re-run safety)

`render.sh` preserves any existing YAML frontmatter in `.cursor/tool-optimizer.local.md`
on every re-run — only the body block is regenerated. User settings (`enabled`, `nudge`,
`mcp`) live in the frontmatter and are **never churned**. Re-running the bootstrap is
safe at any time.

### Manual demo

To verify the bootstrap end-to-end after installing the plugin:

1. Open a project in Cursor.
2. Type `/bootstrap` (or "check my tool shelf") in a new chat.
3. Confirm `.cursor/tool-optimizer.local.json` appears with a `detectedAt` timestamp.
4. Confirm `.cursor/tool-optimizer.local.md` contains the `## Local tool policy` section.
5. Run the bootstrap a second time. Check that the frontmatter in `.cursor/tool-optimizer.local.md`
   is unchanged (settings not churned).

### MANUAL CHECK 7 — bootstrap command is registered

1. Open Cursor Settings → Plugins → `cursor-tool-optimizer`.
2. Confirm the `bootstrap` command appears in the plugin's command list.
3. In a chat, type `/` — `bootstrap` should appear in the completion suggestions.

`[sourced — unverified]`: slash command registration via `plugin.json` `commands` array.

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
