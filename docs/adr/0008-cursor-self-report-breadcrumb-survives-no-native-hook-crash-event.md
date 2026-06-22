# In the Cursor port, the self-report capability ports verbatim and the EXIT-trap breadcrumb is deliberately retained

The `report-error` capability (sanitize-by-construction seam, defect gate, best-effort
dedup, gh-absent pending-JSONL fallback) is harness-agnostic POSIX shell + `gh`, so it
ports to Cursor **verbatim** — ADR-0006's reasoning is unchanged. The only harness-coupled
piece is **failure capture**: how the plugin learns that one of its *own* hooks crashed.

Cursor's native failure events — `postToolUseFailure` (`error_message`, `failure_type`)
and `sessionEnd.error_message` — describe **the agent's tool/session failing, not a plugin
hook script crashing**. There is no native "my hook crashed" event. So the self-instrumenting
`EXIT`-trap breadcrumb from ADR-0006 (slice #26) is **not** redundant in Cursor; it remains
the only way to catch a silent crash of the plugin's own `sessionStart`/`preToolUse` hooks.

`[sourced — cursor.com/docs/hooks, 2026-06-21: the recovery channel — `sessionStart` output
`additional_context` — is quoted verbatim and confirmed.]`
`[sourced — unverified — the claim that `postToolUseFailure`/`sessionEnd` describe *agent/session*
failures (not plugin-hook crashes) rests on their input field sets read through the WebFetch
summarizer; the absence of any "hook-crashed" event is inferred from the full event list, not an
explicit doc statement. Re-verify at implementation time.]`

## Consequences

- The breadcrumb file, the `EXIT` trap, and the read-and-inject recovery all carry over from
  ADR-0006 with no mechanism change — only the host harness differs.
- **The `sessionStart` hook does double duty.** The same hook ADR-0007 adds for the dynamic
  inventory also reads the breadcrumb at the start of the next session and folds a one-line
  "invoke `report-error`" pointer into its `additional_context`. No new hook is introduced for
  recovery.
- This is a **deliberate non-change**: a future reader will reasonably assume Cursor's richer
  lifecycle replaced the breadcrumb. It did not. Removing the breadcrumb on that assumption
  would silently drop coverage of the plugin's own hook crashes.
- The upstream tracker stays hardcoded to `rodrigorjsf/ast-grep-for-agents` (ADR-0006), never
  inferred from the user's git remote — unchanged by the port.
