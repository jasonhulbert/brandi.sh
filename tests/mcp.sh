#!/bin/sh
# tests/mcp.sh — exercise the MCP emitters against the test fixtures.
#
# Runs the Claude (JSON) and Codex (TOML) emitters on tests/fixtures/mcp/* via
# the internal `plan.sh _mcp` command and asserts the merged output, including
# that merging preserves unrelated servers/tables. The Claude (JSON) checks need
# python3 (as the Claude emitter itself does) and are skipped with a note if it
# is absent; the Codex (TOML) checks need no extra tools and always run.
set -u

REPO=$(CDPATH='' cd -- "$(dirname -- "$0")/.." && pwd)
FIX="$REPO/tests/fixtures/mcp"
PSH="$REPO/plan.sh"

pass=0
fail=0
ok() { printf '  PASS: %s\n' "$1"; pass=$((pass + 1)); }
no() { printf '  FAIL: %s\n' "$1"; fail=$((fail + 1)); }
skip() { printf '  SKIP: %s\n' "$1"; }

emit() { # <claude|codex> <serverfile> <target>
	sh "$PSH" _mcp "$1" "$2" "$3"
}

T=$(mktemp -d)

printf '== Codex (TOML) emitter ==\n'
CT="$T/config.toml"
if emit codex "$FIX/example" "$CT" >/dev/null 2>&1; then ok "codex emit exits 0"; else no "codex emit"; fi
if grep -q '^\[mcp_servers\.example\]' "$CT"; then ok "codex: [mcp_servers.example] table"; else no "codex: missing table"; fi
if grep -q 'command = "npx"' "$CT"; then ok "codex: command"; else no "codex: command wrong"; fi
if grep -qF '"@example/mcp-server"' "$CT"; then ok "codex: args"; else no "codex: args wrong"; fi
if grep -q 'API_KEY = "secret123"' "$CT"; then ok "codex: env"; else no "codex: env wrong"; fi

printf '== Codex merge preserves an unrelated table + top-level key ==\n'
CM="$T/merge.toml"
printf 'topkey = "keepme"\n\n[mcp_servers.other]\ncommand = "x"\n' > "$CM"
emit codex "$FIX/example" "$CM" >/dev/null 2>&1
if grep -q '^\[mcp_servers\.other\]' "$CM" && grep -q 'topkey = "keepme"' "$CM" && grep -q '^\[mcp_servers\.example\]' "$CM"; then
	ok "codex merge keeps other table, topkey, and adds example"
else
	no "codex merge clobbered something"
fi

printf '== Codex URL-based server ==\n'
CU="$T/url.toml"
emit codex "$FIX/example-url" "$CU" >/dev/null 2>&1
if grep -q 'url = "https://mcp.example.com/sse"' "$CU"; then ok "codex: url server"; else no "codex: url wrong"; fi

printf '== Claude (JSON) emitter ==\n'
if command -v python3 >/dev/null 2>&1; then
	JT="$T/mcp.json"
	if emit claude "$FIX/example" "$JT" >/dev/null 2>&1; then ok "claude emit exits 0"; else no "claude emit"; fi
	if python3 - "$JT" <<'PY'
import json, sys
d = json.load(open(sys.argv[1]))
s = d["mcpServers"]["example"]
assert s["command"] == "npx", s
assert s["args"] == ["-y", "@example/mcp-server"], s
assert s["env"]["API_KEY"] == "secret123", s
PY
	then ok "claude: valid JSON with command/args/env under mcpServers"; else no "claude: JSON fields wrong"; fi

	JM="$T/merge.json"
	printf '{"mcpServers":{"other":{"command":"x"}},"top":1}' > "$JM"
	emit claude "$FIX/example" "$JM" >/dev/null 2>&1
	if python3 - "$JM" <<'PY'
import json, sys
d = json.load(open(sys.argv[1]))
assert d["mcpServers"]["other"]["command"] == "x", d
assert d["mcpServers"]["example"]["command"] == "npx", d
assert d["top"] == 1, d
PY
	then ok "claude merge keeps unrelated server + top-level key"; else no "claude merge clobbered something"; fi

	JU="$T/url.json"
	emit claude "$FIX/example-url" "$JU" >/dev/null 2>&1
	if python3 - "$JU" <<'PY'
import json, sys
d = json.load(open(sys.argv[1]))
assert d["mcpServers"]["example-url"]["url"] == "https://mcp.example.com/sse", d
PY
	then ok "claude: url server"; else no "claude: url wrong"; fi
else
	skip "python3 not found — Claude JSON emitter checks skipped (the Claude emitter requires python3)"
fi

rm -rf "$T"
printf '\n== mcp emitter test RESULT: pass=%d fail=%d ==\n' "$pass" "$fail"
[ "$fail" = 0 ]
