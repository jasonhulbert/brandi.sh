# brandi.sh

**A cross-harness manager for coding-agent skills and MCP servers — curate your
own once, then *brandish* them in every tool.**

`brandi.sh` (reads as "brandish") moves Agent Skills and MCP servers between
coding-agent harnesses — today **Claude Code** and **Codex** — through one
canonical, vendor-neutral registry. It works in two directions:

- **`ingest`** reads skills and MCP servers out of a harness you already use and
  saves them into your registry in a canonical, harness-neutral form.
- **`install`** renders skillsets from your registry into any harness, rewriting
  paths and conventions for that harness on the way in.

So you can curate a set in one tool and reproduce it in another:

```sh
brandi.sh ingest  --harness claude --skill foo-task,foo-debug --skillset foo-kit
brandi.sh install --harness codex  --skillset foo-kit
```

Under the hood `brandi.sh` is a small, deterministic installer (one canonical
registry + thin per-harness adapters, the shadcn / `ui.sh` model). It only copies
files, substitutes a few placeholders, and normalizes frontmatter keys — **all
judgment lives in the skill markdown, never in shell.**

The tool ships an **engine** (the CLI + adapters). It ships **no content**: the
registry of skillsets and MCP servers is *yours*, lives in your data dir, and is
populated by `ingest` (or by hand).

> **Status — v0.2, implemented and tested end-to-end.** Two honest caveats:
> - The `curl | sh` one-liner needs a published release URL. Until one exists,
>   install from a clone (below) or point the installer at a tarball.
> - `ingest`-ing **MCP servers** needs `python3` (and Python ≥ 3.11 for reading
>   Codex TOML). Skills need no Python.

---

## Contents

- [How it works](#how-it-works)
- [Requirements](#requirements)
- [Quickstart](#quickstart)
- [Installation (bootstrap)](#installation-bootstrap)
- [Commands](#commands)
- [Worked example: move a kit from Claude to Codex](#worked-example-move-a-kit-from-claude-to-codex)
- [What gets created, and where](#what-gets-created-and-where)
- [Verifying your installation](#verifying-your-installation)
- [Authoring the registry by hand](#authoring-the-registry-by-hand)
- [How rendering and ingest work](#how-rendering-and-ingest-work)
- [Harness notes](#harness-notes)
- [Uninstalling](#uninstalling)
- [Repository layout](#repository-layout)
- [Design principles](#design-principles)

---

## How it works

`brandi.sh` separates the **engine** (code) from the **content** (your registry),
and renders through **thin per-harness adapters** that know each harness's
filesystem conventions.

```
        harness A skills/MCP                         harness B skills/MCP
        (e.g. ~/.claude/…)                           (e.g. ~/.codex/…)
                 │                                            ▲
                 │  ingest  (reverse-render,                  │  install / add
                 │           re-tokenize paths)               │  (render, resolve
                 ▼                                            │   placeholders)
        ┌──────────────────────────────────────────────────────────┐
        │  registry/ (canonical, vendor-neutral — YOUR content)     │
        │  skills/<skillset>/…   +   mcp/<server>                    │
        └──────────────────────────────────────────────────────────┘
                 ▲ engine asks the adapter for every harness path ▲
              adapters/claude.sh                        adapters/codex.sh
```

There are **two distinct install steps** — keep them straight:

| Step | Command | What it does |
|---|---|---|
| 1. Bootstrap | `sh install.sh` | Places the `brandi.sh` **engine** (CLI + adapters) on your machine and creates your (empty) registry data dir. |
| 2. Render | `brandi.sh install` | Renders skillsets from your registry into your harnesses. |

`ingest` is how your (otherwise empty) registry gets populated from harnesses you
already use.

---

## Requirements

- A POSIX shell (`/bin/sh`) and standard Unix utilities: `sed`, `awk`, `grep`,
  `find`, `cmp`, `mktemp`, `date`, `sort`, `tr`, `wc`, `tail`, `cp`, `mv`, `mkdir`,
  `rmdir`, `dirname`, `chmod` (the usual coreutils, which ship together).
- A SHA-256 tool — any one of `sha256sum`, `shasum`, or `openssl`.
- `tar` — only for installing from a tarball; `curl` or `wget` — only for the
  remote-tarball install mode.
- `python3` — required for **MCP servers**: the Claude JSON config is merged
  (`install`) and read (`ingest`) with it, and ingesting MCP servers from any
  harness uses it. Reading **Codex** TOML during `ingest --mcp` additionally
  needs Python ≥ 3.11 (`tomllib`). Skill rendering and skill `ingest` need no
  Python; Codex MCP **emit** needs no Python.
- **No `sudo`.** Everything is installed under your home directory by default.

All shell files are POSIX `sh` and pass `shellcheck`.

---

## Quickstart

```sh
git clone <repo-url> brandi.sh
cd brandi.sh

sh install.sh                                          # 1. put the engine on your machine

# 2. populate your registry from a harness you already use
brandi.sh ingest --harness claude --skill my-skill --skillset my-kit

# 3. render it into another harness
brandi.sh install --harness codex --skillset my-kit
brandi.sh doctor                                       # 4. confirm it matches the registry
```

If `brandi.sh` isn't found after step 1, `~/.local/bin` isn't on your `PATH` —
the installer prints the exact `export PATH=...` line to add. (Or run it from the
clone without installing: `sh ./brandi.sh list`.)

---

## Installation (bootstrap)

`install.sh` is the bootstrap. It installs **only the engine** (the CLI + the
adapters) and ensures your registry data dir exists. It is idempotent (safe to
re-run — re-running never overwrites your registry) and never uses `sudo`.

### From a clone (works today)

```sh
git clone <repo-url> brandi.sh && cd brandi.sh
sh install.sh
```

This installs:

- the CLI **launcher** at `~/.local/bin/brandi.sh`,
- the **engine** (a copy of `brandi.sh` + `adapters/`) at `~/.local/share/brandi.sh`,
- and ensures your **data dir** registry at `~/.local/share/brandi.sh/registry/`
  (`skills/` and `mcp/`) exists — without touching anything already there.

By default the engine and your data dir share the directory
`~/.local/share/brandi.sh`, in distinct subpaths: the engine is `brandi.sh` +
`adapters/`; your data is `registry/` + `state` + `backups/`.

### One-liner (`curl | sh`) — once a release is published

```sh
curl -fsSL https://<host>/install.sh | sh
```

When piped with no local source tree, point the installer at a release tarball:

```sh
curl -fsSL https://<host>/install.sh | BRANDI_SH_TARBALL_URL=https://<host>/brandi.sh.tar.gz sh
```

### Bootstrap environment overrides

| Variable | Purpose | Default |
|---|---|---|
| `BIN_DIR` | where the CLI launcher is written | `~/.local/bin` |
| `INSTALL_DIR` | engine location (CLI + `adapters/`) | `$XDG_DATA_HOME/brandi.sh` |
| `BRANDI_SH_DATA` | your data dir (`registry/`, `state`, `backups/`) | `$XDG_DATA_HOME/brandi.sh` |
| `XDG_DATA_HOME` | base for the engine + data defaults | `~/.local/share` |
| `BRANDI_SH_SRC` | install from this local source tree (skips auto-detect) | (auto-detected) |
| `BRANDI_SH_TARBALL` | install from this local `.tar.gz` | — |
| `BRANDI_SH_TARBALL_URL` | download + install from this remote `.tar.gz` | — |

The installer resolves its source in this order: `BRANDI_SH_SRC` → the directory
it was run from (a clone) → `BRANDI_SH_TARBALL` → `BRANDI_SH_TARBALL_URL`. If none
apply, it fails loudly.

---

## Commands

After bootstrapping, the `brandi.sh` CLI populates your registry and renders it
into your harnesses. Run `brandi.sh --help` for the summary, `brandi.sh
--version` for the version.

```
brandi.sh <command> [options]

  install     Render skillset(s) into detected/selected harnesses
  list        Show registry skillsets/skills and where they are installed
  add         Render an additional skillset into targeted harnesses
  sync        Re-render to reconcile installed outputs with the registry
  doctor      Report drift and missing harness dirs (non-zero on problems)
  uninstall   Remove rendered files this tool created; restore backups
  ingest      Reverse-render a harness's skills/MCP into your registry
```

### `brandi.sh ingest --harness <h> --skillset <set> [--skill a,b] [--mcp x,y]`

Reads named skills and/or MCP servers **out of** harness `<h>` and writes them
into your registry, in canonical form, under skillset `<set>`. `--harness` and
`--skillset` are required, and you must give at least one of `--skill` / `--mcp`.

- `--skill <csv>` — copy each skill's file tree from the harness into
  `registry/skills/<set>/<skill>/`, normalize the frontmatter key to `name:`
  (legacy `skill_name:` is handled), and re-tokenize the harness's shared/skills
  absolute paths back into `{{SHARED_DIR}}` / `{{SKILLS_DIR}}` (best-effort;
  anything unrecognized is copied verbatim). The skillset `manifest` is created
  or merged (a `skill:` line is appended if missing).
- `--mcp <csv>` — read each named server from the harness's MCP config
  (Claude `~/.mcp.json`; Codex `~/.codex/config.toml`) and write a neutral
  `registry/mcp/<name>` file, then wire `mcp: <name>` into the skillset manifest.
  Reading the Claude JSON uses `python3`; reading the Codex TOML uses `tomllib`
  (Python ≥ 3.11).

It is **idempotent**: re-ingesting identical content rewrites the same canonical
files and adds no duplicate manifest lines. It fails loud on a missing harness
adapter, a skill directory not present in the harness, an MCP server absent from
the harness config, or a missing parser.

```console
$ brandi.sh ingest --harness claude --skill foo-task --mcp acme --skillset foo-kit
brandi.sh: ingested skill "foo-task" from "claude" -> /home/you/.local/share/brandi.sh/registry/skills/foo-kit/foo-task
brandi.sh: ingested mcp server "acme" from "claude" -> /home/you/.local/share/brandi.sh/registry/mcp/acme
brandi.sh: ingest complete; skillset "foo-kit" registry at /home/you/.local/share/brandi.sh/registry/skills/foo-kit
```

`ingest` only populates the registry; it never installs. Use `install` / `add`
to render into harnesses.

### `brandi.sh install [--harness a,b] [--skillset x,y]`

Renders skillsets into harnesses and records what it wrote.

- `--harness` — comma-separated harness list (`claude`, `codex`). Omit it to
  **auto-detect** installed harnesses.
- `--skillset` — comma-separated skillset list. Omit it to install **every**
  skillset in your registry.

Both flags accept either a space (`--harness claude,codex`) or an equals sign
(`--harness=claude,codex`); the same is true for `uninstall --harness`. An empty
registry fails loud rather than silently doing nothing.

```console
$ brandi.sh install --harness claude,codex --skillset foo-kit
brandi.sh: installed skillset "foo-kit" into harness "claude"
brandi.sh: installed skillset "foo-kit" into harness "codex"
brandi.sh: install complete (2 skillset/harness pair[s]); state: /home/you/.local/share/brandi.sh/state
```

### `brandi.sh list`

Shows each registry skillset, its skills, and which harnesses it is installed
into (read-only). A skillset that isn't installed anywhere shows
`installed into: (none)`.

### `brandi.sh add <skillset>`

Renders one additional skillset into the harnesses you have already installed
into (read from the state file). Requires a prior `install`.

### `brandi.sh sync`

Re-renders every `(harness, skillset)` pair recorded in state to reconcile the
installed files with the current registry — this is how you push registry updates
and repair drift. With nothing installed it is a no-op.

### `brandi.sh doctor`

Checks every installed file against what the registry would render **right now**
and reports problems; useful in CI or before relying on the skills.

- Exit **0** and a clean message when everything matches (or nothing is installed).
- Exit **non-zero** and a list of issues (to stderr) on any drift: a file edited
  since install, a registry change not yet `sync`'d, a missing file, an orphan,
  or a missing harness directory.

```console
$ brandi.sh doctor
brandi.sh: doctor: clean (all installed outputs match the registry)
```

Run `brandi.sh sync` to repair drift, then `brandi.sh doctor` again.

### `brandi.sh uninstall [--harness a,b]`

Removes only the files this tool rendered into harnesses. If a file replaced a
pre-existing ("foreign") file at install time, its backup is restored; otherwise
the file is removed. Empty directories the tool created are cleaned up. Unrelated
skills are never touched. Omit `--harness` to uninstall from every harness in
state. (This does **not** touch your registry — see [Uninstalling](#uninstalling).)

---

## Worked example: move a kit from Claude to Codex

Say you have three skills under `~/.claude/skills/` — `foo-task`, `foo-debug`,
`foo-review` — and an MCP server `acme` in `~/.mcp.json`, and you want them in
Codex too.

```sh
# 1. ingest them into a registry skillset called "foo-kit"
brandi.sh ingest --harness claude \
  --skill foo-task,foo-debug,foo-review \
  --mcp acme \
  --skillset foo-kit

# 2. see what's now in your registry
brandi.sh list
#   foo-kit — ingested skillset foo-kit
#     skills: foo-task, foo-debug, foo-review
#     installed into: (none)

# 3. render the kit into Codex (skills + the acme MCP server)
brandi.sh install --harness codex --skillset foo-kit

# 4. confirm it matches the registry
brandi.sh doctor
```

After step 3, Codex has the three skills (with every `{{SHARED_DIR}}` /
`{{SKILLS_DIR}}` placeholder resolved to Codex's own paths) and an
`[mcp_servers.acme]` table in `~/.codex/config.toml`. The same registry can be
installed into Claude, or any future harness, with no edits.

---

## What gets created, and where

Everything is under your home directory; all paths honor the overrides shown.

| What | Location | Override |
|---|---|---|
| CLI launcher | `~/.local/bin/brandi.sh` | `BIN_DIR` |
| Engine (CLI + `adapters/`) | `~/.local/share/brandi.sh` | `INSTALL_DIR`, `XDG_DATA_HOME` |
| Data dir (`registry/` + `state` + `backups/`) | `~/.local/share/brandi.sh` | `BRANDI_SH_DATA`, `XDG_DATA_HOME` |
| Rendered Claude skills | `~/.claude/skills/<skill>/SKILL.md` | `CLAUDE_SKILLS_DIR` |
| Rendered Codex skills | `<codex skills dir>/<skill>/SKILL.md` | `CODEX_SKILLS_DIR` |
| Shared files (per skillset) | `<skills dir>/<skillset>-shared/` | — |
| Claude MCP config | `~/.mcp.json` | `CLAUDE_MCP_CONFIG` |
| Codex MCP config | `~/.codex/config.toml` | `CODEX_CONFIG` |

The engine and the data dir **coincide by default** (`~/.local/share/brandi.sh`)
but occupy distinct subpaths, so they can also be split with `INSTALL_DIR` /
`BRANDI_SH_DATA`. Your **registry is yours**: the bootstrap creates it but never
overwrites it, and engine-uninstall preserves it (see
[Uninstalling](#uninstalling)).

The **state record** (`~/.local/share/brandi.sh/state`) is a tab-separated file —
one line per rendered file: `harness  skillset  item  rendered-path  sha256`. It
drives `doctor`, `sync`, and `uninstall`. **Backups** of any pre-existing files
that were overwritten are kept under
`~/.local/share/brandi.sh/backups/<UTC-timestamp>/<harness>/…`.

---

## Verifying your installation

The repo ships a full test suite that runs in a throwaway `HOME`:

```sh
sh tests/e2e.sh       # bootstrap + data-safety + render lifecycle
sh tests/ingest.sh    # ingest (skills + MCP) and a cross-harness round-trip
sh tests/mcp.sh       # the MCP emitters against fixtures
# each ends with: == … RESULT: pass=N fail=0 ==
```

To check the shell sources directly:

```sh
sh -n brandi.sh install.sh adapters/*.sh tests/*.sh                  # parse
shellcheck --shell=sh brandi.sh install.sh adapters/*.sh tests/*.sh  # lint (no findings)
```

Manual spot-checks after a real `brandi.sh install`:

```sh
brandi.sh doctor                                 # exit 0
brandi.sh list                                   # shows "installed into: ..."
grep -rl '{{' ~/.claude/skills && echo BAD || echo "no placeholders"  # must say "no placeholders"
```

---

## Authoring the registry by hand

`ingest` is the usual way to populate your registry, but the format is plain text
and you can author it directly. The full contract is in
[`registry/FORMAT.md`](registry/FORMAT.md).

### Add a skill

1. Create `registry/skills/<skillset>/<skill>/SKILL.md` with `---`-fenced
   frontmatter (`name:` and `description:`). Use placeholders instead of
   hard-coded harness paths:
   - `{{SHARED_DIR}}` → the skillset's shared dir for the target harness
   - `{{SKILLS_DIR}}` → the harness's skills root
   - `{{INVOKE:<name>}}` → a reference to another skill (renders to its bare name)
2. Put files shared across the set under `registry/skills/<skillset>/shared/`.
3. Write `registry/skills/<skillset>/manifest` (line-oriented `key: value`):

   ```
   skillset: <skillset>
   description: <one line>
   skill: <skill-dir-name>          # one line per skill
   shared: shared/<file>            # optional, one line per shared file
   mcp: <server-name>               # optional, one line per MCP server
   ```
4. Render it: `brandi.sh install --skillset <skillset>` (or, into already-targeted
   harnesses, `brandi.sh add <skillset>`).

### Add an MCP server

1. Create `registry/mcp/<name>` (line-oriented `key: value`):

   ```
   name: <name>                     # the emitted server key — keep it equal to the filename
   command: npx                     # stdio server …
   arg: -y                          # … one line per argument
   arg: @scope/server
   env: API_KEY=…                   # one line per KEY=VALUE
   # — or, for an HTTP/SSE server, instead of command/arg/env:
   url: https://…
   ```
2. Reference it from a skillset manifest: `mcp: <name>`.
3. On `brandi.sh install` / `add`, it is merged per harness:
   - **Claude** → `~/.mcp.json` under `mcpServers` (override `CLAUDE_MCP_CONFIG`).
     This JSON merge uses `python3`.
   - **Codex** → `~/.codex/config.toml` as `[mcp_servers.<name>]` (override
     `CODEX_CONFIG`). No extra dependency.

   Merges **preserve unrelated** servers/tables and existing top-level keys.

---

## How rendering and ingest work

- **Placeholders** (`{{SHARED_DIR}}`, `{{SKILLS_DIR}}`, `{{INVOKE:<name>}}`) are
  resolved per harness on the way **in** (render), and best-effort re-tokenized
  on the way **out** (ingest). If any `{{…}}` token survives a render, it **fails
  loud** rather than writing a broken file.
- **Frontmatter** is normalized to the canonical `name:` key on ingest (legacy
  `skill_name:` is rewritten once).
- **Idempotent.** Re-rendering a byte-identical file is a no-op; re-ingesting
  identical content rewrites the same bytes and adds no duplicate manifest lines.
- **Backups, never clobber.** Before overwriting a file the tool did *not* create,
  the original is backed up under the data dir; `uninstall` restores it.
- **Drift is defined against the registry.** `doctor` re-renders from the registry
  and compares — catching both files edited after install *and* registry changes
  you haven't `sync`'d.
- **Fail loud.** A missing skillset, unknown harness, unlocatable Codex dir,
  absent MCP server, unresolved placeholder, or missing parser stops with a clear,
  non-zero error. The tool never reports success on partial work.

---

## Harness notes

| Harness | Skills directory | Override | MCP config | MCP override |
|---|---|---|---|---|
| Claude Code | `~/.claude/skills` | `CLAUDE_SKILLS_DIR` | `~/.mcp.json` | `CLAUDE_MCP_CONFIG` |
| Codex | `~/.codex/skills` (`$CODEX_HOME/skills`) | `CODEX_SKILLS_DIR`, `CODEX_HOME` | `~/.codex/config.toml` | `CODEX_CONFIG` |

**Auto-detection** (used by `install` with no `--harness`):

- Claude is detected if `~/.claude` exists (or `CLAUDE_SKILLS_DIR` is set).
- Codex is detected if its skills directory can be located: `CODEX_SKILLS_DIR`,
  `CODEX_HOME` (→ `$CODEX_HOME/skills`), an existing `~/.codex/skills` /
  `~/.config/codex/skills`, or an existing `~/.codex` / `~/.config/codex` base.

**Codex directory.** Codex stores user-level skills at `~/.codex/skills`
(`$CODEX_HOME/skills`; `CODEX_HOME` defaults to `~/.codex`), with project-level
skills in `.codex/skills` ([docs](https://developers.openai.com/codex/skills)).
The adapter resolves that location — honoring `CODEX_SKILLS_DIR` or `CODEX_HOME` —
and **fails loud** if Codex can't be located, rather than guessing or creating a
directory.

---

## Uninstalling

There are two layers, and they are independent:

```sh
# 1. remove rendered skills from your harnesses (restores any backups)
brandi.sh uninstall

# 2. remove the brandi.sh engine + launcher (KEEPS your registry/state/backups)
sh install.sh --uninstall

# …or remove the engine AND your data dir (registry, state, backups):
sh install.sh --uninstall --purge
```

`brandi.sh uninstall` needs the CLI present, so do it first. The bootstrap
uninstall removes the launcher and the engine but **preserves your data dir by
default** — it prints exactly what it kept and how to remove it. Your registry is
only deleted when you explicitly pass `--purge`.

---

## Repository layout

The repo ships the **engine, the format contract, and tests** — and no skillset
or MCP content (that lives in your data dir).

```
brandi.sh      the CLI (install / list / add / sync / doctor / uninstall / ingest)
install.sh     the bootstrap (places the engine; ensures your data-dir registry)
registry/
  FORMAT.md    the contract every skillset / MCP server conforms to
  mcp/         placeholder (.gitkeep) — your MCP servers live in your data dir
adapters/
  claude.sh    Claude Code adapter
  codex.sh     Codex adapter (probes for its skills dir, fails loud)
tests/
  e2e.sh       bootstrap + data-safety + render lifecycle
  ingest.sh    ingest (skills + MCP) round-trip
  mcp.sh       MCP emitter test (runs both emitters against the fixtures)
  fixtures/    test-only MCP server fixtures
plans/         repo-local plans (this repo's own plans)
README.md
```

---

## Design principles

- **Engine vs. content.** The repo ships the engine; your registry is yours,
  user-owned, and never shipped or clobbered by the tool.
- **Canonical registry + thin adapters.** The registry is the single source of
  truth; a harness adapter is a small POSIX-sh file describing only that harness's
  paths and conventions. Supporting a new harness is a new adapter, not an engine
  change.
- **Installer, not a runtime.** `brandi.sh` only copies files, substitutes
  placeholders, and normalizes frontmatter keys. No skill logic lives in shell.
- **Symmetric.** `ingest` is `install` run in reverse; a kit ingested from one
  harness installs cleanly into another.
- **Idempotent, reversible, fail-loud.** Safe to re-run; backs up before
  overwriting; restores on uninstall; preserves your data on engine-uninstall;
  stops on the first real problem instead of silently continuing.

The full machine-readable contract — manifest schema, placeholder grammar,
adapter interface, MCP schema, ingest contract, and on-disk state/layout — is in
[`registry/FORMAT.md`](registry/FORMAT.md).
