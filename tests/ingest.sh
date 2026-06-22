#!/bin/sh
# tests/ingest.sh — exercise `brandi.sh ingest` (reverse render) for skills + MCP.
#
# Fakes a Claude harness in a sandbox HOME, ingests a skill and an MCP server
# into the data-dir registry (canonical placeholder form), checks frontmatter
# normalization, path re-tokenization, manifest wiring, idempotence, and
# fail-loud handling, then round-trips forward into a DIFFERENT harness (Codex)
# and (where tomllib is present) reverse-reads the Codex TOML back to confirm
# bidirectional fidelity. Exits non-zero if any check fails.
set -u

REPO=$(CDPATH='' cd -- "$(dirname -- "$0")/.." && pwd)
PSH="$REPO/brandi.sh"

pass=0
fail=0
ok()   { printf '  PASS: %s\n' "$1"; pass=$((pass + 1)); }
no()   { printf '  FAIL: %s\n' "$1"; fail=$((fail + 1)); }
skip() { printf '  SKIP: %s\n' "$1"; }

SBX=$(mktemp -d)
HOME="$SBX/home"
export HOME
export XDG_DATA_HOME="$SBX/xdg-data"
export XDG_CONFIG_HOME="$HOME/.config"
export BRANDI_SH_DATA="$SBX/data"
export CLAUDE_SKILLS_DIR="$SBX/claude/skills"
export CODEX_SKILLS_DIR="$SBX/codex/skills"
export CLAUDE_MCP_CONFIG="$SBX/claude/.mcp.json"
export CODEX_CONFIG="$SBX/codex/config.toml"
unset BRANDI_SH_ROOT 2>/dev/null || true

REG="$BRANDI_SH_DATA/registry"
CANON="$REG/skills/foo-kit/foo-task/SKILL.md"
SRV="$REG/mcp/acme"

# A fake Claude skill that references the harness's own shared + skills dirs by
# absolute path, and uses the legacy skill_name: frontmatter key.
mkdir -p "$CLAUDE_SKILLS_DIR/foo-task"
cat > "$CLAUDE_SKILLS_DIR/foo-task/SKILL.md" <<EOF
---
skill_name: foo-task
description: a foo task
---
# Foo Task

Shared contract: $CLAUDE_SKILLS_DIR/foo-kit-shared/CONTRACT.md
Skills root: $CLAUDE_SKILLS_DIR
EOF

for skill in obsidian-notes obsidian-search plan-task; do
	mkdir -p "$CLAUDE_SKILLS_DIR/$skill"
	cat > "$CLAUDE_SKILLS_DIR/$skill/SKILL.md" <<EOF
---
name: $skill
description: $skill fixture
---
# $skill
EOF
done

printf '== ingest a claude skill into the data-dir registry ==\n'
if sh "$PSH" ingest --harness claude --skill foo-task --skillset foo-kit >/dev/null 2>&1; then
	ok "ingest exits 0"
else
	no "ingest failed"
fi
if [ -f "$CANON" ]; then ok "canonical SKILL.md created"; else no "canonical SKILL.md missing"; fi
if grep -q '^name: foo-task' "$CANON"; then ok "frontmatter normalized to name:"; else no "frontmatter not normalized"; fi
if grep -q 'skill_name:' "$CANON"; then no "skill_name: still present"; else ok "no skill_name: remains"; fi
if grep -qF '{{SHARED_DIR}}/CONTRACT.md' "$CANON"; then ok "shared dir re-tokenized"; else no "shared dir not re-tokenized"; fi
if grep -qF 'Skills root: {{SKILLS_DIR}}' "$CANON"; then ok "skills dir re-tokenized"; else no "skills dir not re-tokenized"; fi
if [ -f "$REG/skills/foo-kit/manifest" ] && grep -qxF 'skill: foo-task' "$REG/skills/foo-kit/manifest"; then
	ok "manifest has 'skill: foo-task'"
else
	no "manifest missing skill line"
fi

printf '== ingest claude skills by pattern ==\n'
if sh "$PSH" ingest --harness claude --skill 'obsidian-*' --skillset obsidian-kit >/dev/null 2>&1; then
	ok "pattern ingest exits 0"
else
	no "pattern ingest failed"
fi
if [ -f "$REG/skills/obsidian-kit/obsidian-notes/SKILL.md" ] && [ -f "$REG/skills/obsidian-kit/obsidian-search/SKILL.md" ]; then
	ok "pattern-matched skills created"
else
	no "pattern-matched skills missing"
fi
if [ ! -e "$REG/skills/obsidian-kit/plan-task" ]; then
	ok "pattern skipped non-matching skill"
else
	no "pattern ingested non-matching skill"
fi
if grep -qxF 'skill: obsidian-notes' "$REG/skills/obsidian-kit/manifest" && grep -qxF 'skill: obsidian-search' "$REG/skills/obsidian-kit/manifest"; then
	ok "pattern manifest has matched skills"
else
	no "pattern manifest missing matched skills"
fi
if sh "$PSH" ingest --harness claude --skill 'missing-*' --skillset obsidian-kit >/dev/null 2>&1; then
	no "ingest of a non-matching pattern should fail"
else
	ok "non-matching pattern fails (non-zero)"
fi

printf '== re-ingest is idempotent ==\n'
before=$(cat "$CANON")
sh "$PSH" ingest --harness claude --skill foo-task --skillset foo-kit >/dev/null 2>&1
after=$(cat "$CANON")
if [ "$before" = "$after" ]; then ok "canonical file byte-identical after re-ingest"; else no "re-ingest changed the file"; fi
n=$(grep -cxF 'skill: foo-task' "$REG/skills/foo-kit/manifest")
if [ "$n" = 1 ]; then ok "no duplicate skill line"; else no "duplicate skill line (count=$n)"; fi

printf '== missing skill fails loud ==\n'
if sh "$PSH" ingest --harness claude --skill nope --skillset foo-kit >/dev/null 2>&1; then
	no "ingest of a missing skill should fail"
else
	ok "ingest of a missing skill fails (non-zero)"
fi

printf '== ingest a claude MCP server (JSON) into the registry ==\n'
cat > "$CLAUDE_MCP_CONFIG" <<'EOF'
{
  "mcpServers": {
    "acme": { "command": "npx", "args": ["-y", "@acme/mcp"], "env": {"API_KEY": "sek"} },
    "other": { "command": "keep-me" }
  }
}
EOF
if sh "$PSH" ingest --harness claude --mcp acme --skillset foo-kit >/dev/null 2>&1; then
	ok "mcp ingest exits 0"
else
	no "mcp ingest failed"
fi
if [ -f "$SRV" ]; then ok "neutral mcp file created"; else no "neutral mcp file missing"; fi
if grep -qxF 'command: npx' "$SRV" && grep -qxF 'arg: -y' "$SRV" && grep -qxF 'arg: @acme/mcp' "$SRV" && grep -qxF 'env: API_KEY=sek' "$SRV"; then
	ok "neutral mcp fields correct"
else
	no "neutral mcp fields wrong"
fi
if grep -qxF 'mcp: acme' "$REG/skills/foo-kit/manifest"; then ok "manifest wired 'mcp: acme'"; else no "manifest missing mcp line"; fi
if sh "$PSH" ingest --harness claude --mcp nope --skillset foo-kit >/dev/null 2>&1; then
	no "ingest of an absent mcp server should fail"
else
	ok "absent mcp server fails loud"
fi
cp "$SRV" "$SBX/acme-from-claude"

printf '== cross-harness round-trip: install foo-kit into codex ==\n'
if sh "$PSH" install --skillset foo-kit --harness codex >/dev/null 2>&1; then
	ok "forward install into codex exits 0"
else
	no "forward install into codex failed"
fi
RENDERED="$CODEX_SKILLS_DIR/foo-task/SKILL.md"
if [ -f "$RENDERED" ]; then ok "skill rendered into codex"; else no "skill not rendered into codex"; fi
if grep -rq '{{' "$CODEX_SKILLS_DIR" 2>/dev/null; then no "placeholders remain in codex render"; else ok "codex render is placeholder-free"; fi
if grep -qF "$CODEX_SKILLS_DIR/foo-kit-shared/CONTRACT.md" "$RENDERED"; then
	ok "shared placeholder resolved to codex path"
else
	no "shared placeholder resolved wrong"
fi
if grep -q '^\[mcp_servers\.acme\]' "$CODEX_CONFIG" && grep -q 'command = "npx"' "$CODEX_CONFIG"; then
	ok "codex config has [mcp_servers.acme] with command"
else
	no "mcp not emitted into codex config"
fi
if sh "$PSH" doctor >/dev/null 2>&1; then ok "doctor clean after round-trip"; else no "doctor not clean"; fi

printf '== reverse-read the codex TOML back (bidirectional fidelity) ==\n'
if python3 -c 'import tomllib' >/dev/null 2>&1; then
	if sh "$PSH" ingest --harness codex --mcp acme --skillset foo-kit2 >/dev/null 2>&1; then
		ok "codex mcp reverse-read exits 0"
	else
		no "codex mcp reverse-read failed"
	fi
	if cmp -s "$SBX/acme-from-claude" "$SRV"; then
		ok "codex-read neutral matches claude-read (full round-trip fidelity)"
	else
		no "codex-read neutral differs from claude-read"
	fi
	if grep -qxF 'mcp: acme' "$REG/skills/foo-kit2/manifest"; then ok "foo-kit2 manifest wired 'mcp: acme'"; else no "foo-kit2 manifest missing mcp line"; fi
else
	skip "tomllib unavailable (Python <3.11) — codex TOML reverse-read not exercised"
fi

rm -rf "$SBX"
printf '\n== ingest test RESULT: pass=%d fail=%d ==\n' "$pass" "$fail"
[ "$fail" = 0 ]
