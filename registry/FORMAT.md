# plan.sh Registry FORMAT

The single source of truth for how `plan.sh` stores, declares, and renders
skillsets and MCP servers. This file is to `plan.sh` what `PLAN-CONTRACT.md` is
to the plan skills: every contribution to the registry, and every adapter,
conforms to what is written here.

If a script seems to disagree with this file, **this file wins** — fix the
script.

`plan.sh` is *only an installer/renderer*. It does deterministic work: copy
files and substitute placeholders. All judgment/reasoning lives in the skill
markdown, never in shell.

---

## 1. Architecture

Canonical registry + thin per-harness adapters (the shadcn / `ui.sh` model):

- The **registry** is the one canonical, vendor-neutral source for every skill
  and MCP server.
- An **adapter** is a small POSIX-`sh` file that knows one harness's filesystem
  conventions (where skills live, how shared files are placed, how MCP config is
  written).
- The **renderer** copies a canonical skillset through an adapter, resolving
  placeholders, producing the harness-specific install.

Adding a skill or MCP server is "drop a folder/file in the registry" — never a
change to the engine.

```
<repo root>
├── plan.sh                     # CLI entrypoint (POSIX sh)
├── install.sh                  # curl|sh bootstrap (places the CLI + registry)
├── registry/
│   ├── FORMAT.md               # this contract
│   ├── skills/
│   │   └── <skillset>/         # one directory per skillset (e.g. plan/)
│   │       ├── manifest        # declares skills, shared files, mcp needs
│   │       ├── <skill>/SKILL.md
│   │       └── shared/<file>   # files shared across the skillset's skills
│   └── mcp/
│       └── <server>            # one neutral MCP server definition per file
├── adapters/
│   ├── claude.sh
│   └── codex.sh
└── plans/                      # repo-local plans (this repo's own plans)
```

---

## 2. Skillset layout

A **skillset** is a directory under `registry/skills/` whose name is the
skillset id (kebab-case, e.g. `plan`). It contains:

- a `manifest` file (see §3),
- one subdirectory per skill, each holding a `SKILL.md` (and optional
  `references/`, `scripts/` per the Agent Skills standard),
- an optional `shared/` directory for files referenced by more than one skill in
  the set (e.g. a shared contract document).

The skill subdirectory name is the skill's installed name (e.g. `plan-create/`
installs as the skill `plan-create`).

---

## 3. Manifest schema

`registry/skills/<skillset>/manifest` is line-oriented so POSIX `sh` can parse it
without external tools. Format:

- One `key: value` per line. The delimiter is the first colon; a single leading
  space after the colon is trimmed.
- Lines beginning with `#` and blank lines are ignored.
- Some keys repeat; each occurrence adds one entry.

| Key | Repeats | Meaning |
|---|---|---|
| `skillset` | no | The skillset id. Must equal the directory name. |
| `description` | no | One-line human description. |
| `skill` | yes | A skill subdirectory name to install. Order is install order. |
| `shared` | yes | A file under the skillset (path relative to the skillset dir, e.g. `shared/PLAN-CONTRACT.md`) installed into the skillset's shared dir. |
| `mcp` | yes | Name of an MCP server (a file in `registry/mcp/`) this skillset needs. The literal `none`, or no `mcp:` line at all, means zero MCP needs. |

Example (`registry/skills/plan/manifest`):

```
skillset: plan
description: Phased planning skills (create/phase/reflect/auto/multi/task)
skill: plan-create
skill: plan-phase
skill: plan-reflect
skill: plan-auto
skill: plan-multi
skill: plan-task
shared: shared/PLAN-CONTRACT.md
mcp: none
```

---

## 4. SKILL.md frontmatter rule

Canonical `SKILL.md` files carry YAML frontmatter delimited by `---` fences, with
at least:

```
---
name: <skill-name>
description: <one-paragraph description>
---
```

- The **canonical key is `name:`**. Some upstream skills use the legacy
  `skill_name:` key; the importer normalizes `skill_name:` → `name:` exactly once
  at canonicalization time. The `description` value is preserved verbatim.
- v1 target harnesses (Claude Code, Codex) both consume the `name:` key, so the
  renderer does not rewrite it per-harness. An adapter may declare a different
  expected key for a future harness via `adapter_frontmatter_key` (default
  `name`); the renderer rewrites the single frontmatter key accordingly.

---

## 5. Placeholder grammar

Placeholders are double-brace tokens the renderer resolves per harness. A
canonical skill must contain **no** harness-specific absolute paths; it uses
placeholders instead. Every token below is resolved before the file is written;
a rendered file must contain no `{{...}}` token.

| Token | Resolves to |
|---|---|
| `{{SHARED_DIR}}` | Absolute path of the skillset's installed **shared** directory in the target harness. Default resolution: `<skills_dir>/<skillset>-shared`. |
| `{{SKILLS_DIR}}` | Absolute path of the harness's **skills root** directory (e.g. `~/.claude/skills`). |
| `{{INVOKE:<name>}}` | A harness-appropriate reference to another skill named `<name>`. In v1, both Claude and Codex reference skills by bare name, so this resolves to the literal `<name>`. Provided for future harnesses whose invocation form differs. |

Notes:

- The canonical `plan` skillset only needs `{{SHARED_DIR}}`: the five skills that
  referenced `~/.claude/skills/plan-shared/PLAN-CONTRACT.md` are rewritten to
  `{{SHARED_DIR}}/PLAN-CONTRACT.md`. `{{SKILLS_DIR}}` and `{{INVOKE:…}}` are part
  of the contract for future skills; the current `plan-*` text does not need
  them (they already cross-reference each other by bare name).
- Tokens are matched literally (no whitespace inside the braces:
  `{{SHARED_DIR}}`, not `{{ SHARED_DIR }}`). `{{INVOKE:<name>}}` takes the skill
  name between the colon and the closing braces.

---

## 6. Adapter contract

An adapter is `adapters/<harness>.sh`, a POSIX-`sh` file that the renderer
**sources**. When sourced it must define one variable and a set of functions.
Functions echo their result to stdout and **fail loud** (non-zero exit + a
message on stderr) when they cannot satisfy the request — never guess.

| Symbol | Kind | Contract |
|---|---|---|
| `ADAPTER_NAME` | variable | Short harness id, e.g. `claude` / `codex`. Must equal the adapter's filename stem; `render_skillset` asserts this after sourcing. |
| `adapter_detect` | function | Return 0 if this harness appears installed on the machine, non-zero otherwise. Used by `install` to auto-select harnesses when `--harness` is not given. |
| `adapter_skills_dir` | function | Echo the absolute skills-root directory for this harness, honoring env overrides. Exit non-zero with an actionable message (naming the override variable) if it cannot be located. |
| `adapter_shared_dir <skillset>` | function | Echo the absolute shared directory for `<skillset>`. Default behavior: `"$(adapter_skills_dir)/$1-shared"`. |
| `adapter_frontmatter_key` | function | Echo the frontmatter name key this harness expects. Default `name`. |
| `adapter_mcp_target` | function | Echo the absolute path of the harness's MCP config file (see §7). |
| `adapter_mcp_emit <server-file>` | function | Merge one neutral MCP server definition (§7) into this harness's MCP config without clobbering unrelated entries. (Stub until Phase 6.) |

The renderer never hardcodes a harness path; it asks the adapter. This is what
keeps harness specifics in ~30 lines of adapter and out of the engine.

---

## 7. MCP server schema

`registry/mcp/<server>` is one neutral, line-oriented definition per server,
parsed like a manifest (§3 rules: `key: value`, `#` comments, blank lines
ignored, some keys repeat).

| Key | Repeats | Meaning |
|---|---|---|
| `name` | no | Server id — the key the emitted config is written under. Keep it equal to the filename (the manifest references the file by filename); this is an authoring convention, not enforced by the tool. |
| `command` | no | Executable for a stdio server (mutually exclusive with `url`). |
| `arg` | yes | One argv element for `command`, in order. |
| `env` | yes | One `KEY=VALUE` environment entry. |
| `url` | no | Endpoint for an HTTP/SSE server (mutually exclusive with `command`). |

Emitters (Phase 6) transform one neutral definition into:

- **Claude** — a JSON object merged under `mcpServers` in the Claude MCP target
  (`adapter_mcp_target`), of the form
  `{"command": <command>, "args": [<arg>…], "env": {<env>…}}` for stdio, or
  `{"url": <url>}` for HTTP/SSE. Merging must not clobber unrelated servers.
- **Codex** — a `[mcp_servers.<name>]` TOML table merged into the Codex config
  (`adapter_mcp_target`, e.g. `~/.codex/config.toml`) with `command`, `args`,
  `env` keys. Merging must not clobber unrelated tables.

v1 ships **zero** servers (`registry/mcp/` empty of real servers). A test fixture
exercises both emitters; with zero server files, `install` writes no MCP config
and creates no empty config files.

---

## 8. Install layout, state, and overrides

The bootstrap (`install.sh`, Phase 7) and the `install` subcommand respect XDG
and the following env overrides. No `sudo`; everything lives under the user's
home by default.

| Thing | Default | Override |
|---|---|---|
| CLI entrypoint | `~/.local/bin/plan.sh` | `BIN_DIR` |
| Tool data (CLI + `registry/` + `adapters/`) | `$XDG_DATA_HOME/plan.sh` → `~/.local/share/plan.sh` | `INSTALL_DIR`, `XDG_DATA_HOME` |
| State (records, backups) | `$XDG_STATE_HOME/plan.sh` → `~/.local/state/plan.sh` | `XDG_STATE_HOME` |
| Claude skills dir | `~/.claude/skills` | `CLAUDE_SKILLS_DIR` |
| Codex skills dir | probed (e.g. `~/.codex/skills`) | `CODEX_SKILLS_DIR` |

### State file (Phase 5)

`$XDG_STATE_HOME/plan.sh/state` records every rendered output so the tool can
detect drift (`doctor`), reconcile (`sync`), and cleanly remove only what it
created (`uninstall`). Line-oriented, tab-separated:

```
<harness>	<skillset>	<skill-or-shared>	<rendered-abs-path>	<sha256>
```

### Backups

Before overwriting any pre-existing file the tool did not create, the original is
copied into `$XDG_STATE_HOME/plan.sh/backups/<UTC-timestamp>/…` preserving its
relative location, so `uninstall` can restore it. The tool never overwrites
without a backup, and never reports success on partial work (global Rule 12).

---

## 9. Invariants (quick reference)

- Registry is canonical and vendor-neutral; adapters are thin and harness-specific.
- `plan.sh` only copies + substitutes. No skill logic in shell.
- Manifest and MCP files are line-oriented `key: value`; `#`/blank lines ignored.
- Canonical SKILL.md frontmatter key is `name:` (importer normalizes `skill_name:`).
- A rendered file contains no `{{...}}` placeholder.
- `{{SHARED_DIR}}` = `<skills_dir>/<skillset>-shared` unless an adapter overrides.
- Adapters fail loud; they never guess a missing directory.
- No `sudo`; XDG-aware paths; `INSTALL_DIR`/`BIN_DIR`/`XDG_*` overridable; idempotent.
- Never overwrite without a backup; never report success on partial work.
