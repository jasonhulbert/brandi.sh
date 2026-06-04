# brandi.sh Registry FORMAT

The single source of truth for how `brandi.sh` stores, declares, renders, and
**ingests** skillsets and MCP servers. Every contribution to a registry, and
every adapter, conforms to what is written here.

If a script seems to disagree with this file, **this file wins** — fix the
script.

`brandi.sh` is *only an installer/renderer*. It does deterministic work: copy
files, substitute placeholders, and normalize frontmatter keys. All
judgment/reasoning lives in the skill markdown, never in shell.

The **registry is user-owned**: the tool ships an engine, not content. Your
registry lives in your data dir (§9) and is populated by `ingest` (§8) or by
hand. The tool creates it but never overwrites it.

---

## 1. Architecture

Canonical registry + thin per-harness adapters (the shadcn / `ui.sh` model),
split into an **engine** (shipped code) and **content** (your registry):

- The **registry** is the one canonical, vendor-neutral source for every skill
  and MCP server. It is user-owned and lives in the data dir (§9), not in the
  repo.
- An **adapter** is a small POSIX-`sh` file (shipped with the engine) that knows
  one harness's filesystem conventions (where skills live, how shared files are
  placed, how MCP config is read and written).
- The **renderer** copies a canonical skillset through an adapter, resolving
  placeholders, producing the harness-specific install.
- The **ingester** does the renderer in reverse: it reads a harness's skills/MCP
  and writes them back into the registry in canonical form (§8).

Adding a skill or MCP server is "drop a folder/file in the registry" (or run
`ingest`) — never a change to the engine.

```
engine root ($INSTALL_DIR)            data dir ($BRANDI_SH_DATA)
├── brandi.sh        # CLI            ├── registry/
└── adapters/                         │   ├── FORMAT.md*       (* lives in the repo,
    ├── claude.sh                     │   ├── skills/             not the data dir)
    └── codex.sh                      │   │   └── <skillset>/
                                      │   │       ├── manifest
   render  ─────────────────────▶     │   │       ├── <skill>/SKILL.md
   ingest  ◀─────────────────────     │   │       └── shared/<file>
                                      │   └── mcp/
                                      │       └── <server>
                                      ├── state
                                      └── backups/
```

By default the engine root and the data dir are the same directory
(`$XDG_DATA_HOME/brandi.sh`) but occupy distinct subpaths; they can be split with
`INSTALL_DIR` / `BRANDI_SH_DATA` (§9).

---

## 2. Skillset layout

A **skillset** is a directory under `registry/skills/` whose name is the skillset
id (kebab-case, e.g. `foo-kit`). It contains:

- a `manifest` file (see §3),
- one subdirectory per skill, each holding a `SKILL.md` (and optional
  `references/`, `scripts/` per the Agent Skills standard),
- an optional `shared/` directory for files referenced by more than one skill in
  the set (e.g. a shared contract document).

The skill subdirectory name is the skill's installed name (e.g. `foo-task/`
installs as the skill `foo-task`).

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
| `shared` | yes | A file under the skillset (path relative to the skillset dir, e.g. `shared/CONTRACT.md`) installed into the skillset's shared dir. |
| `mcp` | yes | Name of an MCP server (a file in `registry/mcp/`) this skillset needs. The literal `none`, or no `mcp:` line at all, means zero MCP needs. |

Example (`registry/skills/foo-kit/manifest`):

```
skillset: foo-kit
description: ingested skillset foo-kit
skill: foo-task
skill: foo-debug
shared: shared/CONTRACT.md
mcp: acme
```

`ingest` synthesizes this manifest (creating `skillset:` + `description:` on
first ingest) and merges into it (appending a `skill:` / `mcp:` line only if
that exact line is absent).

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
  `skill_name:` key; `ingest` normalizes `skill_name:` → `name:` exactly once at
  ingest time (in the leading frontmatter block). The `description` value is
  preserved verbatim.
- v1 target harnesses (Claude Code, Codex) both consume the `name:` key, so the
  renderer does not rewrite it per-harness. An adapter may declare a different
  expected key for a future harness via `adapter_frontmatter_key` (default
  `name`); the renderer rewrites the single frontmatter key accordingly.

---

## 5. Placeholder grammar

Placeholders are double-brace tokens the renderer resolves per harness. A
canonical skill must contain **no** harness-specific absolute paths; it uses
placeholders instead. Every token below is resolved before a file is written; a
rendered file must contain no `{{...}}` token.

| Token | Resolves to |
|---|---|
| `{{SHARED_DIR}}` | Absolute path of the skillset's installed **shared** directory in the target harness. Default resolution: `<skills_dir>/<skillset>-shared`. |
| `{{SKILLS_DIR}}` | Absolute path of the harness's **skills root** directory (e.g. `~/.claude/skills`). |
| `{{INVOKE:<name>}}` | A harness-appropriate reference to another skill named `<name>`. In v1, both Claude and Codex reference skills by bare name, so this resolves to the literal `<name>`. Provided for future harnesses whose invocation form differs. |

Notes:

- Tokens are matched literally (no whitespace inside the braces:
  `{{SHARED_DIR}}`, not `{{ SHARED_DIR }}`). `{{INVOKE:<name>}}` takes the skill
  name between the colon and the closing braces.
- On `ingest`, the **shared** and **skills** placeholders are re-created from the
  source harness's absolute paths (best-effort; see §8). `{{INVOKE:…}}` is **not**
  reconstructed (bare names are ambiguous) and is left as written.

---

## 6. Adapter contract

An adapter is `adapters/<harness>.sh`, a POSIX-`sh` file that the engine
**sources**. When sourced it must define one variable and a set of functions.
Functions echo their result to stdout and **fail loud** (non-zero exit + a
message on stderr) when they cannot satisfy the request — never guess.

| Symbol | Kind | Contract |
|---|---|---|
| `ADAPTER_NAME` | variable | Short harness id, e.g. `claude` / `codex`. Must equal the adapter's filename stem; the engine asserts this after sourcing. |
| `adapter_detect` | function | Return 0 if this harness appears installed on the machine, non-zero otherwise. Used by `install` to auto-select harnesses when `--harness` is not given. |
| `adapter_skills_dir` | function | Echo the absolute skills-root directory for this harness, honoring env overrides. Exit non-zero with an actionable message (naming the override variable) if it cannot be located. |
| `adapter_shared_dir <skillset>` | function | Echo the absolute shared directory for `<skillset>`. Default behavior: `"$(adapter_skills_dir)/$1-shared"`. |
| `adapter_frontmatter_key` | function | Echo the frontmatter name key this harness expects. Default `name`. |
| `adapter_mcp_target` | function | Echo the absolute path of the harness's MCP config file (§7). |
| `adapter_mcp_emit <server-file>` | function | Merge one neutral MCP server definition (§7) into this harness's MCP config without clobbering unrelated entries. |
| `adapter_mcp_read <server-name>` | function | The reverse of `adapter_mcp_emit`: read one named server from this harness's MCP config and echo it in the neutral format (§7) to stdout; non-zero if absent. Used by `ingest --mcp`. |

The engine never hardcodes a harness path; it asks the adapter. This is what
keeps harness specifics in a small adapter and out of the engine.

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

Emitters transform one neutral definition into:

- **Claude** — a JSON object merged under `mcpServers` in the Claude MCP target
  (`adapter_mcp_target`), of the form
  `{"command": <command>, "args": [<arg>…], "env": {<env>…}}` for stdio, or
  `{"url": <url>}` for HTTP/SSE. Merging must not clobber unrelated servers.
- **Codex** — a `[mcp_servers.<name>]` TOML table merged into the Codex config
  (`adapter_mcp_target`, e.g. `~/.codex/config.toml`) with `command`, `args`,
  `env` keys. Merging must not clobber unrelated tables.

`ingest --mcp` reads the same configs back into this neutral format (§8): the
Claude JSON is parsed with `python3`; the Codex TOML is parsed with `tomllib`
(Python ≥ 3.11).

---

## 8. Ingest contract (reverse render)

`ingest` is the renderer run backwards: it reads a harness's installed skills and
MCP servers and writes them into the registry in canonical form. It writes only
into the user's own data-dir registry, so it needs no foreign-file backup logic
there; it is idempotent and must not disturb unrelated skillsets/servers.

```
brandi.sh ingest --harness <h> --skillset <set> [--skill <csv>] [--mcp <csv>]
```

- `--harness` and `--skillset` are **required**; at least one of `--skill` /
  `--mcp` must be given. The harness must be specified — the tool cannot reverse-
  read a skill or server without knowing the source harness's conventions.

### Skill ingest (`--skill`)

For each named skill:

1. Copy its file tree from the harness's `adapter_skills_dir`/`<skill>` into
   `registry/skills/<set>/<skill>/`.
2. **Normalize the frontmatter key** `skill_name:` → `name:` (once, in the
   leading frontmatter block; §4).
3. **Best-effort re-tokenize** the harness's own shared-dir and skills-dir
   absolute paths back into `{{SHARED_DIR}}` / `{{SKILLS_DIR}}` (the shared dir is
   tokenized first, as it is a sub-path of the skills dir). Any path not
   recognized is copied verbatim — re-tokenization is intentionally lossy and
   verbatim is the safe fallback.
4. **Synthesize/merge the manifest**: create `registry/skills/<set>/manifest`
   (with `skillset:` + `description:`) if absent; append a `skill: <skill>` line
   if missing.

### MCP ingest (`--mcp`)

For each named server, read it from the harness's `adapter_mcp_target` via
`adapter_mcp_read`, write a neutral `registry/mcp/<name>` file (§7), and append
`mcp: <name>` to the skillset manifest. Reading the Claude JSON needs `python3`;
reading the Codex TOML needs `tomllib` (Python ≥ 3.11). Reading is scoped to the
documented server shapes (§7); anything outside them fails loud rather than
guessing.

### Fail-loud and idempotence

`ingest` fails loud on: an unknown harness (no adapter), a skill directory not
present in the harness, an MCP server absent from the harness config, or a
missing parser. Re-ingesting identical content rewrites byte-identical canonical
files and adds no duplicate manifest lines.

`ingest` only populates the registry; it never installs. Installing into
harnesses is `install` / `add`.

---

## 9. Install layout, state, and overrides

The bootstrap (`install.sh`) and the `install` subcommand respect XDG and the
following env overrides. No `sudo`; everything lives under the user's home by
default.

| Thing | Default | Override |
|---|---|---|
| CLI launcher | `~/.local/bin/brandi.sh` | `BIN_DIR` |
| Engine (CLI + `adapters/`) | `$XDG_DATA_HOME/brandi.sh` → `~/.local/share/brandi.sh` | `INSTALL_DIR`, `XDG_DATA_HOME` |
| Data dir (`registry/`, `state`, `backups/`) | `$XDG_DATA_HOME/brandi.sh` → `~/.local/share/brandi.sh` | `BRANDI_SH_DATA`, `XDG_DATA_HOME` |
| Claude skills dir | `~/.claude/skills` | `CLAUDE_SKILLS_DIR` |
| Codex skills dir | `~/.codex/skills` → `$CODEX_HOME/skills` (CODEX_HOME defaults to `~/.codex`) | `CODEX_SKILLS_DIR`, `CODEX_HOME` |

The engine resolves its own root via `BRANDI_SH_ROOT` (set by the launcher);
the CLI resolves the data dir via `BRANDI_SH_DATA` (else `$XDG_DATA_HOME/brandi.sh`).
They coincide by default but occupy distinct subpaths, so the engine never ships
or owns the registry.

### Bootstrap safety (engine vs. content)

- `install.sh` installs/refreshes **only the engine** (`brandi.sh` + `adapters/`)
  and **ensures** `registry/skills` + `registry/mcp` exist under the data dir
  without overwriting any existing content. It never `rm -rf`s a registry.
- `install.sh --uninstall` removes the engine + launcher but **preserves** the
  data dir (registry, state, backups) by default, printing what it left and how
  to remove it. `install.sh --uninstall --purge` additionally deletes the data
  dir — the only path that destroys user content, and only on explicit opt-in.

### State file

`$DATA_DIR/state` records every rendered output so the tool can detect drift
(`doctor`), reconcile (`sync`), and cleanly remove only what it created
(`uninstall`). Line-oriented, tab-separated:

```
<harness>	<skillset>	<skill-or-shared>	<rendered-abs-path>	<sha256>
```

### Backups

Before overwriting any pre-existing file the tool did not create, the original is
copied into `$DATA_DIR/backups/<UTC-timestamp>/…` preserving its relative
location, so `uninstall` can restore it. The tool never overwrites without a
backup, and never reports success on partial work.

---

## 10. Invariants (quick reference)

- Registry is canonical, vendor-neutral, and **user-owned** (lives in the data
  dir, not the repo); adapters are thin, harness-specific, and shipped.
- `brandi.sh` only copies, substitutes placeholders, and normalizes frontmatter
  keys. No skill logic in shell.
- Manifest and MCP files are line-oriented `key: value`; `#`/blank lines ignored.
- Canonical SKILL.md frontmatter key is `name:` (`ingest` normalizes `skill_name:`).
- A rendered file contains no `{{...}}` placeholder; `ingest` re-tokenizes
  shared/skills paths best-effort (verbatim fallback).
- `{{SHARED_DIR}}` = `<skills_dir>/<skillset>-shared` unless an adapter overrides.
- Adapters fail loud; they never guess a missing directory.
- `ingest` only populates the registry; `install`/`add` render into harnesses.
- No `sudo`; XDG-aware paths; `INSTALL_DIR`/`BIN_DIR`/`BRANDI_SH_DATA`/`XDG_*`
  overridable; idempotent.
- The bootstrap never clobbers the registry; engine-uninstall preserves user data
  unless `--purge` is given.
- Never overwrite without a backup; never report success on partial work.
