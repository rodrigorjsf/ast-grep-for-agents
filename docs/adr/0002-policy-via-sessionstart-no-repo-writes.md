# Policy delivered by SessionStart injection; the plugin writes nothing into the repo

Claude Code plugins have no native `rules/` component — the only plugin-native way to
inject standing context is a `SessionStart` hook. So the token-first tool policy is
delivered by the plugin's `SessionStart` hook (policy text + the available-tools summary
read from the resolved config), and the plugin deliberately writes **nothing** into the
user's repository — not `CLAUDE.md`, not `AGENTS.md`. Disabling the plugin removes the
policy cleanly, which is the correct behavior for a plugin-provided concern.

## Considered Options

- **Bootstrap writes the policy into `AGENTS.md`** (portable, cross-harness, read by
  Cursor/Codex; Claude Code bridges via `@AGENTS.md`) — rejected as default: it turns
  the plugin into something that edits repo files (a review/commit surface) for reach
  that is out of scope for a Claude Code plugin. It remains an easy additive opt-in later.
- **Append the policy to the project `CLAUDE.md`** — rejected: Claude-specific (no
  cross-harness gain) and intrusive into a file the repo owner usually curates by hand.

## Consequences

- There is no `rules/` directory in the plugin; "the rules" are the SessionStart payload.
- Cross-harness reach (Cursor/Codex/Windsurf) is explicitly out of scope; if wanted later,
  add a consented `AGENTS.md` write to the bootstrap — additive, no rework.
- The MCP server (`ast-grep-mcp`) is opt-in (off by default); the lightweight default is
  the ast-grep CLI on `PATH` plus the policy line, per the repo's own verdict.
