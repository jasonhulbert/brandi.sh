# adapters/codex.sh — Codex harness adapter.
#
# Sourced by brandi.sh. Codex stores user-level skills at $CODEX_HOME/skills
# (CODEX_HOME defaults to ~/.codex); project-level skills are .codex/skills.
# See https://developers.openai.com/codex/skills . This adapter resolves that
# location (honoring CODEX_SKILLS_DIR / CODEX_HOME) and FAILS LOUD (non-zero,
# naming the override) when it cannot be located — it never guesses or creates a
# directory. See registry/FORMAT.md §6 for the adapter contract.

# Consumed by brandi.sh after sourcing (FORMAT.md §6); shellcheck can't see cross-file use.
# shellcheck disable=SC2034
ADAPTER_NAME=codex

# True (0) if Codex appears installed on this machine (the probe succeeds).
adapter_detect() {
	adapter_skills_dir >/dev/null 2>&1
}

# Absolute Codex skills root. Codex's user-level skills live at $CODEX_HOME/skills
# (CODEX_HOME defaults to ~/.codex); see https://developers.openai.com/codex/skills .
#   1. CODEX_SKILLS_DIR override always wins (the user opted in; created if absent).
#   2. else CODEX_HOME, if set, gives $CODEX_HOME/skills (Codex's own home override).
#   3. else an already-existing Codex skills dir is used as-is.
#   4. else, if a Codex base dir exists (Codex is installed), derive <base>/skills.
#   5. else fail loud — do not guess, do not create.
adapter_skills_dir() {
	if [ -n "${CODEX_SKILLS_DIR:-}" ]; then
		printf '%s\n' "$CODEX_SKILLS_DIR"
		return 0
	fi

	if [ -n "${CODEX_HOME:-}" ]; then
		printf '%s/skills\n' "$CODEX_HOME"
		return 0
	fi

	_xdg="${XDG_CONFIG_HOME:-$HOME/.config}"

	for _cand in "$HOME/.codex/skills" "$_xdg/codex/skills"; do
		if [ -d "$_cand" ]; then
			printf '%s\n' "$_cand"
			return 0
		fi
	done

	for _base in "$HOME/.codex" "$_xdg/codex"; do
		if [ -d "$_base" ]; then
			printf '%s/skills\n' "$_base"
			return 0
		fi
	done

	printf 'brandi.sh: cannot locate the Codex skills directory; set CODEX_SKILLS_DIR or CODEX_HOME to override (probed %s and %s)\n' \
		"$HOME/.codex" "$_xdg/codex" >&2
	return 1
}

# Absolute shared dir for a skillset: <skills_dir>/<skillset>-shared.
adapter_shared_dir() {
	printf '%s/%s-shared\n' "$(adapter_skills_dir)" "$1"
}

# Frontmatter name key Codex expects (the Agent Skills standard 'name').
adapter_frontmatter_key() {
	printf 'name\n'
}

# Absolute path of the Codex MCP config target (TOML). CODEX_CONFIG overrides.
# Finalized in Phase 6.
adapter_mcp_target() {
	printf '%s\n' "${CODEX_CONFIG:-$HOME/.codex/config.toml}"
}

# Merge one neutral MCP server definition into the Codex config.
adapter_mcp_emit() {
	mcp_emit_codex "$1" "$(adapter_mcp_target)"
}

# Read one MCP server from the Codex MCP config into the neutral registry
# format (used by ingest; the reverse of adapter_mcp_emit).
adapter_mcp_read() {
	mcp_read_codex "$1" "$(adapter_mcp_target)"
}
