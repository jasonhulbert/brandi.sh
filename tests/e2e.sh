#!/bin/sh
# tests/e2e.sh — full-lifecycle smoke test for brandi.sh in a throwaway HOME.
#
# Exercises the engine/content split and bootstrap data-safety:
#   bootstrap install (engine only; ensures the data-dir registry) -> empty
#   registry fails loud -> seed a fixture skillset -> reinstall does NOT clobber
#   it -> brandi.sh install (claude + faked codex) -> doctor -> placeholder-free
#   skills + shared file -> add a second skillset -> partial uninstall keeps
#   state -> bootstrap uninstall PRESERVES the user data dir -> --purge removes
#   it. Exits non-zero if any check fails.
#
# The registry is user-owned and lives under BRANDI_SH_DATA, deliberately kept
# distinct from the engine (INSTALL_DIR) so the test never relies on bundled
# content — it seeds its own fixtures.
set -u

REPO=$(CDPATH='' cd -- "$(dirname -- "$0")/.." && pwd)

pass=0
fail=0
ok()  { printf '  PASS: %s\n' "$1"; pass=$((pass + 1)); }
no()  { printf '  FAIL: %s\n' "$1"; fail=$((fail + 1)); }

SBX=$(mktemp -d)
HOME="$SBX/home"
export HOME
export XDG_STATE_HOME="$HOME/.local/state"
export XDG_DATA_HOME="$SBX/xdg-data"
export XDG_CONFIG_HOME="$HOME/.config"
export BIN_DIR="$SBX/bin"
export INSTALL_DIR="$SBX/engine"
# User data dir (registry + state + backups) — distinct from the engine root.
export BRANDI_SH_DATA="$SBX/data"
unset BRANDI_SH_SRC BRANDI_SH_TARBALL BRANDI_SH_TARBALL_URL 2>/dev/null || true
unset CLAUDE_SKILLS_DIR CODEX_SKILLS_DIR CODEX_CONFIG CLAUDE_MCP_CONFIG 2>/dev/null || true

# Both harnesses "present" on this machine (Codex base dir faked).
mkdir -p "$HOME/.claude" "$HOME/.codex"

PSH="$BIN_DIR/brandi.sh"
REG="$BRANDI_SH_DATA/registry"
STATE="$BRANDI_SH_DATA/state"

# Seed one canonical skill into the data-dir registry. Args: <skillset> <skill>
seed_skill() {
	mkdir -p "$REG/skills/$1/$2"
	printf -- '---\nname: %s\ndescription: %s fixture skill\n---\n# %s\nContract: {{SHARED_DIR}}/CONTRACT.md\n' \
		"$2" "$2" "$2" > "$REG/skills/$1/$2/SKILL.md"
}

printf '== bootstrap install (engine) ensures the data-dir registry ==\n'
if sh "$REPO/install.sh" >/dev/null 2>&1; then ok "bootstrap install exits 0"; else no "bootstrap install"; fi
if [ -x "$PSH" ]; then ok "CLI launcher installed"; else no "CLI launcher missing"; fi
if [ -d "$REG/skills" ]; then ok "registry/skills ensured"; else no "registry/skills not created"; fi
if [ -d "$REG/mcp" ]; then ok "registry/mcp ensured"; else no "registry/mcp not created"; fi

printf '== install against an empty data-dir registry fails loud ==\n'
if "$PSH" install --harness claude >/dev/null 2>&1; then
	no "empty-registry install should have failed"
else
	ok "empty-registry install fails (non-zero)"
fi

printf '== seed a fixture skillset; reinstall must not clobber it ==\n'
seed_skill kit kit-a
seed_skill kit kit-b
mkdir -p "$REG/skills/kit/shared"
printf 'Kit shared contract.\n' > "$REG/skills/kit/shared/CONTRACT.md"
printf 'skillset: kit\ndescription: fixture kit\nskill: kit-a\nskill: kit-b\nshared: shared/CONTRACT.md\nmcp: none\n' \
	> "$REG/skills/kit/manifest"
sh "$REPO/install.sh" >/dev/null 2>&1
if [ -f "$REG/skills/kit/manifest" ] && [ -f "$REG/skills/kit/kit-a/SKILL.md" ]; then
	ok "reinstall preserved the seeded skillset"
else
	no "reinstall clobbered user registry content"
fi

printf '== brandi.sh install --harness claude,codex ==\n'
if "$PSH" install --harness claude,codex >/dev/null 2>&1; then ok "render install exits 0"; else no "render install"; fi

printf '== brandi.sh doctor ==\n'
if "$PSH" doctor >/dev/null 2>&1; then ok "doctor clean (exit 0)"; else no "doctor not clean"; fi

printf '== placeholder-free skills + shared file per harness ==\n'
for base in "$HOME/.claude/skills" "$HOME/.codex/skills"; do
	c=0
	for s in kit-a kit-b; do
		[ -f "$base/$s/SKILL.md" ] && c=$((c + 1))
	done
	if [ "$c" = 2 ]; then ok "two skills in $base"; else no "only $c/2 in $base"; fi
	if [ -f "$base/kit-shared/CONTRACT.md" ]; then ok "shared file in $base"; else no "shared file missing in $base"; fi
	if grep -rq '{{' "$base" 2>/dev/null; then no "placeholders remain in $base"; else ok "no placeholders in $base"; fi
done

printf '== add a second seeded skillset ==\n'
seed_skill kit2 kit2-a
printf 'skillset: kit2\ndescription: fixture kit2\nskill: kit2-a\nmcp: none\n' \
	> "$REG/skills/kit2/manifest"
if "$PSH" add kit2 >/dev/null 2>&1 && [ -f "$HOME/.claude/skills/kit2-a/SKILL.md" ]; then
	ok "newly-added registry skillset renders"
else
	no "add of new registry skillset failed"
fi
if "$PSH" doctor >/dev/null 2>&1; then ok "doctor clean after add"; else no "doctor not clean after add"; fi

printf '== partial uninstall (codex) keeps claude + state ==\n'
"$PSH" uninstall --harness codex >/dev/null 2>&1
cleft=$(find "$HOME/.codex/skills" -name 'SKILL.md' 2>/dev/null | wc -l | tr -d ' ')
if [ "$cleft" = 0 ]; then ok "codex rendered skills removed"; else no "$cleft codex skills remain"; fi
if [ -f "$HOME/.claude/skills/kit-a/SKILL.md" ]; then ok "claude rendered skills remain"; else no "claude skills wrongly removed"; fi
if [ -f "$STATE" ]; then ok "state file persists (claude still installed)"; else no "state file wrongly removed"; fi

printf '== bootstrap uninstall PRESERVES the user data dir ==\n'
if sh "$REPO/install.sh" --uninstall >/dev/null 2>&1; then ok "bootstrap uninstall exits 0"; else no "bootstrap uninstall"; fi
if [ ! -e "$PSH" ]; then ok "CLI launcher removed"; else no "launcher remains"; fi
if [ ! -d "$INSTALL_DIR" ]; then ok "engine dir removed"; else no "engine dir remains"; fi
if [ -f "$REG/skills/kit/manifest" ] && [ -f "$REG/skills/kit2/manifest" ]; then
	ok "user registry preserved"
else
	no "user registry destroyed by bootstrap uninstall"
fi
if [ -f "$STATE" ]; then ok "user state preserved"; else no "user state destroyed by bootstrap uninstall"; fi

printf '== --purge opt-in removes the user data dir ==\n'
sh "$REPO/install.sh" >/dev/null 2>&1
sh "$REPO/install.sh" --uninstall --purge >/dev/null 2>&1
if [ ! -e "$REG/skills/kit/manifest" ]; then ok "registry removed by --purge"; else no "registry survived --purge"; fi
if [ ! -e "$STATE" ]; then ok "state removed by --purge"; else no "state survived --purge"; fi

rm -rf "$SBX"
printf '\n== e2e RESULT: pass=%d fail=%d ==\n' "$pass" "$fail"
[ "$fail" = 0 ]
