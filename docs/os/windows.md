# ast-grep on Windows

> Part of the ast-grep learning book — see [INDEX](../INDEX.md). ↑ Up: [02 · CLI & Rules](../02-cli-and-rules.md)

This is a **delta page**. The canonical OS chapter is [Linux](linux.md) — it explains
the things that are the same everywhere (what the binary is, how custom languages are
registered, what `AST_GREP_CONFIG` does, why patterns need quoting at all). Read that
first. This page covers only the handful of things that are genuinely different on
Windows, and the one that actually bites: **pattern quoting changes per shell**.

> **Not reproduced on Windows.** Every `[verified]` fact in this book was run on this
> machine — WSL2, x86_64, `ast-grep 0.42.3`. **No command in this chapter was executed
> on a real Windows host.** So nothing here is marked `[verified]`: claims are either
> `[sourced]` (confirmed in official docs/registries this session, URL given) or
> `[sourced — unverified]` (could not confirm). Treat the snippets as documented
> recipes to try, not captured output.

## What actually differs from Linux

| Concern | Linux ([linux.md](linux.md)) | Windows | Label |
| --- | --- | --- | --- |
| Install route | nix / mise / cargo / npm / pip | **`scoop install main/ast-grep`** (also npm / pip / cargo) | [sourced] |
| `sg` name collision | `sg` = `setgroups`, never use it | **no `setgroups`** — `sg` is normally free | [sourced — unverified] |
| Grammar library ext. | `.so` | **`.dll`** | [sourced] |
| Pattern quoting | single quotes `'…'` | **PowerShell → `'…'`; cmd.exe → `"…"`** | [sourced] |
| Config env var | `export AST_GREP_CONFIG=…` | **`$env:…`** (PS) / **`set …`** (cmd) | [sourced] |

Everything else — flags, subcommands, exit codes, meta-variables, rule YAML, the fact
that all 32 grammars are baked into the binary so **no JDK / Python / Go is needed** to
analyze Java, Python, or Go — is identical to Linux. This page does not repeat it.

---

## 1. Install

The Windows-native route is [Scoop](https://scoop.sh). ast-grep lives in Scoop's
default **main** bucket, so one command installs it:

```powershell
scoop install main/ast-grep
```

[sourced — the `ast-grep.json` manifest exists in the Scoop main bucket:
https://github.com/ScoopInstaller/Main/blob/master/bucket/ast-grep.json ;
homepage https://ast-grep.github.io]

> Scoop installs the **latest** version from the main bucket (at the time of writing the
> manifest tracks `0.43.0`, slightly ahead of the `0.42.3` this book targets). The CLI
> surface this book teaches is unchanged; just expect `ast-grep --version` to print a
> version at or above `0.42.3` [sourced — manifest version, same URL].

The three cross-platform routes from the [Linux page](linux.md#1-installing-on-linux)
also work unchanged on Windows:

```powershell
npm  i @ast-grep/cli -g       # Node projects
pip  install ast-grep-cli     # Python projects / venv
cargo install ast-grep --locked   # build from a Rust toolchain
```

[sourced — https://ast-grep.github.io/guide/quick-start.html]

Confirm the binary before trusting any result. The version-check command is the same on
every OS:

```powershell
ast-grep --version
# expect: ast-grep 0.42.3  (or newer)
```

If that prints a version you are ready. If you get *command not found*, Scoop's shims
directory (`~\scoop\shims`) — or the npm / cargo install dir — is not on `PATH`; fix the
`PATH`, do not reinstall.

---

## 2. No `sg` collision — but still type `ast-grep`

On Linux, `sg` is the `setgroups` system utility, so a bare `sg` runs the wrong tool
(see [linux.md §2](linux.md#2-the-sg-trap-why-you-always-type-ast-grep)). **Windows ships
no `setgroups`**, so the short `sg` alias ast-grep's own docs sometimes use is normally
*free* to point at ast-grep [sourced — unverified: the absence of `sg` on a default
Windows `PATH` was not tested on a Windows host this session].

Even so, **this book always invokes the full `ast-grep`** for portability — the same
command then copy-pastes into Linux, WSL, CI, and agent prompts without surprises. Type
`ast-grep`; don't lean on `sg`.

---

## 3. Grammar libraries use `.dll`

You rarely need this — the 32 built-in languages (Java, Python, Go included) are already
compiled into the binary. But a **custom language** registers a pre-compiled Tree-sitter
grammar as a dynamic library, and on Windows that file ends in **`.dll`** (it is `.so` on
Linux, `.dylib` on macOS) [sourced]. The registration shape under `customLanguages` is
otherwise identical to the [Linux example](linux.md#3-grammar-libraries-use-the-so-extension)
— only the extension changes:

```yaml
# sgconfig.yml — custom language registration (Windows)
customLanguages:
  mylang:
    libraryPath: ./grammars/mylang.dll   # .dll on Windows (.so Linux, .dylib macOS)
    extensions: [ml]
    expandoChar: _
```

---

## 4. Pattern quoting: it depends on the shell

This is the real reason a Windows-specific page exists. ast-grep patterns are full of
`$`-prefixed meta-variables (`$VAR`, `$$$ARGS`, `$_`). Whether those survive the trip
from your keyboard to ast-grep depends on **which shell you typed them in** — and Windows
has two common ones that behave *oppositely*.

```mermaid
flowchart TD
  P["You write -p '…$$$A…'"] e1@--> S{"Which shell?"}
  S -->|"PowerShell"| PS["Use SINGLE quotes 'pattern'<br/>double quotes expand $ (like bash)"]
  S -->|"cmd.exe"| CMD["Use DOUBLE quotes \"pattern\"<br/>single quotes are literal chars here!"]
  PS e2@--> OK["✓ $$$A reaches ast-grep intact"]
  CMD e3@--> OK
  classDef start fill:#1e3a5f,stroke:#4a90d9,color:#fff;
  classDef good fill:#1f4d2e,stroke:#46b06b,color:#fff;
  classDef warn fill:#5f4a1f,stroke:#d9a64a,color:#fff;
  class P,S start;
  class PS,CMD warn;
  class OK good;
  e1@{ animate: true }
  e2@{ animate: true }
  e3@{ animate: true }
```

### PowerShell — single quotes (just like bash)

PowerShell expands `$` inside **double** quotes — `"$$$A"` gets rewritten before ast-grep
sees it, exactly the bash failure mode from [linux.md §4](linux.md#4-pattern-quoting-single-quotes-always).
So in PowerShell, use **single** quotes, which are fully literal:

```powershell
# RIGHT — PowerShell: single quotes are literal, $$$A survives
ast-grep run -p 'print($$$A)' -l python
```

If you are coming from bash, this rule is identical — good news, your muscle memory
transfers. [sourced — PowerShell quoting semantics:
https://learn.microsoft.com/en-us/powershell/module/microsoft.powershell.core/about/about_quoting_rules]

### cmd.exe — double quotes (the gotcha)

cmd.exe is the trap, because the bash/PowerShell habit *backfires*. **In cmd.exe, single
quotes are not string delimiters at all** — they are ordinary characters. Paste
`-p 'print($$$A)'` into cmd and the quote marks get baked *into* the pattern, so ast-grep
searches for a literal `'print(...)'` and finds nothing.

Use **double** quotes in cmd. And here is the saving grace: cmd does **not** expand `$` —
it uses `%VAR%` for variables — so `$$$A` is completely inert inside `"…"`:

```bat
:: RIGHT — cmd.exe: double quotes delimit; $ is inert here (cmd uses %VAR%)
ast-grep run -p "print($$$A)" -l python
```

[sourced — cmd.exe quoting / `%VAR%` expansion:
https://learn.microsoft.com/en-us/windows-server/administration/windows-commands/set_1]

| Shell | Wrap patterns in | Why |
| --- | --- | --- |
| **PowerShell** | single quotes `'…'` | double quotes expand `$` (same as bash) |
| **cmd.exe** | double quotes `"…"` | single quotes aren't delimiters in cmd; `$` is inert inside `"…"` |

> **The one cmd-only char to watch is `%`, not `$`.** Because cmd expands `%VAR%`, a
> literal `%` inside a pattern must be doubled to `%%`. You almost never hit this with
> ast-grep meta-variable patterns, but it is the cmd analogue of the `$`-escaping problem
> [sourced — same Microsoft `set` reference].

---

## 5. Pointing ast-grep at your config

The behavior is the same as everywhere — ast-grep auto-discovers `sgconfig.yml` by
walking *up* from the current directory, and both `--config` and the `AST_GREP_CONFIG`
environment variable override that (`--config` wins). See
[linux.md §6](linux.md#6-pointing-ast-grep-at-your-config-ast_grep_config) for the full
story. Only the **shell syntax** for setting the env var differs on Windows:

```powershell
# PowerShell — note the $env: prefix and the = with spaces is fine
$env:AST_GREP_CONFIG = "C:\path\to\sgconfig.yml"
ast-grep scan
```

```bat
:: cmd.exe — note: NO spaces around the = , and no quotes needed
set AST_GREP_CONFIG=C:\path\to\sgconfig.yml
ast-grep scan
```

[sourced — `AST_GREP_CONFIG` override behavior:
https://ast-grep.github.io/guide/project/project-config.html ; PowerShell `$env:` and
cmd `set` syntax: standard Windows shell conventions]

The `set` trap in cmd is easy to miss: `set AST_GREP_CONFIG = C:\...` (with spaces)
creates a variable whose name has a trailing space and whose value has a leading space —
silently wrong. Keep it tight: `set NAME=value`.

The per-invocation flag is identical on every OS and sidesteps both quoting regimes:

```powershell
ast-grep scan --config C:\path\to\sgconfig.yml
```

---

## Windows cheat-sheet

| Goal | Do this | Label |
| --- | --- | --- |
| Install (native) | `scoop install main/ast-grep` | [sourced] |
| Install (cross-platform) | `npm i @ast-grep/cli -g` · `pip install ast-grep-cli` · `cargo install ast-grep --locked` | [sourced] |
| Confirm install | `ast-grep --version` → `0.42.3` or newer | [sourced] |
| `sg` short name | normally free (no `setgroups`), but still type `ast-grep` | [sourced — unverified] |
| Custom grammar | `libraryPath: ….dll` in `sgconfig.yml` | [sourced] |
| Pattern in PowerShell | single quotes `-p '…$VAR…'` | [sourced] |
| Pattern in cmd.exe | double quotes `-p "…$VAR…"` | [sourced] |
| Config env var (PS) | `$env:AST_GREP_CONFIG = "C:\…\sgconfig.yml"` | [sourced] |
| Config env var (cmd) | `set AST_GREP_CONFIG=C:\…\sgconfig.yml` (no spaces) | [sourced] |

**Rules of thumb for Windows**

- Install with **Scoop** (`scoop install main/ast-grep`); npm / pip / cargo also work.
- **PowerShell → single quotes**, **cmd.exe → double quotes**. They are opposite.
- In cmd, single quotes are literal characters, not delimiters — that is the #1 gotcha.
- cmd's `set` takes **no spaces** around `=`; the inert pattern char to escape is `%`, not `$`.
- Custom-grammar files end in `.dll` here (`.so` Linux, `.dylib` macOS).
- For everything else, the [Linux page](linux.md) is the source of truth.

---

## See also

- **[Linux](linux.md)** — the canonical OS chapter; read it for everything this delta
  does not repeat.
- **[WSL](wsl.md)** — run real Linux ast-grep *inside* Windows; the alternative to a
  native Windows install when you want the Linux behavior end-to-end.
- **[macOS](macos.md)** — sibling delta: grammar libs are `.dylib`.
- **Official docs** —
  [quick-start](https://ast-grep.github.io/guide/quick-start.html) ·
  [project config](https://ast-grep.github.io/guide/project/project-config.html) ·
  [Scoop manifest](https://github.com/ScoopInstaller/Main/blob/master/bucket/ast-grep.json).

---
[← Previous: macOS](macos.md) · [Next: Decision Policy](../harnesses/00-decision-policy.md)
