# The plugin phones home on its OWN defects, and the report is sanitized by construction

When a tool-optimizer **Bootstrap script** is genuinely defective — it crashes or emits clearly
garbage output — the plugin files **exactly one** GitHub issue on its **hardcoded** upstream
tracker, `rodrigorjsf/ast-grep-for-agents`, regardless of which repo the plugin is installed in.
The report is **sanitized by construction**: a single inspectable seam (`sanitize.sh`) builds a
struct from an **allowlist** of facts only (the failing artifact's plugin-relative path, the exit
code/signal, the tool's own scrubbed error message, an error class + a stable fingerprint, the OS
class, the plugin version, the detected package-manager set) and a **labeled synthetic
reproduction**; everything on the **denylist** (triggering user path, file contents, repo
name/remote/org, home dir/username/absolute paths, env-var values, secrets) is synthesized or
omitted. The background filing subagent is handed **only that struct** — never the raw
transcript, paths, or code — so it cannot leak what it was never given. An **expected outcome**
(a documented no-match exit, an expected empty result, a genuinely missing tool degraded around,
or a declined consented install) is **not** a defect and files nothing.

## Considered Options

- **Sanitize-by-construction (chosen):** build the report from an allowlist and synthesize the
  reproduction, then hand the filing subagent only the resulting struct. The privacy guarantee is
  positive ("only these fields can ever appear") and lives in one auditable seam.
- **Scrub-the-transcript (rejected):** capture the raw failure transcript and redact it before
  filing. Rejected as a *blocklist* posture — it is only as good as the last regex, and one
  missed shape (a novel secret format, an unusual absolute path) leaks. A positive allowlist
  cannot leak a field it never copies.
- **Infer the repo from the local git remote (rejected):** this is the plugin's *own* defect
  tracker, not the user's project tracker. Inferring the remote would file the plugin's bugs into
  whatever repo the user happens to be in — wrong destination, and a privacy leak (the remote is
  itself denylisted). The upstream repo is therefore **hardcoded** in both the skill and the
  sanitizer, the deliberate opposite of the project's normal "tracker = this repo" rule.
- **Auto-file with no defect gate (rejected):** reporting every non-zero exit would drown the
  upstream tracker in expected outcomes (ast-grep's no-match exit 1, empty censuses). A defect
  gate in the skill keeps reports to genuine script faults.

## Consequences

- The upstream tracker (`rodrigorjsf/ast-grep-for-agents`) is hardcoded in `report-error/SKILL.md`
  and `sanitize.sh`; it is never derived from a git remote. Filing uses an explicit
  `gh issue create --repo rodrigorjsf/ast-grep-for-agents`.
- The privacy property is **testable**: `sanitize.seam.sh` seeds a user path, a home directory, a
  fake secret, and a repo name, and asserts the emitted struct carries the fingerprint + the
  allowlisted fields + the title prefix + a labeled synthetic reproduction, and **provably none**
  of the seeded denylist strings.
- The `needs-triage` label is applied when possible, but a label failure is **non-fatal**: the
  issue is filed regardless (the label may not exist on the upstream repo).
- The plugin version in the report is read from the single source of truth, the plugin manifest
  (`.claude-plugin/plugin.json`), so a report always names the version that produced the defect.
- This slice is the **tracer-bullet spine**: it files one sanitized issue end to end. It
  deliberately does **not** dedup against an existing upstream fingerprint or add a local
  pending-report fallback for when `gh` is absent — those are separate, later concerns layered
  on top of this spine.
- **Hook on-failure breadcrumb (slice #26).** Hook crashes are harder to surface than Bootstrap
  crashes, so each registered hook (`session-start-policy.sh`, `nudge.sh`) now installs a POSIX
  `EXIT` trap that appends a sanitized `artifact-identity#exit-code` line to
  `.claude/tool-optimizer.breadcrumb` on any unexpected non-zero exit. The `SessionStart` hook
  reads this file at the next session start and, when non-empty, injects a one-line pointer
  directing the agent to invoke `report-error`. The file is gitignored; no paths, no file
  contents, and no network calls run on the hook hot path.
