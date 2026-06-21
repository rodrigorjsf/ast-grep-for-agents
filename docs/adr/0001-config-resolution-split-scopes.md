# Config resolution: split inventory from settings, two scopes, project overrides global

The bootstrap persists a deterministic, machine-detected **tool inventory** as JSON
(`~/.claude/tool-optimizer/config.json` global, `.claude/tool-optimizer.local.json`
project) separate from the user's **settings** in `.claude/tool-optimizer.local.md`
(YAML frontmatter + a body block). Both a global and a project scope always exist;
resolution is key-by-key — `project[key] ?? global[key]`. We chose this over a single
file because re-running detection must rewrite the inventory without churning the
human-edited settings, and because it honors both the handoff's "deterministic JSON"
requirement and the `plugin-dev:plugin-settings` `.local.md` convention at once.

## Considered Options

- **Single `.local.json`** — rejected: re-detection rewrites the file the user edits;
  the SessionStart hook would need `jq` on the hot path.
- **Single `.local.md` frontmatter** — rejected: a nested per-tool inventory is awkward
  in the flat-scalar YAML the convention's `sed`/`grep` parser can read, and it doesn't
  satisfy the deterministic-JSON requirement.

## Consequences

- The SessionStart hook reads the rendered block from the `.local.md` **body**, so the
  hot path needs no `jq`; the JSON inventory is consumed only by the bootstrap skill
  (re-detect / diagnostics).
- `.gitignore` must cover `.claude/*.local.md` and `.claude/*.local.json` (both are
  user-local, not committed).
- Global scope lives under `~/.claude/tool-optimizer/`, which the `plugin-settings`
  convention does not itself prescribe (it is project-only) — this is a deliberate delta.
