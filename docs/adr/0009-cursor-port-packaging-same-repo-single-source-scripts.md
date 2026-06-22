# The Cursor port ships as a sibling plugin dir in this repo, with harness-agnostic scripts single-sourced + synced and harness-coupled artifacts forked

The Cursor variant of `tool-optimizer` lives in **this same repo** as a sibling plugin
directory (`cursor-tool-optimizer/`) alongside the Claude Code plugin (`tool-optimizer/`),
not in a separate repository. A root `.cursor-plugin/marketplace.json` makes the repo a
Cursor marketplace; it is a separate namespace from any Claude `.claude-plugin/marketplace.json`,
so the two coexist without conflict. The shared decision log (`CONTEXT.md`, `docs/adr/`) and
the study docs stay in one place.

Because plugin installs **git-clone the whole plugin directory** and the
self-contained-artifact rule forbids an artifact referencing files outside its own plugin
dir, the two plugins cannot share scripts by symlink or `../shared/` reference at runtime —
**each must carry its own committed copy.** "Sharing" therefore means *single source +
copy step*, not a runtime reference.

## Decision

- **Canonical source** of the harness-agnostic shell stays in `tool-optimizer/` (the
  origin). The Cursor plugin receives **committed copies**.
- **The 3 path-coupled scripts** (`mount_mcp`, `render`, `resolve`) are made
  harness-agnostic by **env-var parameterization** (e.g. `TO_STATE_DIR=.cursor`,
  `TO_MCP_CONFIG=.cursor/mcp.json`), so one source works in both harnesses; the host
  hook/skill sets the env. The ~7 pure scripts (`census`, `detect`, `rank`,
  `pick_channel`, `sanitize`, `render-comment`, `file-or-pend`) are already agnostic.
- **A sync procedure** (`scripts/sync-cursor-plugin.sh`, per the project's "export
  repeatable procedures" rule) copies the agnostic scripts into `cursor-tool-optimizer/`,
  and a **drift check** (extend `check-docs.py`/CI) fails if a copy diverges from its
  source.
- **Genuinely harness-coupled artifacts are forked** (no sharing attempted): `hooks.json`
  (different schema), `session-start-policy.sh` and `nudge.sh` (Cursor stdin/stdout JSON
  envelopes), `.cursor-plugin/plugin.json`, the rule `.mdc` (Cursor-only), and the thin
  `commands/` wrapper (Cursor-only).

## Considered Options

- **Separate repo — rejected.** Cleaner standalone Cursor marketplace, but it splits the
  decision log, duplicates the study context, and makes keeping the two ports in sync a
  cross-repo chore.
- **Duplicate scripts and maintain by hand — rejected.** Simple today; guarantees drift
  tomorrow (a one-line fix must land in two places across ~10 scripts) with no guard.
- **Runtime-shared scripts (`../shared/`) — not viable.** Violates the
  self-contained-artifact rule and the git-clone-whole-dir constraint; the reference would
  dangle once installed.

## Consequences

- The installed Cursor plugin is **self-contained** — the sync produces committed copies
  that travel with the clone; nothing references the Claude plugin dir.
- Env-parameterizing `mount_mcp`/`render`/`resolve` is a small refactor to the **Claude
  plugin too** (it reads the env with `.claude`-flavored defaults), keeping one source of
  truth rather than forking three scripts.
- New drift surface: the sync-copy equality is **testable** (the drift check), the same
  posture as the existing seam tests.
- The forked hook scripts need their **own seam tests** for the Cursor JSON envelopes; the
  `sanitize.seam.sh` privacy test ports verbatim since `sanitize.sh` is shared and unchanged.
- Local dev install path for the Cursor plugin is `~/.cursor/plugins/local/<name>/`
  `[sourced — cursor/plugins @ create-plugin/skills/create-plugin-scaffold/SKILL.md]`.
