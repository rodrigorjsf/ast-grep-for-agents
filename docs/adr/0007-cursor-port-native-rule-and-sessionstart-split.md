# Cursor port re-derives capabilities with native primitives; static policy ships as a native rule, the per-machine inventory via a `sessionStart` hook

Porting `tool-optimizer` to Cursor, "the same plugin" means **the same capabilities
re-derived with Cursor-native primitives**, not the Claude Code architecture mirrored
mechanism-for-mechanism. The first and load-bearing consequence is policy delivery.

Unlike Claude Code (ADR-0002: "Claude Code plugins have no native `rules/` component"),
**Cursor has a native `rules/` component** — `.mdc` files with `alwaysApply: true`
frontmatter. So the **static** token-first Policy ships as a native rule, and the
**dynamic** per-machine available-tools inventory — which a static rule cannot
interpolate at session time — ships via a `sessionStart` hook emitting
`additional_context`.

`[sourced — cursor/plugins @ create-plugin/rules/plugin-quality-gates.mdc and
schemas/plugin.schema.json; cursor.com/docs/reference/plugins, 2026-06-21]`
`[sourced — cursor.com/docs/hooks, 2026-06-21: sessionStart output is quoted verbatim as
`{ "env": {...}, "additional_context": "<context to add to conversation>" }`, where
`additional_context` "adds context to the conversation's initial system context". A
third-party hook (OthmanAdi/chronos `session_start.sh`) emits `additional_context`,
corroborating real-world use.]`

## Considered Options

- **Native rule (static) + `sessionStart` hook (dynamic) — chosen.** Each half uses the
  primitive built for it. The rule is always-on standing context with zero per-event cost;
  the hook does the one thing a static rule provably cannot — inject a value computed on
  *this* machine.
- **Mirror Claude: both halves via the hook, no rule — rejected.** Contradicts the root
  posture (re-derive, not mirror) and ignores the native `rules/` primitive that is the
  whole reason ADR-0002's hook workaround is unnecessary here.
- **Rule only, drop the dynamic inventory — rejected as default.** Simplest (no policy
  hook at all), but it loses the always-present machine inventory the Claude version
  injects; the agent would have to read the bootstrap-written config file on its own
  initiative. Kept as the graceful-degradation fallback (see Consequences).

## Consequences

- ADR-0002's rationale ("no native rules → deliver policy by `SessionStart`") is
  **Claude-Code-specific and does not carry to Cursor.** The Cursor variant deliberately
  uses the native rule ADR-0002 lacked. ADR-0002's deeper principle — *the plugin writes
  nothing into the user's repo by default* — **is preserved**: a bundled rule and a
  fire-and-forget hook both write nothing to the user's tree.
- The rule must **inline** the Policy text. The self-contained-artifact rule forbids a
  plugin artifact from referencing repo docs (`docs/tools/00-overview.md`), which do not
  travel with an installed plugin.
- **The two halves degrade differently — do not conflate them.** The static Policy is
  delivered by the always-on rule, so it survives any hook failure: that is genuine graceful
  degradation. The **dynamic inventory has a hard dependency** on the `sessionStart` hook
  delivering `additional_context` — it is the *only* channel for it. That channel is now
  verified to exist (see source label), so the dependency is satisfiable; but if the hook is
  absent or crashes, the inventory is simply **not delivered** (the agent loses the
  per-machine list, falling back to detecting tools itself). "Graceful degradation" describes
  the Policy, not the inventory — the inventory either arrives via the hook or not at all.
- Disabling/uninstalling the plugin removes both the rule and the hook cleanly — the same
  clean-removal property ADR-0002 valued.
