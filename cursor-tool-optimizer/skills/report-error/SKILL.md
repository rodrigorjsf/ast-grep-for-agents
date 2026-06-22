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

## Step 2a — gh-availability gate: file or pend (main thread)

Before spawning the filing subagent, run the gh-availability gate. If `gh` is missing **or**
unauthenticated, append the already-sanitized struct to the local pending-reports file and
**stop** — do not spawn the subagent. This is the lossless fallback for machines without a
usable GitHub CLI.

```sh
S="${CLAUDE_PLUGIN_ROOT}/skills/report-error/scripts/file-or-pend.sh"
TOKEN=$(
  TO_FOP_STRUCT="$(cat "${TMPDIR:-/tmp}/tool-optimizer-report.json")" \
    sh "$S"
)
```

`$TOKEN` is either `"gh-available"` or `"pended"` (the script always exits 0 — lossless).

- **`pended`** — `gh` is missing or unauthenticated. The sanitized struct has been appended
  (compact JSONL, one struct per line) to `.claude/tool-optimizer.pending-reports.jsonl`
  (relative to the repo root where the skill runs). **Stop here.** Do not proceed to Step 3.
  The pending file is gitignored; a human or a future gh-available session files the reports
  manually. **No auto-flush is implemented — this skill never reads the pending file back.**
- **`gh-available`** — `gh` is present and authenticated. Proceed to Step 3 as normal.

The pending path is overridable via `TO_FOP_PEND` (see `file-or-pend.sh`). The seam
`file-or-pend.seam.sh` proves AC1–AC3: the appended struct is sanitized (no denylist
strings), the pending path and the filing path are mutually exclusive, and the fallback
always exits 0.

## Step 3 — Spawn a BACKGROUND dedup+filing subagent with ONLY the struct

Spawn a background subagent and pass it **only the contents of the struct file** from Step 2 —
no transcript, no paths, no code, no environment beyond what the struct already contains. The
subagent's whole job is to search for an existing open issue and then either file, comment, or
silently stop. Its instructions are exactly:

> You are given one JSON struct (below) — a pre-sanitized tool-optimizer defect report. It is
> the only context you have or need. Do not ask for or infer anything else. Follow the exact
> dedup search → branch logic in Steps 3a–3c, using the **hardcoded** repository
> `rodrigorjsf/ast-grep-for-agents`. Do not derive the repo from any git remote.

### Step 3a — Search FIRST (dedup search precedes both create and comment)

Before creating an issue or adding a comment, search the upstream tracker for an **open** issue
whose title contains the same `fp:<fingerprint>` marker. The fingerprint is the struct's
`fingerprint` field.

```sh
FP="<fingerprint>"          # from the struct

# GitHub search tokenizes on punctuation, so post-filter for an exact substring match.
MATCH_NUMBER=$(
  gh issue list \
    --repo rodrigorjsf/ast-grep-for-agents \
    --state open \
    --search "fp:${FP} in:title" \
    --json number,title \
    --jq ".[] | select(.title | contains(\"fp:${FP}\")) | .number" \
  | head -1
)
```

`MATCH_NUMBER` is the issue number of the first open issue whose title contains `fp:<fingerprint>`
exactly. If the `gh issue list` command itself fails (e.g. network error), treat it as no-match
and proceed to Step 3c (create).

> **Dedup is best-effort, not airtight.** GitHub search indexing lags by seconds, and the
> `fp:` marker tokenizes imperfectly on punctuation. Rapid double-fires can still occasionally
> create a duplicate. The post-filter on the exact substring reduces this, but does not
> eliminate it. Document this honestly rather than presenting dedup as a guarantee.

### Step 3b — No match → create the issue (same as before)

If `MATCH_NUMBER` is empty, proceed to create the issue. Build the body from the struct
field-by-field (no raw context):

1. `**Fingerprint:** <fingerprint>`
2. A two-column table with rows: Error class = `<errorClass>`, Failing artifact = `<artifact>`,
   Exit code / signal = `<exitCode>`, OS class = `<osClass>`, Plugin version = `<pluginVersion>`,
   Package managers = `<packageManagers>`.
3. A `**Tool's own error (scrubbed):**` heading followed by `<toolMessage>` in a fenced code
   block.
4. The struct's `<syntheticReproduction>` (already labeled "no user paths/code/data").
5. A closing italic line: _Auto-filed by the tool-optimizer report-error skill. Sanitized by
   construction: no user paths, code, data, secrets, or repo name are included._

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

### Step 3c — Match found → compare context, then decide

If `MATCH_NUMBER` is non-empty, fetch the existing issue's body to compare its context fields
against the new struct's fields:

```sh
EXISTING_BODY=$(gh issue view "$MATCH_NUMBER" \
  --repo rodrigorjsf/ast-grep-for-agents \
  --json body --jq '.body')
```

Extract the existing context from the body table. A **meaningfully different context** is
defined as: the new struct has a different `osClass`, `pluginVersion`, or `packageManagers`
than what appears in the existing issue's facts table. These are the only three context fields
that carry new investigative value across recurrences.

**Same context** (osClass, pluginVersion, and packageManagers all match the existing issue):

> File nothing. Add no comment. Stop. This is the dedup hit: the same defect in the same
> environment was already reported. Silently return the existing issue URL.

**Meaningfully different context** (at least one of the three fields differs):

> Add ONE sanitized comment to the existing issue. Build the comment body using
> `render-comment.sh` with **only the sanitized struct** (the same trust boundary as the issue
> body):

```sh
S="${CLAUDE_PLUGIN_ROOT}/skills/report-error/scripts/render-comment.sh"
TO_COMMENT_STRUCT="$(cat "${TMPDIR:-/tmp}/tool-optimizer-report.json")" \
TO_COMMENT_OUT="${TMPDIR:-/tmp}/tool-optimizer-comment.md" \
  sh "$S"

gh issue comment "$MATCH_NUMBER" \
  --repo rodrigorjsf/ast-grep-for-agents \
  --body-file "${TMPDIR:-/tmp}/tool-optimizer-comment.md"
```

The comment body is rendered entirely from the already-sanitized struct. No raw context,
no user paths, no transcript content ever reaches the comment. `render-comment.sh` is the
inspectable seam where this guarantee lives; `render-comment.seam.sh` proves it.

## Step 4 — File or comment exactly ONCE

This skill produces **at most one action** per run — either one new issue (Step 3b), or one
comment on an existing issue (Step 3c, different-context branch), or nothing (Step 3c,
same-context branch). Do not loop, retry on success, or take more than one action for the
same failure in the same run.

## What this skill deliberately does NOT do

- It does **not** auto-flush the pending-reports file. Reports that accumulate in
  `.claude/tool-optimizer.pending-reports.jsonl` stay there until a human or a future
  gh-available session files them manually. Reading the pending file back, batching its
  entries, or triggering any network call to drain it is **explicitly out of scope**
  for this skill.
- It does **not** install a hook on-failure breadcrumb or EXIT trap — that is the
  `#26` breadcrumb mechanism, which is a separate, already-merged concern.
