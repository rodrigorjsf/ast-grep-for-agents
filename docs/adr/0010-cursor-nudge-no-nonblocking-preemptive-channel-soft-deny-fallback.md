# Cursor has no single non-blocking + pre-emptive nudge channel; verify the allow-path, else fall back to a one-time soft-deny redirect

The Claude Code Nudge is `PreToolUse` → `permissionDecision: allow` + `systemMessage`: it is
**non-blocking and pre-emptive at the same time** — it reaches the agent *before* the wasteful
Read happens, without blocking it. In Cursor, `preToolUse` output is
`{ permission, user_message, agent_message, updated_input }`, but the doc describes the message
fields as **deny-path only**: `agent_message` = "message sent to agent **when denied**",
`user_message` = "message shown in client **when denied**".

So, per the documentation, **no single Cursor mechanism is both non-blocking and pre-emptive**:
- `preToolUse` can reach the agent pre-emptively, but (apparently) only by **denying** (blocking).
- `postToolUse` → `additional_context` reaches the agent non-blockingly, but only **after** the
  Read — too late to prevent the tokens already spent pulling a large file into context.

`[sourced — cursor.com/docs/hooks, 2026-06-21: preToolUse output fields and their "when denied"
descriptions quoted verbatim.]`
`[sourced — unverified: whether `agent_message` is also delivered on `permission: "allow"` is NOT
documented; the doc only ties it to deny. This is the single behavior to verify hands-on first.]`

## Decision

1. **At implementation, verify hands-on** whether `agent_message` reaches the agent on
   `permission: "allow"`. If it does, the faithful non-blocking + pre-emptive Nudge ports
   directly (best case).
2. **If it does not** (as the doc implies), fall back to a **one-time soft-deny + `agent_message`
   redirect** on the narrow triggers (a Read of a large / tabular / binary file): deny that first
   Read with a message pointing at the cheaper tool (ast-grep / DuckDB / MarkItDown). This
   **preserves the Nudge's actual value — preventing the wasteful read — at the cost of blocking
   that one call**, turning the Nudge from a pure *guide* into a *gate* on that path.

## Considered Options

- **`postToolUse` + `additional_context` (post-hoc coaching) — rejected.** Honors "never blocks"
  literally but fires after the Read; it cannot prevent the waste, only coach for next time. The
  large-file case is the main reason the Nudge exists, so post-hoc defeats its purpose.
- **Drop the Nudge, rely on the rule — rejected.** The user explicitly values the just-in-time
  catch; the always-on rule steers default reach but does not intercept a specific wasteful Read.

## Consequences

- **The Nudge concept gains a Cursor-specific shading:** where the harness offers no
  non-blocking pre-emptive channel, the Nudge may act as a **one-time soft-deny redirect** (a
  gate), not only a guide. `CONTEXT.md`'s "never blocks the call… is not a deny" is therefore
  **Claude-specific**, not a cross-harness invariant — the glossary is updated to say so.
- The soft-deny must stay **one-time per path** (the existing "never repeats for the same path"
  property), otherwise a re-deny of the same file loops the agent. The breadcrumb/state file
  already tracks per-path nudge history; reuse it.
- This asymmetry is a **finding of the planning pass**, surfaced by verifying the hook *output*
  contract — the layer the official sampled plugins (`continual-learning`, `ralph-loop`) never
  exercise, so there was no real-world example to copy.
