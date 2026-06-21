# Opt-in `ast-grep-mcp` is mounted by a consented project `.mcp.json` the bootstrap writes and removes

A Claude Code plugin mounts the MCP servers declared in its bundled `.mcp.json`
**whenever the plugin is enabled** — the servers start with the plugin, with no
native per-setting toggle (`plugin-dev:mcp-integration`: "MCP servers start when
plugin enables"). So a server bundled at the plugin root cannot honor the `mcp:`
setting: it would always be on. To keep `ast-grep-mcp` genuinely opt-in (off by
default, per ADR-0002), the **bootstrap** owns the mount: when `mcp:` is on it
writes a project-level `.mcp.json` declaring `ast-grep-mcp` (the same consented,
HITL step the install flow already uses); when `mcp:` is off — the default — it
writes nothing and removes a `.mcp.json` it previously wrote. Default off mounts
nothing; the lightweight default stays the ast-grep CLI on `PATH` plus the policy
line.

This is the consented additive write ADR-0002 anticipated ("add a consented
`AGENTS.md` write to the bootstrap — additive, no rework"). ADR-0002's "the plugin
writes nothing into the repo" governs the *default, unconsented* path — the policy
delivery — and is unchanged: the MCP write happens only on explicit opt-in and is
fully reversible by turning `mcp:` off.

## Considered Options

- **Bundle `ast-grep-mcp` in the plugin-root `.mcp.json`** — rejected: always-on
  when the plugin is enabled, which violates the "default off mounts nothing"
  acceptance criterion. There is no per-setting conditional mount to gate it.
- **Documented manual step only** (README tells the user to add the server by
  hand) — rejected as the default: error-prone and it abandons the consent/install
  ergonomics the bootstrap already provides. It remains the fallback when the user
  declines the write.
- **Env-var substitution into a bundled config** — rejected: `${VAR}` expansion can
  parameterize a server's command/args/env, but it cannot make a declared server
  *absent*, so it can't express "off mounts nothing".

## Consequences

- The mount is HITL: the bootstrap presents the `.mcp.json` write, takes explicit
  consent (like the tool-install flow), and is reversible — `mcp: off` removes it.
- The project `.mcp.json` is a normal repo file the user owns; whether to commit it
  is their call. The README documents its lifecycle (written on `mcp: on`, removed
  on `mcp: off`) alongside the `.claude/*.local.*` gitignore entries.
- New seam: given the resolved `mcp:` setting → the project `.mcp.json` is present
  (declaring `ast-grep-mcp`) or absent. A pure check verified with fixtures, no live
  MCP process needed.
- `ast-grep-mcp`'s provenance/command must be cited from its upstream source in the
  written config, consistent with the self-contained-artifact rule.
