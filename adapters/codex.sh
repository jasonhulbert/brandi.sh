# adapters/codex.sh — Codex harness adapter.
#
# Sourced by plan.sh. The Codex skills directory is not officially confirmed, so
# this adapter PROBES for it at runtime and FAILS LOUD (non-zero, naming the
# override) when it cannot be located — it never guesses or creates a directory.
# See registry/FORMAT.md §6 for the adapter contract.

# Consumed by plan.sh after sourcing (FORMAT.md §6); shellcheck can't see cross-file use.
# shellcheck disable=SC2034
ADAPTER_NAME=codex

# True (0) if Codex appears installed on this machine (the probe succeeds).
adapter_detect() {
	adapter_skills_dir >/dev/null 2>&1
}

# Absolute Codex skills root.
#   1. CODEX_SKILLS_DIR override always wins (the user opted in; created if absent).
#   2. else an already-existing Codex skills dir is used as-is.
#   3. else, if a Codex base dir exists (Codex is installed), derive <base>/skills.
#   4. else fail loud — do not guess, do not create.
adapter_skills_dir() {
	if [ -n "${CODEX_SKILLS_DIR:-}" ]; then
		printf '%s\n' "$CODEX_SKILLS_DIR"
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

	printf 'plan.sh: cannot locate the Codex skills directory; set CODEX_SKILLS_DIR to override (probed %s and %s)\n' \
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
