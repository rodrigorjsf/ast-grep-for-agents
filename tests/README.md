# `tests/` — seam tests, kept out of the installed plugin

These are the `*.seam.sh` tests for the `tool-optimizer` plugin. They live **here**, at the
repo root, **not** under `tool-optimizer/` — on purpose.

## Why they are not inside the plugin

Claude Code installs a plugin by **git-cloning its directory verbatim** into
`~/.claude/plugins/cache/…`. There is **no** manifest field to include/exclude files
(`plugin.json` has no `files`/`exclude`/`ignore`), and `.gitattributes export-ignore` is
honored only by `git archive`, never by `git clone`. So any file under `tool-optimizer/`
— including every `*.seam.sh` — would be copied onto **every user's machine** at install.

Moving the seams out of `tool-optimizer/` keeps them in the repo (and in the test gate)
while leaving the installed plugin footprint to **real runtime scripts only**.

> **Do not move a `*.seam.sh` back under `tool-optimizer/`.** It would ship to users.
> A new test goes here, mirroring the plugin path of the script it covers.

## Layout

The tree mirrors the plugin exactly: a seam for `tool-optimizer/<path>/<name>.sh` lives at
`tests/tool-optimizer/<path>/<name>.seam.sh`.

## How a seam finds the script it tests

The **real scripts are not moved** — only the seams are. Each seam resolves the plugin
directory by mapping its own location back:

```sh
SCRIPT_DIR="$(CDPATH= cd -- "$(dirname "$0")" && pwd)"
SCRIPT_DIR="$(printf '%s' "$SCRIPT_DIR" | sed 's#/tests/tool-optimizer/#/tool-optimizer/#')"
```

`$SCRIPT_DIR` then points at the real script's directory, so every existing
`"$SCRIPT_DIR/<name>.sh"` reference resolves unchanged. Because the scripts stay put, their
own internal relative paths (e.g. to `.claude-plugin/plugin.json`) remain valid.

## Running them

```sh
# all seams
find tests -name '*.seam.sh' -exec sh {} \;
```

The repo's test gate (`.orchestrate/commands.json`) discovers them automatically: it globs
the whole repo for `*seam*`/`*test*`/`*/tests/*` `.sh` files, so the relocation needed no
gate change.
