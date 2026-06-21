---
name: bootstrap
description: >-
  Bootstrap the local agent tool shelf — detect which of the 10 core tools are
  installed, rank each by relevance to THIS codebase, then present every missing
  tool (ranked) with where the agent would use it and offer a consented,
  non-privileged install. Use when the user wants to set up / bootstrap / install
  the tool-optimizer tools, "install missing tools", or "check my tool shelf".
---

# Bootstrap the tool shelf (present → consent → install)

Turns the ranked tool inventory into action: for each **Missing** tool,
ordered by Relevance, show *where the agent would use it*, ask the user, and — only on
explicit confirmation — run the best **non-privileged** install channel for the OS,
then re-probe. A failed or impossible install degrades to advice and the bootstrap
continues. `sudo` and `curl … | sh` are **never** run automatically; they are shown as
text for the user to run themselves.

This flow is **HITL**: the install mutates the machine and consent must be driven by a
human. Only `pick_channel.sh` is harness-verified (`pick_channel.seam.sh`); the
present / consent / install / re-probe loop below is not harness-verifiable.

## Step 1 — Build the ranked inventory

Run the three batch scripts in order; each is deterministic and injectable. Default
output is `.claude/tool-optimizer.local.json` (override with `TO_OUTPUT`/`TO_RANK_OUT`).

```sh
D="${CLAUDE_PLUGIN_ROOT}/skills/bootstrap/scripts"   # install-safe; the scripts ship with the plugin
sh "$D/detect.sh"      # probe the 10 tools -> inventory JSON (available/version/path/category)
sh "$D/rank.sh"        # runs census.sh itself, then adds census + relevance + recommendOrder, in place
```

`rank.sh` runs `census.sh` internally (override with `TO_CENSUS=<file>` only if you want a
fixed census). After this, the inventory has `relevance` (a verdict for **every** tool —
none omitted) and `recommendOrder` (the Missing+recommended set, already ranked).

## Step 2 — Detect package managers and OS

```sh
mgrs=""; for m in brew npm pipx uv cargo scoop winget; do command -v "$m" >/dev/null 2>&1 && mgrs="$mgrs,$m"; done; mgrs="${mgrs#,}"
case "$(uname -s)" in Darwin) os=macos;; Linux) grep -qi microsoft /proc/version 2>/dev/null && os=wsl || os=linux;; *) os=windows;; esac
```

`pick_channel.sh` only recognises this manager set; `pip` / `sudo apt` / `curl|sh` are
deliberately not in it (they are manual-only).

## Step 3 — Present EVERY Missing tool, ranked (never hide one)

Relevance ranks and informs; it never hides a tool. So present the full
Missing set, in two tiers:

1. **Recommended (push):** the tools in `recommendOrder` (already ranked HIGH→MED→GEN).
2. **Show, don't push:** the remaining `relevance[]` entries with `available == false`
   (LOW / NA / GEN-conditional). List them so the user can still opt in, but do not
   nudge them.

For each tool show three things:
- its **Relevance** + the codebase **evidence** (`relevance[].evidence`, e.g. "60 java →
  structural search pays off" — this is sourced from the census, not improvised);
- the **sourced "where the agent uses it"** line from the table below — quote it
  verbatim, do not paraphrase or invent a new rationale;
- the install channel from Step 4.

### Where the agent uses it

This table is the plugin's canonical per-tool rationale — each line is one tool's role on
the shelf. Quote it **verbatim** at consent time; do not paraphrase or invent a new reason.

| Tool | Where the agent uses it |
|---|---|
| ripgrep | Fast literal / regex / identifier search across the tree — the baseline text-search incumbent. |
| ast-grep | Syntax-aware structural search **and rewrite** in one language — the spine of the shelf. |
| semgrep | The one thing ast-grep can't: taint / dataflow security analysis + a CWE rule registry. |
| repomix | Compact, structured whole-repo context — map + summary + contents with token counts. |
| files-to-prompt | Light, path-aware packing of an explicit file **subset** (`--cxml` for Claude). |
| markitdown | Office / web docs (docx/pptx/xlsx/html) → Markdown with pipe tables (the formats a PDF extractor doesn't cover). |
| duckdb | SQL over CSV / Parquet / Excel **without loading** the file — the SUM/JOIN/window engine. |
| qsv | Sub-second CSV stats / count / slice / frequency. |
| universal-ctags | Persistent symbol index — "where is X defined?" becomes a lookup, not a re-scan. |
| rtk | Per-command output compression — environment-level, useful in any project. |

## Step 4 — Pick the channel and get explicit consent

For each Missing tool, ask `pick_channel.sh` for the install command:

```sh
sh "$D/pick_channel.sh" <tool> "$mgrs" "$os"
```

It prints one TAB-separated line:
- `RUN<TAB><command>` — a **non-privileged** command the bootstrap may run.
- `MANUAL<TAB><command>` — advice only (covers the `sudo` / `curl|sh` / from-source / no-
  eligible-manager cases). **Never run a MANUAL line.** Show it for the user to run.

Consent rule: **nothing is installed without an explicit, per-tool
confirmation.** Ask the user — e.g. via `AskUserQuestion` — to approve the exact `RUN`
command before executing it. No blanket "install all"; no silent install. If the user
declines, skip to the next tool.

## Step 5 — Install on consent, then re-probe; degrade on failure

On a confirmed `RUN` command, execute it, then re-probe the tool's **binary** with
`command -v` (the binary name differs from the tool name for two tools):

| Tool | Binary | | Tool | Binary |
|---|---|---|---|---|
| ripgrep | `rg` | | universal-ctags | `ctags` |

All other tools' binary == their name (`ast-grep`, `semgrep`, `repomix`,
`files-to-prompt`, `markitdown`, `duckdb`, `qsv`, `rtk`).

```sh
command -v <binary> >/dev/null 2>&1 && echo "Available" || echo "still Missing — advice only"
```

- Record the tool **Available only if `command -v <binary>` now succeeds** on `PATH`.
- Do **not** re-run `detect.sh` mid-loop — it overwrites the whole inventory and drops the
  `census`/`relevance`/`recommendOrder` block you are iterating. Use `command -v`.
- If the install fails, or `pick_channel` returned `MANUAL`, print the manual command as
  advice and **continue** the bootstrap — one locked-down tool never aborts the run.

After the loop, you may re-run Step 1 once to refresh the persisted inventory with the
newly-installed tools.

## Acceptance recap (issue #7)

- Missing tools presented ranked, each with a sourced "where used" line — Steps 3–4.
- No install without explicit confirmation — Step 4.
- Chosen channel is non-privileged; `sudo` / `curl|sh` shown as text only — `pick_channel.sh`.
- Failed/impossible install → advice, bootstrap continues — Step 5.
- After success, re-probe; Available only if it resolves on `PATH` — Step 5.
- `pick_channel` seam passes — `pick_channel.seam.sh` (the harness-verified piece).
