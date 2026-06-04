# adapters/claude.sh — Claude Code harness adapter.
#
# Sourced by brandi.sh. Defines where Claude keeps skills and MCP config, how the
# skillset's shared dir is named, and the frontmatter key Claude expects.
# See registry/FORMAT.md §6 for the adapter contract. Functions echo their
# result to stdout and fail loud (non-zero) when they cannot satisfy a request.

# Consumed by brandi.sh after sourcing (FORMAT.md §6); shellcheck can't see cross-file use.
# shellcheck disable=SC2034
ADAPTER_NAME=claude

# True (0) if Claude Code appears installed on this machine.
adapter_detect() {
	[ -n "${CLAUDE_SKILLS_DIR:-}" ] || [ -d "$HOME/.claude" ]
}

# Absolute Claude skills root. Claude keeps skills under ~/.claude/skills;
# CLAUDE_SKILLS_DIR overrides (used for testing and non-standard layouts).
adapter_skills_dir() {
	printf '%s\n' "${CLAUDE_SKILLS_DIR:-$HOME/.claude/skills}"
}

# Absolute shared dir for a skillset. Default: <skills_dir>/<skillset>-shared,
# which reproduces Claude's existing ~/.claude/skills/plan-shared layout.
adapter_shared_dir() {
	printf '%s/%s-shared\n' "$(adapter_skills_dir)" "$1"
}

# Frontmatter name key Claude expects (the Agent Skills standard 'name').
adapter_frontmatter_key() {
	printf 'name\n'
}

# Absolute path of the Claude MCP config target (config-file merge; the default
# from the plan's Open Question on MCP target). CLAUDE_MCP_CONFIG overrides.
# Finalized in Phase 6.
adapter_mcp_target() {
	printf '%s\n' "${CLAUDE_MCP_CONFIG:-$HOME/.mcp.json}"
}

# Merge one neutral MCP server definition into the Claude MCP config.
adapter_mcp_emit() {
	mcp_emit_claude "$1" "$(adapter_mcp_target)"
}

# Read one MCP server from the Claude MCP config into the neutral registry
# format (used by ingest; the reverse of adapter_mcp_emit).
adapter_mcp_read() {
	mcp_read_claude "$1" "$(adapter_mcp_target)"
}
