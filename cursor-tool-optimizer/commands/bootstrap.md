---
name: bootstrap
description: Bootstrap the local agent tool shelf — run the census, rank every tool by relevance to this codebase, and write the inventory render to .cursor/. Re-running is safe; the settings frontmatter is never churned.
---

# Bootstrap the tool shelf

<!-- [sourced — unverified]: Cursor command manifest shape derived from
     cursor.com/docs/reference/plugins and schemas/plugin.schema.json (2026-06-21).
     A live Cursor runtime is required to confirm the exact frontmatter field names
     and the slash-command invocation path. -->

<!-- HARNESS COUPLING NOTE: This is the Cursor-specific thin wrapper for the bootstrap
     skill. It sets TO_STATE_DIR=.cursor so census.sh and render.sh write their outputs
     under .cursor/ instead of the default .claude/. The shared scripts (census.sh,
     render.sh) are harness-agnostic; only this wrapper is Cursor-specific. -->

Invoke the `bootstrap` skill to build a ranked tool inventory for this codebase and
write a pre-rendered policy block to `.cursor/tool-optimizer.local.md`.

## What happens

1. **Census** — `census.sh` reads the tracked-file list (`git ls-files`) and produces
   bucketed counts (source by language, tabular, docs, notebooks, build files). An empty
   list means "global" mode (no codebase).

2. **Detect + Rank** — `detect.sh` probes the 10 core tools; `rank.sh` adds relevance
   verdicts and a recommended-install order, writing the full inventory JSON to
   `.cursor/tool-optimizer.local.json`.

3. **Render** — `render.sh` reads the inventory JSON and writes a pre-rendered markdown
   policy block to `.cursor/tool-optimizer.local.md`. Any existing YAML frontmatter
   (user settings: `enabled`, `nudge`, `mcp`) is **preserved** — re-running never
   churns it.

4. **Steps 3–6** of the skill (present → consent → install → MCP mount) are HITL — the
   agent drives them interactively after the census/render wiring completes.

## Environment wiring (Cursor-specific)

```sh
# The Cursor bootstrap sets TO_STATE_DIR=.cursor so all state lands under .cursor/:
#   .cursor/tool-optimizer.local.json  (inventory)
#   .cursor/tool-optimizer.local.md    (pre-rendered policy block)
export TO_STATE_DIR=".cursor"
```

The shared scripts default to `.claude`; this wrapper overrides the umbrella so
Cursor's state is segregated from any Claude Code state in the same project.

## Triggering this command

- **Slash command:** `/bootstrap` in a Cursor chat (registered via `plugin.json`
  `[sourced — unverified]`).
- **Natural language:** "check my tool shelf", "bootstrap tools", "set up tool-optimizer",
  or similar — the skill description and the rule guide the agent to invoke it.
