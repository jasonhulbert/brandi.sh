#!/bin/sh
# tests/e2e.sh — full-lifecycle smoke test for plan.sh in a throwaway HOME.
#
# Exercises: bootstrap install -> plan.sh install (claude + faked codex) ->
# doctor -> placeholder-free skills -> add a new registry skill -> uninstall ->
# bootstrap uninstall -> clean sandbox. Exits non-zero if any check fails.
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
export INSTALL_DIR="$SBX/data"
unset PLAN_SH_SRC PLAN_SH_TARBALL PLAN_SH_TARBALL_URL 2>/dev/null || true
unset CLAUDE_SKILLS_DIR CODEX_SKILLS_DIR CODEX_CONFIG CLAUDE_MCP_CONFIG 2>/dev/null || true

# Both harnesses "present" on this machine (Codex base dir faked).
mkdir -p "$HOME/.claude" "$HOME/.codex"

PSH="$BIN_DIR/plan.sh"

printf '== bootstrap install ==\n'
if sh "$REPO/install.sh" >/dev/null 2>&1; then ok "bootstrap install exits 0"; else no "bootstrap install"; fi
if [ -x "$PSH" ]; then ok "CLI launcher installed"; else no "CLI launcher missing"; fi

printf '== plan.sh install --harness claude,codex ==\n'
if "$PSH" install --harness claude,codex >/dev/null 2>&1; then ok "render install exits 0"; else no "render install"; fi

printf '== plan.sh doctor ==\n'
if "$PSH" doctor >/dev/null 2>&1; then ok "doctor clean (exit 0)"; else no "doctor not clean"; fi

printf '== six placeholder-free SKILL.md per harness ==\n'
for base in "$HOME/.claude/skills" "$HOME/.codex/skills"; do
	c=0
	for s in plan-create plan-phase plan-reflect plan-auto plan-multi plan-task; do
		[ -f "$base/$s/SKILL.md" ] && c=$((c + 1))
	done
	if [ "$c" = 6 ]; then ok "six skills in $base"; else no "only $c/6 in $base"; fi
	if grep -rq '{{' "$base" 2>/dev/null; then no "placeholders remain in $base"; else ok "no placeholders in $base"; fi
done

printf '== add a new dummy registry skill (README spot-check) ==\n'
mkdir -p "$INSTALL_DIR/registry/skills/demo/demo-skill"
printf -- '---\nname: demo-skill\ndescription: demo skill\n---\n# Demo\nContract: {{SHARED_DIR}}/none\n' \
	> "$INSTALL_DIR/registry/skills/demo/demo-skill/SKILL.md"
printf 'skillset: demo\ndescription: demo\nskill: demo-skill\nmcp: none\n' \
	> "$INSTALL_DIR/registry/skills/demo/manifest"
if "$PSH" add demo >/dev/null 2>&1 && [ -f "$HOME/.claude/skills/demo-skill/SKILL.md" ]; then
	ok "newly-added registry skill renders"
else
	no "add of new registry skill failed"
fi
if "$PSH" doctor >/dev/null 2>&1; then ok "doctor clean after add"; else no "doctor not clean after add"; fi

printf '== plan.sh uninstall ==\n'
if "$PSH" uninstall >/dev/null 2>&1; then ok "skill uninstall exits 0"; else no "skill uninstall"; fi
left=$(find "$HOME/.claude/skills" "$HOME/.codex/skills" -name 'SKILL.md' 2>/dev/null | wc -l | tr -d ' ')
if [ "$left" = 0 ]; then ok "no rendered skills remain"; else no "$left rendered skills remain"; fi

printf '== bootstrap uninstall ==\n'
if sh "$REPO/install.sh" --uninstall >/dev/null 2>&1; then ok "bootstrap uninstall exits 0"; else no "bootstrap uninstall"; fi
if [ ! -e "$PSH" ]; then ok "CLI launcher removed"; else no "launcher remains"; fi
if [ ! -d "$INSTALL_DIR" ]; then ok "tool data dir removed"; else no "data dir remains"; fi

rm -rf "$SBX"
printf '\n== e2e RESULT: pass=%d fail=%d ==\n' "$pass" "$fail"
[ "$fail" = 0 ]
