# Installs are consented and run only through non-privileged channels

The bootstrap is able to install a missing tool, but only after it informs the user,
explains where the agent will use that tool, and gets explicit confirmation. It detects
which package managers are present (brew/npm/pipx/uv/cargo/scoop/winget), maps each tool
to the best **non-privileged** channel for the OS, shows the exact command, and runs it
on confirmation. It **never** auto-runs `sudo` or a `curl … | sh` installer. If the
chosen channel fails, or no eligible channel exists, it prints the manual command (the
`sudo`/`curl` ones included, for the user to run themselves) and continues the bootstrap.

## Considered Options

- **Print-only (never execute)** — rejected: violates the explicit requirement that the
  skill be *able* to install.
- **Fixed channel order with auto-fallthrough** (brew→npm→pip→cargo) — rejected: ignores
  OS-appropriateness (no winget/scoop on Windows) and can pick a slower/worse channel.
- **Auto-install (no per-tool confirm)** — rejected: installs are OS/permission/sandbox
  fragile, and silent installs violate the consent requirement.

## Consequences

- A failed or impossible install never aborts the bootstrap — it degrades to advice and
  the run continues, so a locked-down machine still completes setup.
- `sudo` and `curl | sh` are manual-only by rule. On this repo's WSL2 sandbox both are
  blocked and `.venv` has no pip; the plugin must not assume the user's machine differs,
  so privileged/remote-script channels are surfaced as text, never executed.
- After a successful install the bootstrap re-runs the detection probe to confirm the
  tool now resolves on `PATH` before recording it as available.
- The "where the agent will use this tool" explanation shown at consent time is **sourced
  from the tool→category mapping and the `docs/tools/*` rationale**, not improvised at
  runtime — it is a sourced claim, consistent with the repo's `[verified]`/sourcing
  discipline, not a generated one.
