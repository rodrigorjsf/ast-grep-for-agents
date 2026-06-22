# Tool-Optimizer Plugin

A Claude Code plugin that, once installed, makes the running agent reach for the
right specialized CLI (or the right standard tool) for each task — spending fewer
tokens and getting better-structured results. It ships a harness (rules, hooks,
skills) plus a bootstrap pass that inspects the machine and the project, records
what is available, and consolidates the agreed configuration with the user.

## Language

**Bootstrap**:
The one-time setup pass that inspects the machine and the project, detects which
tools are present, writes the config, and grills the user to consolidate the fixed
configuration.
_Avoid_: Setup, init, install (those name parts of it, not the whole pass).

**Tool**:
One of the CLIs in the token-first policy (e.g. ripgrep, ast-grep, Repomix, DuckDB).
The standard harness primitives (`Read`/`Grep`/`Glob`) and shell standards
(`grep`/`sed`/`find`) are assumed present and are never the subject of detection.
_Avoid_: Binary, dependency, package.

**Available** / **Missing tool**:
*Available* = resolvable on `PATH` (`command -v` succeeds) with a passing version
probe. *Missing* = not resolvable. Detection is deterministic and reproducible.
_Avoid_: Installed/uninstalled (a tool can be installed yet not on `PATH`).

**Consented install**:
The plugin may install a missing tool, but only after it has informed the user,
explained where the agent will use that tool, and received the user's explicit
confirmation. If an install cannot complete, the plugin reports it and continues
the bootstrap. There is no silent or automatic install.
_Avoid_: Auto-install, unattended install.

**Channel**:
The specific command used to install one Missing tool, chosen from `(tool, installed
managers, OS)` by `pick_channel.sh`. A **non-privileged** channel (`brew`/`npm`/`pipx`/
`uv`/`cargo`/`scoop`/`winget`) is emitted as `RUN` — the bootstrap may execute it on
consent. Anything privileged or remote-script (`sudo apt`, `curl … | sh`, a from-source
build) — and the case where no eligible manager is installed — is emitted as `MANUAL`:
advice the user runs themselves, never auto-run.
_Avoid_: Installer, method (say which: RUN channel vs MANUAL fallback).

**Policy**:
The token-first guidance the agent reads — "pick the tool by the shape of the
task; a non-standard tool must beat the standard one on tokens or capability;
never deny-list a standard tool." Canonical source: `docs/tools/00-overview.md`.
_Avoid_: config (the policy is one part of the config). NB: the Policy is the
*content*; in the Cursor port a **Rule** is the *delivery vehicle* for its static
half — don't conflate them (see **Rule**).

**Scope**:
Where a config lives and which wins. *Global* (`~/.claude/...`) holds the
machine-wide tool inventory + default policy. *Project* (`.claude/...` in the
repo) holds only per-repo overrides. Resolution is key-by-key: the project value
wins when present, otherwise the global value applies (`project[key] ?? global[key]`).
_Avoid_: Local vs remote, workspace.

**Nudge**:
A soft, one-line reminder fired only on narrow triggers (a `Read` of a large file, a
tabular file, or a binary doc) that points the agent at the cheaper specialized tool.
It never repeats for the same path and is tunable/disablable via the `nudge:` setting.
**Harness-dependent blocking:** in **Claude Code** the Nudge is non-blocking by
construction (`PreToolUse` allow + a message-to-agent) — it guides, it is not a deny.
In **Cursor**, where `preToolUse` appears to reach the agent only on the deny path, the
Nudge may degrade to a *one-time soft-deny redirect* (a gate on that first Read) to keep
its actual value — preventing the wasteful read. So "never blocks" is a Claude property,
not a cross-harness invariant (see ADR-0010).
_Avoid_: Veto, hard-block (a Nudge is at most a one-time, redirecting soft-deny — never a
standing block).

**Census**:
The cheap, deterministic snapshot of the project that Relevance is computed from:
bucketed, sorted counts derived from the tracked-file *list* alone (`git ls-files`) —
source by language, tabular files, binary docs, notebooks, build files, repo size, and
monorepo markers. No full-tree walk and no file contents are read. An empty census (no
tracked files) is the *global* (no-codebase) case.
_Avoid_: Scan, crawl, index (those imply reading contents or walking the tree).

**Relevance** (codebase fit):
How useful a Tool is *for the codebase being bootstrapped*, derived from a cheap,
deterministic census of the project (file-type counts, languages, repo size) mapped
onto the tool→category Policy. It is reported honestly for every Tool with its
evidence — e.g. "0 tabular files → DuckDB low relevance here", "1,240 `.java` →
ast-grep high". Relevance *ranks and informs*; it never hides a Tool or gates
detection. A global Bootstrap has no codebase, so its relevance is generic and
labelled as such.
_Avoid_: Score, priority, fitness.

**GEN-core** / **GEN-conditional**:
The two halves of a *global* (no-codebase) Relevance verdict. *GEN-core* tools are
broadly useful in any project (ripgrep, ast-grep, Repomix, files-to-prompt,
universal-ctags, rtk) and are recommended even without a codebase. *GEN-conditional*
tools are gated on a need that can't be seen globally (Semgrep, DuckDB, qsv,
MarkItDown) and are shown but not pushed. The split stops the global advice from
recommending a tool whose own evidence says "only if you handle X".
_Avoid_: Generic (ambiguous — say which half).

**Fixed config**:
A deterministic, user-agreed value consolidated during the bootstrap grilling
(e.g. config path, tool→category mapping, nudge triggers). Non-random and
reproducible across runs.
_Avoid_: Settings, preferences, options.

**Self-report** (phone-home):
The plugin reporting one of *its own* Bootstrap-script defects (a crash or clearly
garbage output) by filing **exactly one** GitHub issue on its **hardcoded** upstream
tracker — `rodrigorjsf/ast-grep-for-agents` — regardless of the repo it is installed
in. It is the deliberate opposite of the project's normal "tracker = this repo" rule:
the destination is the plugin's tracker, never inferred from the user's git remote
(the remote is itself denylisted). An **expected outcome** (a documented no-match exit,
an expected empty result, a genuinely Missing tool degraded around, or a declined
Consented install) is **not** a defect and files nothing.
_Avoid_: Telemetry, analytics, crash-reporting (those imply silent/continuous data
collection; a self-report is one issue, per genuine defect, with no user data).

**Sanitize-by-construction**:
The privacy posture of the Self-report: the report struct is **built from an allowlist
of facts only** (the failing artifact's plugin-relative path, exit code/signal, the
tool's own scrubbed error message, an error class + fingerprint, OS class, plugin
version, detected package-manager set) plus a **labeled synthetic reproduction** — and
the background filing subagent is handed **only that struct**. Everything on the
**denylist** (triggering user path, file contents, repo name/remote/org,
home dir/username/absolute paths, env-var values, secrets) is synthesized or omitted,
never copied. A positive allowlist cannot leak a field it never copies — the opposite
of scrubbing a raw transcript, which is only as good as the last redaction regex.
_Avoid_: Redact, scrub, anonymize (those name a blocklist pass over raw data; construction
means the raw data never enters the struct in the first place).

## Multi-harness

**Harness**:
A host agent runtime the plugin targets — currently **Claude Code** and **Cursor**.
The same capabilities are re-derived per harness using that harness's native
primitives, not mirrored mechanism-for-mechanism. A plugin **artifact** is then
either *harness-agnostic* (pure shell over stdin/data — single-sourced and synced
into each plugin) or *harness-coupled* (forked per harness: the manifest, the
hook config + hook scripts, and the Rule).
_Avoid_: Platform, host, IDE, editor (say Harness; a harness is the agent runtime,
not the editor chrome around it).

**Rule** (Cursor):
A Cursor-native standing-context artifact — a `.mdc` file with `alwaysApply: true` —
that carries the *static* half of the **Policy** in the Cursor port. Claude Code has
no Rule primitive, which is why there it delivers the same Policy by a `SessionStart`
hook instead. A Rule is the vehicle; the Policy is the content it carries.
_Avoid_: Policy (the content, not the vehicle), guideline, instruction.
