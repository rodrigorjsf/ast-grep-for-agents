---
name: report-error
description: >-
  Files exactly one sanitized defect report to the tool-optimizer plugin's upstream tracker
  when one of its own Bootstrap scripts is genuinely broken. Use when a tool-optimizer
  Bootstrap script (detect.sh, census.sh, rank.sh, render.sh, resolve.sh, pick_channel.sh,
  mount_mcp.sh) crashes unexpectedly, exits with an unhandled error, or emits clearly garbage
  output — i.e. the script itself is defective, not the environment. Do NOT use it for an
  expected outcome (a documented no-match exit, an expected empty result, a genuinely missing
  tool you degrade around, or a declined consented install).
---

# Report a tool-optimizer self-defect (sanitize → file ONE upstream issue)

When a tool-optimizer **Bootstrap script is genuinely defective**, this skill turns the failure
into a **sanitized** defect report and files **exactly one** GitHub issue on the plugin's
**hardcoded upstream tracker** — `rodrigorjsf/ast-grep-for-agents` — regardless of which repo
the plugin is installed in. The report carries only allowlisted facts; it never carries your
paths, code, data, secrets, or repo name.

The guarantee is **sanitize-by-construction**: the main thread builds the report struct with
`sanitize.sh` and hands the background filing subagent **only that struct** — never the raw
transcript, the failing command's arguments, your file paths, or your code. The subagent
cannot leak what it was never given.

## Step 0 — Confirm it is a real defect (gate)

File a report **only** when the script itself misbehaved. These are defects:

- the script **crashed** (segfault, unhandled signal, an interpreter/syntax error in the
  shipped script);
- it exited **non-zero in a way the script does not document** as an outcome;
- it produced **clearly garbage output** (malformed JSON where JSON is promised, an empty
  inventory where tools are installed, a truncated render).

These are **expected outcomes — do NOT report them**:

- a **documented no-match / no-op exit** (e.g. ast-grep exiting 1 on zero matches);
- an **expected empty result** (an empty census because the repo has no tracked files);
- a **genuinely missing tool** the bootstrap degrades around (install declined or impossible);
- a **declined consented install** (the user said no — that is the design, not a bug).

If the failure is any of the expected outcomes, **stop here — file nothing.**

## Step 1 — Gather the raw context (main thread only)

Collect the minimum the sanitizer needs. The sanitizer scrubs all of it; you still pass real
values so the scrub has something to remove.

```sh
ARTIFACT="<absolute path to the failing Bootstrap script>"   # e.g. .../tool-optimizer/skills/bootstrap/scripts/detect.sh
EXITCODE="<exit code or signal>"                              # e.g. 127, or SIGSEGV
ERRMSG="<the script's own stderr tail>"                       # the tool's own message, verbatim
ERRCLASS="crash"                                              # or: garbage-output | exit-nonzero

# OS class + package-manager set — the SAME snippet the bootstrap uses, so the report
# describes the same environment facts (no new detection logic).
case "$(uname -s)" in Darwin) OSCLASS=macos;; Linux) grep -qi microsoft /proc/version 2>/dev/null && OSCLASS=wsl || OSCLASS=linux;; *) OSCLASS=windows;; esac
MGRS=""; for m in brew npm pipx uv cargo scoop winget; do command -v "$m" >/dev/null 2>&1 && MGRS="$MGRS,$m"; done; MGRS="${MGRS#,}"
```

## Step 2 — Build the sanitized struct (the only thing the subagent ever sees)

Run the sanitizer. It emits a JSON struct holding **only** the allowlisted fields and a
**labeled synthetic reproduction**, with every denylisted shape scrubbed or synthesized away.

```sh
S="${CLAUDE_PLUGIN_ROOT}/skills/report-error/scripts/sanitize.sh"
TO_ERR_ARTIFACT="$ARTIFACT" \
TO_ERR_EXIT="$EXITCODE" \
TO_ERR_MESSAGE="$ERRMSG" \
TO_ERR_CLASS="$ERRCLASS" \
TO_OS_CLASS="$OSCLASS" \
TO_PKG_MGRS="$MGRS" \
TO_REPORT_OUT="${TMPDIR:-/tmp}/tool-optimizer-report.json" \
  sh "$S"
```

- **Allowlist (what the struct carries):** the failing artifact's *plugin-relative* path, the
  exit code/signal, the tool's own (scrubbed) error message, the error class + a stable
  **fingerprint**, the OS class, the plugin version (read from the plugin manifest), and the
  detected package-manager set.
- **Denylist (synthesized or omitted, never copied):** your triggering path, file contents,
  repo name/remote/org, home dir/username/absolute paths, env-var values, secrets.

Inspect the struct if you like — it is plain JSON. It is the **entire** payload the next step
sends; nothing outside it travels upstream.

## Step 3 — Spawn a BACKGROUND filing subagent with ONLY the struct

Spawn a background subagent and pass it **only the contents of the struct file** from Step 2 —
no transcript, no paths, no code, no environment beyond what the struct already contains. The
subagent's whole job is to file the issue. Its instructions are exactly:

> You are given one JSON struct (below) — a pre-sanitized tool-optimizer defect report. It is
> the only context you have or need. Do not ask for or infer anything else. File exactly ONE
> GitHub issue on the **hardcoded** repository `rodrigorjsf/ast-grep-for-agents` using the
> struct's `title`, and a body built ONLY from the struct's fields. Do not derive the repo
> from any git remote. Then report back the issue URL.

The body the subagent assembles (Markdown) is built field-by-field from the struct, in this
order — a `**Fingerprint:**` line, a facts table, the scrubbed tool message inside a fenced
block, then the labeled synthetic reproduction:

1. `**Fingerprint:** <fingerprint>`
2. A two-column table with rows: Error class = `<errorClass>`, Failing artifact = `<artifact>`,
   Exit code / signal = `<exitCode>`, OS class = `<osClass>`, Plugin version = `<pluginVersion>`,
   Package managers = `<packageManagers>`.
3. A `**Tool's own error (scrubbed):**` heading followed by `<toolMessage>` in a fenced code
   block.
4. The struct's `<syntheticReproduction>` (already labeled "no user paths/code/data").
5. A closing italic line: _Auto-filed by the tool-optimizer report-error skill. Sanitized by
   construction: no user paths, code, data, secrets, or repo name are included._

Every value above comes verbatim from the struct — the subagent introduces no new content, so
nothing outside the allowlisted, already-sanitized struct reaches the issue body.

The `gh` invocation the subagent runs — note the **explicit `--repo`**; the upstream tracker
is hardcoded and is never inferred from the local git remote:

```sh
# Try to apply the triage label, but treat a label failure as NON-FATAL: the issue must
# still be filed even if the label cannot be applied (e.g. the label does not exist upstream).
gh issue create \
  --repo rodrigorjsf/ast-grep-for-agents \
  --title "$TITLE" \
  --body-file "$BODY_FILE" \
  --label needs-triage \
|| gh issue create \
  --repo rodrigorjsf/ast-grep-for-agents \
  --title "$TITLE" \
  --body-file "$BODY_FILE"
```

`$TITLE` is the struct's `title` (it already carries the `[tool-optimizer]` prefix and the
fingerprint). `$BODY_FILE` holds the assembled Markdown body above.

## Step 4 — File exactly ONE issue

This skill files **one** issue per defect and then stops. Do not loop, retry on success, or
file a second issue for the same failure in the same run.

## What this skill deliberately does NOT do

- It does **not** search the upstream tracker for an existing report or deduplicate against a
  prior fingerprint — that is out of scope here. (The fingerprint is emitted so a later step
  *can* dedup; this skill just files.)
- It does **not** install a breadcrumb, a hook on-failure trap, or any local pending-report
  fallback for when `gh` is absent or unauthenticated.

Each of those is a separate concern; keep this skill to the sanitize-and-file spine.
