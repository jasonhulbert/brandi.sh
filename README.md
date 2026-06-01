# plan.sh

**A cross-provider planning system for coding agents — research, create, and
execute multi-step plans, the same way in every tool.**

`plan.sh` installs and keeps in sync the skills (and, over time, MCP servers)
that make up a structured planning workflow: turn a goal into a durable, phased
plan, then execute it phase by phase with verification between steps. It delivers
that workflow into multiple coding-agent harnesses — today **Claude Code** and
**Codex** — from one canonical source, so the planning system behaves the same
no matter which tool you are in.

Under the hood, `plan.sh` is a small, vendor-neutral installer (one canonical
registry + thin per-harness adapters, the shadcn / `ui.sh` model). That
architecture is what lets a single planning system span providers and grow — but
the product *is* the planning system, not a generic skill manager. The installer
only copies files and substitutes a few placeholders; all judgment lives in the
skill markdown, never in shell.

> **Status — v1, implemented and tested end-to-end.** The bundled planning
> system is the `plan` skillset (6 skills, described below); it ships with zero
> MCP servers (the MCP extension point is built and exercised by `tests/mcp.sh`
> against test-only fixtures). Two honest caveats:
> - The Codex skills directory location is not officially confirmed, so the
>   Codex adapter **probes** for it and **fails loud** if it can't be found
>   (set `CODEX_SKILLS_DIR` to be explicit). It never guesses.
> - The `curl | sh` one-liner needs a published release URL. Until one exists,
>   install from a clone (below) or point the installer at a tarball.

---

## Contents

- [The planning system](#the-planning-system)
- [How it works](#how-it-works)
- [Requirements](#requirements)
- [Quickstart](#quickstart)
- [Installation (bootstrap)](#installation-bootstrap)
- [Commands](#commands)
- [What gets created, and where](#what-gets-created-and-where)
- [Verifying your installation](#verifying-your-installation)
- [Extending the registry](#extending-the-registry)
- [How rendering works](#how-rendering-works)
- [Harness notes](#harness-notes)
- [Uninstalling](#uninstalling)
- [Repository layout](#repository-layout)
- [Design principles](#design-principles)

---

## The planning system

The point of `plan.sh` is the workflow it installs. The bundled `plan` skillset
turns "do this multi-step change" into a tracked, resumable plan that an agent
can execute and verify, phase by phase. The skills hand off to one another:

| Skill | Role in the workflow |
|---|---|
| `plan-create` | Turn a goal into a durable, phased plan saved to a file. |
| `plan-phase` | Execute one phase — inspect, change, validate — then hand off to reflect. |
| `plan-reflect` | Verify a finished phase against the actual repo and update the plan before the next one. |
| `plan-auto` | Run all remaining phases unattended (`plan-phase` + `plan-reflect` per phase) until done or blocked. |
| `plan-multi` | Break work too big for one plan into coordinated child plans. |
| `plan-task` | Do a small, well-scoped change in a single pass (no durable plan). |

Together they cover the **create → execute → verify** loop for plans of any size.
`plan.sh`'s job is to keep these skills — and, as the system grows, research
skills and MCP servers — installed and in sync across every coding agent you use,
so the workflow is identical whether you are in Claude Code or Codex.

> v1 bundles the create/execute/verify lifecycle above. Research skills and MCP
> servers are part of the system's intended scope; they slot into the same
> registry with no engine change (see [Extending the registry](#extending-the-registry)).

## How it works

`plan.sh` delivers the planning system into each harness from one source, using
the shadcn / `ui.sh` model: **one canonical registry** of vendor-neutral sources
plus **thin per-harness adapters** that render copies into each harness's own
conventions.

```
                         ┌─────────────────────────┐
                         │  registry/ (canonical)  │
                         │  skills/  +  mcp/        │
                         └────────────┬────────────┘
                                      │  render (substitute placeholders)
                  ┌───────────────────┼───────────────────┐
                  ▼                                       ▼
        adapters/claude.sh                       adapters/codex.sh
                  │                                       │
                  ▼                                       ▼
        ~/.claude/skills/…                       ~/.codex/skills/…
```

There are **two distinct install steps** — keep them straight:

| Step | Command | What it does |
|---|---|---|
| 1. Bootstrap | `sh install.sh` | Places the `plan.sh` CLI + registry + adapters on your machine. |
| 2. Render | `plan.sh install` | Renders skillsets from the registry into your harnesses. |

---

## Requirements

- A POSIX shell (`/bin/sh`) and standard Unix utilities: `sed`, `awk`, `grep`,
  `find`, `cmp`, `mktemp`, `date`, `sort`, `tr`, `wc`, `tail`, `cp`, `mv`, `mkdir`,
  `rmdir`, `dirname`, `chmod` (the usual coreutils, which ship together).
- A SHA-256 tool — any one of `sha256sum`, `shasum`, or `openssl`.
- `tar` — only for installing from a tarball; `curl` or `wget` — only for the
  remote-tarball install mode.
- `python3` — **only** required if you add an MCP server and render it for
  Claude (the JSON merge uses it). Nothing else needs Python. Codex MCP merges
  need no extra tools.
- **No `sudo`.** Everything is installed under your home directory by default.

All shell files are POSIX `sh` and pass `shellcheck`.

---

## Quickstart

```sh
git clone <repo-url> plan.sh
cd plan.sh

sh install.sh            # 1. put the CLI + registry on your machine
plan.sh install          # 2. render skills into auto-detected harnesses
plan.sh doctor           # 3. confirm everything matches the registry (exit 0)
```

If `plan.sh` isn't found after step 1, `~/.local/bin` isn't on your `PATH` — the
installer prints the exact `export PATH=...` line to add. (Or try it without
installing: from the clone, run `sh ./plan.sh list`.)

---

## Installation (bootstrap)

`install.sh` is the bootstrap. It is idempotent (safe to re-run) and never uses
`sudo`.

### From a clone (works today)

```sh
git clone <repo-url> plan.sh && cd plan.sh
sh install.sh
```

This installs:

- the CLI **launcher** at `~/.local/bin/plan.sh`, and
- the tool **data** (a copy of `plan.sh`, `registry/`, `adapters/`) at
  `~/.local/share/plan.sh`.

The launcher is a tiny script that points the CLI at its installed data dir, so
the CLI always finds its registry regardless of where you call it from.

### One-liner (`curl | sh`) — once a release is published

```sh
curl -fsSL https://<host>/install.sh | sh
```

When piped with no local source tree, point the installer at a release tarball:

```sh
curl -fsSL https://<host>/install.sh | PLAN_SH_TARBALL_URL=https://<host>/plan.sh.tar.gz sh
```

### Bootstrap environment overrides

| Variable | Purpose | Default |
|---|---|---|
| `BIN_DIR` | where the CLI launcher is written | `~/.local/bin` |
| `INSTALL_DIR` | where CLI + registry + adapters live | `$XDG_DATA_HOME/plan.sh` |
| `XDG_DATA_HOME` | base for the default `INSTALL_DIR` | `~/.local/share` |
| `PLAN_SH_SRC` | install from this local source tree (skips auto-detect) | (auto-detected) |
| `PLAN_SH_TARBALL` | install from this local `.tar.gz` | — |
| `PLAN_SH_TARBALL_URL` | download + install from this remote `.tar.gz` | — |

The installer resolves its source in this order: `PLAN_SH_SRC` → the directory
it was run from (a clone) → `PLAN_SH_TARBALL` → `PLAN_SH_TARBALL_URL`. If none
apply, it fails loudly.

Example (custom locations):

```sh
BIN_DIR=~/bin INSTALL_DIR=~/tools/plan.sh sh install.sh
```

If `BIN_DIR` is not on your `PATH`, the installer prints the exact line to add —
it **never** edits your dotfiles:

```
install.sh: NOTE: /home/you/.local/bin is not on your PATH. Add it with:
install.sh:   export PATH="/home/you/.local/bin:$PATH"
```

---

## Commands

After bootstrapping, the `plan.sh` CLI renders and manages skills in your
harnesses. Run `plan.sh --help` for the summary, `plan.sh --version` for the
version.

```
plan.sh <command> [options]

  install     Render skillset(s) into detected/selected harnesses
  list        Show registry skillsets/skills and where they are installed
  add         Render an additional skillset into targeted harnesses
  sync        Re-render to reconcile installed outputs with the registry
  doctor      Report drift and missing harness dirs (non-zero on problems)
  uninstall   Remove rendered files this tool created; restore backups
```

### `plan.sh install [--harness a,b] [--skillset x,y]`

Renders skillsets into harnesses and records what it wrote.

- `--harness` — comma-separated harness list (`claude`, `codex`). Omit it to
  **auto-detect** installed harnesses.
- `--skillset` — comma-separated skillset list. Omit it to install **every**
  skillset in the registry.

Both flags accept either a space (`--harness claude,codex`) or an equals sign
(`--harness=claude,codex`); the same is true for `uninstall --harness`.

```console
$ plan.sh install --harness claude,codex
plan.sh: installed skillset "plan" into harness "claude"
plan.sh: installed skillset "plan" into harness "codex"
plan.sh: install complete (2 skillset/harness pair[s]); state: /home/you/.local/state/plan.sh/state
```

If no harness is detected and none is named, it fails loudly and lists the
harnesses it knows about:

```
plan.sh: no harness detected; pass --harness (available: claude,codex)
```

### `plan.sh list`

Shows each registry skillset, its skills, and which harnesses it is installed
into (read-only).

```console
$ plan.sh list
plan.sh: registry skillsets
  plan — Phased planning skills (create/phase/reflect/auto/multi/task)
    skills: plan-create, plan-phase, plan-reflect, plan-auto, plan-multi, plan-task
    installed into: claude, codex
```

A skillset that isn't installed anywhere shows `installed into: (none)`.

### `plan.sh add <skillset>`

Renders one additional skillset into the harnesses you have already installed
into (read from the state file). Requires a prior `install`; otherwise it tells
you to run `install` first.

### `plan.sh sync`

Re-renders every `(harness, skillset)` pair recorded in state to reconcile the
installed files with the current registry — this is how you push registry
updates and repair drift. With nothing installed it is a no-op.

### `plan.sh doctor`

Checks every installed file against what the registry would render **right now**
and reports problems; useful in CI or before relying on the skills.

- Exit **0** and a clean message when everything matches (or nothing is
  installed).
- Exit **non-zero** and a list of issues (to stderr) on any drift: a file
  edited since install, a registry change not yet `sync`'d, a missing file, an
  orphan, or a missing harness directory.

```console
$ plan.sh doctor
plan.sh: doctor: clean (all installed outputs match the registry)

$ plan.sh doctor        # after a rendered file was hand-edited
plan.sh: doctor found drift/issues:
  - modified/drift: /home/you/.claude/skills/plan-create/SKILL.md
$ echo $?
1
```

Run `plan.sh sync` to repair drift, then `plan.sh doctor` again.

### `plan.sh uninstall [--harness a,b]`

Removes only the files this tool rendered. If a file replaced a pre-existing
("foreign") file at install time, its backup is restored; otherwise the file is
removed. Empty directories the tool created are cleaned up. Unrelated skills are
never touched. Omit `--harness` to uninstall from every harness in state.

```console
$ plan.sh uninstall
plan.sh: uninstall complete (removed 14, restored 0).
```

---

## What gets created, and where

Everything is under your home directory; all paths honor the overrides shown.

| What | Location | Override |
|---|---|---|
| CLI launcher | `~/.local/bin/plan.sh` | `BIN_DIR` |
| Tool data (CLI + `registry/` + `adapters/`) | `~/.local/share/plan.sh` | `INSTALL_DIR`, `XDG_DATA_HOME` |
| State record + backups | `~/.local/state/plan.sh/` | `XDG_STATE_HOME` |
| Rendered Claude skills | `~/.claude/skills/<skill>/SKILL.md` | `CLAUDE_SKILLS_DIR` |
| Rendered Codex skills | `<codex skills dir>/<skill>/SKILL.md` | `CODEX_SKILLS_DIR` |
| Shared files (per skillset) | `<skills dir>/<skillset>-shared/` (e.g. `plan-shared/`) | — |
| Claude MCP config (only if a server is added) | `~/.mcp.json` | `CLAUDE_MCP_CONFIG` |
| Codex MCP config (only if a server is added) | `~/.codex/config.toml` | `CODEX_CONFIG` |

The **state record** (`~/.local/state/plan.sh/state`) is a tab-separated file —
one line per rendered file: `harness  skillset  item  rendered-path  sha256`.
It drives `doctor`, `sync`, and `uninstall`. **Backups** of any pre-existing
files that were overwritten are kept under
`~/.local/state/plan.sh/backups/<UTC-timestamp>/<harness>/…`.

---

## Verifying your installation

The repo ships a full end-to-end smoke test that runs the whole lifecycle in a
throwaway `HOME` (faking a Codex install) and asserts each step:

```sh
sh tests/e2e.sh
# ... per-step PASS lines ...
# == e2e RESULT: pass=15 fail=0 ==
```

It covers: bootstrap install → `plan.sh install --harness claude,codex` →
`doctor` exits 0 → six placeholder-free `SKILL.md` files per harness → adding a
new registry skill renders → `plan.sh uninstall` → bootstrap uninstall →
sandbox clean.

The MCP extension point has its own test that runs both emitters against the
test fixtures and asserts the merged JSON/TOML (and that merges preserve
unrelated entries):

```sh
sh tests/mcp.sh
# == mcp emitter test RESULT: pass=N fail=0 ==
```

To check the shell sources directly:

```sh
sh -n plan.sh install.sh adapters/*.sh tests/*.sh        # parse
shellcheck --shell=sh plan.sh install.sh adapters/*.sh tests/*.sh   # lint (no findings)
```

Manual spot-checks after a real `plan.sh install`:

```sh
plan.sh doctor                                  # exit 0
plan.sh list                                    # shows "installed into: ..."
grep -rl '{{' ~/.claude/skills && echo BAD || echo "no placeholders"  # must say "no placeholders"
ls -d ~/.claude/skills/plan-*/                   # six skill dirs + plan-shared/
```

---

## Extending the registry

You grow the planning system — and add the research skills and MCP servers that
round it out — the same way: drop a file in the registry, no engine change. The
full contract is in [`registry/FORMAT.md`](registry/FORMAT.md).

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
   mcp: none                        # or an MCP server name (see below)
   ```
4. Render it: `plan.sh install --skillset <skillset>` (or, into already-targeted
   harnesses, `plan.sh add <skillset>`).

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
   The manifest references the file by its **filename** (`mcp: <name>`), while the
   emitted server is **keyed by the `name:` value**. Keep them identical — this is
   an authoring convention; the tool does not enforce it.
2. Reference it from a skillset manifest: `mcp: <name>`.
3. On `plan.sh install` / `add`, it is merged per harness:
   - **Claude** → `~/.mcp.json` under `mcpServers` (override `CLAUDE_MCP_CONFIG`).
     This JSON merge uses `python3`.
   - **Codex** → `~/.codex/config.toml` as `[mcp_servers.<name>]` (override
     `CODEX_CONFIG`). No extra dependency.

   Merges **preserve unrelated** servers/tables and existing top-level keys. v1
   ships zero MCP servers, so by default no MCP config is written.

---

## How rendering works

- **Placeholders** (`{{SHARED_DIR}}`, `{{SKILLS_DIR}}`, `{{INVOKE:<name>}}`) are
  resolved per harness. If any `{{…}}` token survives, the render **fails loud**
  rather than writing a broken file.
- **Idempotent.** Re-rendering a byte-identical file is a no-op. Running
  `install` twice produces identical output and no duplicates.
- **Backups, never clobber.** Before overwriting a file the tool did *not*
  create, the original is backed up under the state dir. `uninstall` restores
  the most recent such backup.
- **Drift is defined against the registry.** `doctor` re-renders from the
  registry and compares — so it catches both files edited after install *and*
  registry changes you haven't `sync`'d yet.
- **Fail loud.** A missing skillset, unknown harness, unlocatable Codex dir, or
  unresolved placeholder stops with a clear, non-zero error. The tool never
  reports success on partial work.

---

## Harness notes

| Harness | Skills directory | Override | MCP config | MCP override |
|---|---|---|---|---|
| Claude Code | `~/.claude/skills` | `CLAUDE_SKILLS_DIR` | `~/.mcp.json` | `CLAUDE_MCP_CONFIG` |
| Codex | probed (e.g. `~/.codex/skills`) | `CODEX_SKILLS_DIR` | `~/.codex/config.toml` | `CODEX_CONFIG` |

**Auto-detection** (used by `install` with no `--harness`):

- Claude is detected if `~/.claude` exists (or `CLAUDE_SKILLS_DIR` is set).
- Codex is detected if its skills directory can be located: `CODEX_SKILLS_DIR`,
  or an existing `~/.codex/skills` / `~/.config/codex/skills`, or an existing
  `~/.codex` / `~/.config/codex` base directory.

**Codex directory probe.** Because Codex's skills directory is not officially
confirmed, the Codex adapter probes the candidates above and **fails loud** if
none exist — naming `CODEX_SKILLS_DIR` as the override. It never guesses or
creates a directory it could not locate. Set `CODEX_SKILLS_DIR` to install into
an explicit path.

---

## Uninstalling

Two distinct steps, run in this order:

```sh
plan.sh uninstall            # 1. remove rendered skills from harnesses (restores any backups)
sh install.sh --uninstall    # 2. remove the plan.sh CLI + registry/adapters
```

`plan.sh uninstall` needs the CLI present, so do it first. The bootstrap
uninstall removes the launcher and the tool data dir but **leaves rendered
harness skills untouched** — if any are still installed, it warns you to run
`plan.sh uninstall` first.

---

## Repository layout

```
plan.sh        the CLI (install / list / add / sync / doctor / uninstall)
install.sh     the curl|sh bootstrap (places the CLI + registry on a machine)
registry/
  FORMAT.md    the contract every skillset / MCP server conforms to
  skills/
    plan/      the bundled plan-* skillset (manifest + 6 skills + shared/)
  mcp/         neutral MCP server definitions (empty in v1)
adapters/
  claude.sh    Claude Code adapter
  codex.sh     Codex adapter (probes for its skills dir, fails loud)
tests/
  e2e.sh       full-lifecycle smoke test
  mcp.sh       MCP emitter test (runs both emitters against the fixtures)
  fixtures/    test-only MCP server fixtures
plans/         repo-local plans (this repo's own plans)
README.md
```

---

## Design principles

- **Canonical registry + thin adapters.** The registry is the single source of
  truth; a harness adapter is a ~40-line POSIX-sh file describing only that
  harness's paths and conventions. Supporting a new harness is a new adapter,
  not an engine change.
- **Installer, not a runtime.** `plan.sh` only copies files and substitutes
  placeholders. No skill logic lives in shell.
- **Idempotent, reversible, fail-loud.** Safe to re-run; backs up before
  overwriting; restores on uninstall; stops on the first real problem instead of
  silently continuing.

The full machine-readable contract — manifest schema, placeholder grammar,
adapter interface, MCP schema, and on-disk state/layout — is in
[`registry/FORMAT.md`](registry/FORMAT.md).
