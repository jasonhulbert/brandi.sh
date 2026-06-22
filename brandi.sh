#!/bin/sh
# brandi.sh — multi-harness Agent Skills & MCP installer.
#
# Canonical registry + thin per-harness adapters (the shadcn / ui.sh model).
# This file is the CLI entrypoint. See registry/FORMAT.md for the contract.
#
# brandi.sh only copies files and substitutes placeholders. All judgment lives in
# the skill markdown, never in shell.
set -eu

PROG=brandi.sh
VERSION=0.2.0-dev
TAB=$(printf '\t')

# Render-control globals (set/cleared around render calls; declared for set -u).
RENDER_RECORD=''       # if non-empty, a file to append state records to
RENDER_OUT_SKILLS=''   # if non-empty, output skills root (placeholder resolution stays real)
RENDER_OUT_SHARED=''   # if non-empty, output shared root
RENDER_QUIET=''        # if non-empty, suppress per-render summary
RENDER_MANAGED=''      # if non-empty, a file listing dests we already own (skip backup)
RUN_TS=''              # backup timestamp for the current render run

# --- fail loud (global Rule 12) -------------------------------------------

die() {
	printf '%s: %s\n' "$PROG" "$*" >&2
	exit 1
}

# --- root / state resolution ----------------------------------------------

# Absolute path of the ENGINE root (adapters/ + the brandi.sh script; the user
# registry lives under data_dir, not here). BRANDI_SH_ROOT wins; otherwise the
# directory containing this script — correct both in-repo and when the bootstrap
# installs the whole tree together.
brandi_sh_root() {
	if [ -n "${BRANDI_SH_ROOT:-}" ]; then
		printf '%s\n' "$BRANDI_SH_ROOT"
		return 0
	fi
	CDPATH='' cd -- "$(dirname -- "$0")" && pwd
}

# Absolute path of the user DATA dir: the registry (user content), the state
# record, and backups/ all live here. Deliberately separate from the engine root
# (brandi_sh_root) so the tool no longer ships the registry. BRANDI_SH_DATA
# overrides (tests/dev); else $XDG_DATA_HOME/brandi.sh (~/.local/share/brandi.sh).
data_dir() {
	if [ -n "${BRANDI_SH_DATA:-}" ]; then
		printf '%s\n' "$BRANDI_SH_DATA"
		return 0
	fi
	printf '%s/brandi.sh\n' "${XDG_DATA_HOME:-$HOME/.local/share}"
}

# State record + backups live under the data dir (single-data-dir design), not a
# separate XDG_STATE_HOME location.
state_dir() {
	data_dir
}

state_file() {
	printf '%s/state\n' "$(state_dir)"
}

# sha256 of a file, using whatever hashing tool is available.
sha256_of() {
	if command -v sha256sum >/dev/null 2>&1; then
		sha256sum "$1" | awk '{print $1}'
	elif command -v shasum >/dev/null 2>&1; then
		shasum -a 256 "$1" | awk '{print $1}'
	elif command -v openssl >/dev/null 2>&1; then
		openssl dgst -sha256 "$1" | awk '{print $NF}'
	else
		die "no sha256 tool found (need sha256sum, shasum, or openssl)"
	fi
}

# --- placeholder substitution ---------------------------------------------

# Escape a string for safe use as a sed replacement with '|' as delimiter.
sed_escape_repl() {
	printf '%s' "$1" | sed 's/[\\&|]/\\&/g'
}

# Escape a string for safe use as a BRE sed *pattern* with '|' as delimiter.
# Used by ingest to re-tokenize literal harness paths back into placeholders.
# (Backslashes are not escaped — absolute home paths never contain them.)
sed_escape_pat() {
	printf '%s' "$1" | sed 's/[].[*^$|]/\\&/g'
}

# Resolve placeholders on stdin -> stdout.  Args: <shared_dir> <skills_dir>
resolve_placeholders() {
	_sd=$(sed_escape_repl "$1")
	_kd=$(sed_escape_repl "$2")
	sed -e "s|{{SHARED_DIR}}|${_sd}|g" \
		-e "s|{{SKILLS_DIR}}|${_kd}|g" \
		-e 's|{{INVOKE:\([^}]*\)}}|\1|g'
}

# --- rendering -------------------------------------------------------------

# Render one file: substitute placeholders (against the real shared/skills
# dirs), optionally rewrite the frontmatter key, then write to dest. Backs up a
# pre-existing, differing dest before overwriting; a byte-identical dest is left
# untouched (idempotent, no backup).
# Args: <src> <dest> <shared_dir> <skills_dir> <fm_key> <harness>
render_file() {
	_src=$1; _dest=$2; _shared=$3; _skills=$4; _fmkey=$5; _harness=$6
	_tmp=$(mktemp) || die "mktemp failed"

	resolve_placeholders "$_shared" "$_skills" < "$_src" > "$_tmp"

	# Future-harness hook: rewrite the canonical 'name:' frontmatter key if the
	# harness expects a different one. v1 harnesses all use 'name' (no-op).
	if [ "$_fmkey" != name ]; then
		_tmp2=$(mktemp) || die "mktemp failed"
		awk -v k="$_fmkey" '
			/^---$/ { f++ }
			f<=1 && !done && /^name:/ { sub(/^name:/, k":"); done=1 }
			{ print }
		' "$_tmp" > "$_tmp2"
		mv "$_tmp2" "$_tmp"
	fi

	# Fail loud if any placeholder survived.
	if grep -q '{{' "$_tmp"; then
		rm -f "$_tmp"
		die "unresolved placeholder while rendering ${_src##*/} -> $_dest"
	fi

	if [ -f "$_dest" ]; then
		if cmp -s "$_tmp" "$_dest"; then
			rm -f "$_tmp"          # identical: idempotent no-op
			return 0
		fi
		# Back up only a file we did NOT create (a pre-install foreign file).
		# Files we already own (recorded in state) are simply updated — backing
		# them up would later let uninstall "restore" stale content. Keyed by
		# absolute path (leading slash stripped) so restore needs no adapter.
		if ! _is_managed "$_dest"; then
			_bak="$(state_dir)/backups/$RUN_TS/$_harness/${_dest#/}"
			mkdir -p "$(dirname -- "$_bak")"
			cp "$_dest" "$_bak"
		fi
	fi
	mkdir -p "$(dirname -- "$_dest")"
	mv "$_tmp" "$_dest"
}

# True (0) if a dest is one we already own (listed in RENDER_MANAGED).
_is_managed() {
	[ -n "$RENDER_MANAGED" ] || return 1
	grep -qxF "$1" "$RENDER_MANAGED"
}

# Append a state record for a rendered file (only if RENDER_RECORD is set).
# Args: <harness> <skillset> <item> <dest>
_record() {
	[ -n "$RENDER_RECORD" ] || return 0
	printf '%s\t%s\t%s\t%s\t%s\n' "$1" "$2" "$3" "$4" "$(sha256_of "$4")" >> "$RENDER_RECORD"
}

# Render a whole skillset into a harness. Args: <skillset> <harness>
# Placeholders resolve against the harness's real dirs; output goes to the real
# dirs unless RENDER_OUT_SKILLS/RENDER_OUT_SHARED override (used by doctor).
render_skillset() {
	_skillset=$1; _harness=$2
	_root=$(brandi_sh_root)
	_data=$(data_dir)

	_adapter="$_root/adapters/$_harness.sh"
	[ -f "$_adapter" ] || die "unknown harness '$_harness' (no adapter at $_adapter)"
	# shellcheck disable=SC1090
	. "$_adapter"
	[ "${ADAPTER_NAME:-}" = "$_harness" ] || \
		die "adapter $_adapter declares ADAPTER_NAME='${ADAPTER_NAME:-}', expected '$_harness'"

	_setdir="$_data/registry/skills/$_skillset"
	_manifest="$_setdir/manifest"
	[ -f "$_manifest" ] || die "unknown skillset '$_skillset' (no manifest at $_manifest)"

	# Adapters fail loud (non-zero) if they cannot locate their dir.
	_skills=$(adapter_skills_dir)
	_shared=$(adapter_shared_dir "$_skillset")
	_fmkey=$(adapter_frontmatter_key)

	_oskills=${RENDER_OUT_SKILLS:-$_skills}
	_oshared=${RENDER_OUT_SHARED:-$_shared}

	# One backup directory per render run (lazily populated by render_file).
	RUN_TS=$(date -u +%Y%m%dT%H%M%SZ)
	mkdir -p "$_oskills" "$_oshared"

	_count=0
	while IFS= read -r _line <&3; do
		case "$_line" in ''|\#*) continue ;; esac
		_key=${_line%%:*}
		_val=${_line#*:}; _val=${_val# }
		case "$_key" in
			skill)
				_srcdir="$_setdir/$_val"
				[ -d "$_srcdir" ] || die "skill directory missing: $_srcdir"
				_list=$(mktemp) || die "mktemp failed"
				find "$_srcdir" -type f > "$_list"
				while IFS= read -r _srcf <&4; do
					_rel=${_srcf#"$_srcdir"/}
					_dest="$_oskills/$_val/$_rel"
					render_file "$_srcf" "$_dest" "$_shared" "$_skills" "$_fmkey" "$_harness"
					_record "$_harness" "$_skillset" "$_val" "$_dest"
				done 4< "$_list"
				rm -f "$_list"
				_count=$((_count + 1))
				;;
			shared)
				_srcf="$_setdir/$_val"
				[ -f "$_srcf" ] || die "shared file missing: $_srcf"
				_dest="$_oshared/${_val##*/}"
				render_file "$_srcf" "$_dest" "$_shared" "$_skills" "$_fmkey" "$_harness"
				_record "$_harness" "$_skillset" "shared" "$_dest"
				;;
			mcp)
				: # MCP needs are handled in Phase 6.
				;;
		esac
	done 3< "$_manifest"

	[ -n "$RENDER_QUIET" ] || printf '%s: rendered skillset "%s" (%d skills) into %s\n' \
		"$PROG" "$_skillset" "$_count" "$_oskills"
}

# Render a (harness, skillset) into the real dirs and update the state file:
# fresh records replace the pair's old records, and any previously-recorded file
# the registry no longer renders (an orphan) is removed.
render_and_record() {
	_h=$1; _s=$2
	_sf=$(state_file)
	_newrec=$(mktemp) || die "mktemp failed"

	# Files we already own (so render_file won't back them up as if foreign).
	_managed=$(mktemp)
	[ -f "$_sf" ] && awk -F'\t' '{print $4}' "$_sf" > "$_managed" || :

	RENDER_RECORD="$_newrec"
	RENDER_MANAGED="$_managed"
	RENDER_QUIET=1
	render_skillset "$_s" "$_h"
	RENDER_RECORD=''
	RENDER_MANAGED=''
	RENDER_QUIET=''
	rm -f "$_managed"

	if [ -f "$_sf" ]; then
		_newd=$(mktemp); awk -F'\t' '{print $4}' "$_newrec" > "$_newd"
		_oldd=$(mktemp); awk -F'\t' -v h="$_h" -v s="$_s" '$1==h && $2==s {print $4}' "$_sf" > "$_oldd"
		while IFS= read -r _od <&5; do
			if ! grep -qxF "$_od" "$_newd"; then
				rm -f "$_od"
				rmdir "$(dirname -- "$_od")" 2>/dev/null || true
			fi
		done 5< "$_oldd"
		rm -f "$_newd" "$_oldd"
	fi

	_merged=$(mktemp)
	if [ -f "$_sf" ]; then
		awk -F'\t' -v h="$_h" -v s="$_s" '!($1==h && $2==s)' "$_sf" > "$_merged"
	fi
	cat "$_newrec" >> "$_merged"
	rm -f "$_newrec"
	mkdir -p "$(dirname -- "$_sf")"
	mv "$_merged" "$_sf"

	# Emit any MCP servers this skillset declares (adapter already sourced by
	# render_skillset). Kept out of render_skillset so doctor's temp re-render
	# never touches the real MCP config.
	_emit_mcp "$_h" "$_s"
}

# --- MCP emitters ----------------------------------------------------------

# Echo values for a key in a neutral MCP server file. Args: <serverfile> <key>
mcp_field() {
	[ -f "$1" ] || return 0
	while IFS= read -r _ln; do
		case "$_ln" in ''|\#*) continue ;; esac
		_k=${_ln%%:*}
		_v=${_ln#*:}; _v=${_v# }
		[ "$_k" = "$2" ] && printf '%s\n' "$_v"
	done < "$1"
	return 0
}

# Emit a TOML basic-string literal for $1 (escaping backslash and double-quote).
toml_str() {
	printf '"%s"' "$(printf '%s' "$1" | sed 's/\\/\\\\/g; s/"/\\"/g')"
}

# Merge one neutral MCP server into a Claude JSON config under mcpServers,
# preserving unrelated servers and top-level keys. Args: <serverfile> <target>
mcp_emit_claude() {
	_srv=$1; _tgt=$2
	command -v python3 >/dev/null 2>&1 || \
		die "MCP emit for Claude needs python3 to merge JSON safely (none found)"
	_name=$(mcp_field "$_srv" name)
	[ -n "$_name" ] || die "mcp server $_srv has no 'name'"
	mkdir -p "$(dirname -- "$_tgt")"
	BRANDISH_TGT="$_tgt" \
	BRANDISH_NAME="$_name" \
	BRANDISH_CMD="$(mcp_field "$_srv" command)" \
	BRANDISH_URL="$(mcp_field "$_srv" url)" \
	BRANDISH_ARGS="$(mcp_field "$_srv" arg)" \
	BRANDISH_ENV="$(mcp_field "$_srv" env)" \
	python3 - <<'PY'
import json, os, sys
tgt = os.environ["BRANDISH_TGT"]
name = os.environ["BRANDISH_NAME"]
cmd = os.environ.get("BRANDISH_CMD", "")
url = os.environ.get("BRANDISH_URL", "")
args = [a for a in os.environ.get("BRANDISH_ARGS", "").split("\n") if a]
env = {}
for e in [x for x in os.environ.get("BRANDISH_ENV", "").split("\n") if x]:
    k, _, v = e.partition("=")
    env[k] = v
obj = {}
if cmd:
    obj["command"] = cmd
    if args:
        obj["args"] = args
    if env:
        obj["env"] = env
elif url:
    obj["url"] = url
else:
    sys.exit("mcp server '%s' has neither command nor url" % name)
data = {}
try:
    with open(tgt) as f:
        txt = f.read().strip()
        if txt:
            data = json.loads(txt)
except FileNotFoundError:
    data = {}
if not isinstance(data, dict):
    sys.exit("existing %s is not a JSON object" % tgt)
data.setdefault("mcpServers", {})[name] = obj
tmp = tgt + ".brandish.tmp"
with open(tmp, "w") as f:
    json.dump(data, f, indent=2)
    f.write("\n")
os.replace(tmp, tgt)
PY
}

# Merge one neutral MCP server into a Codex TOML config as [mcp_servers.<name>],
# preserving unrelated tables (text-level replace-or-append, no TOML round-trip).
# Args: <serverfile> <target>
mcp_emit_codex() {
	_srv=$1; _tgt=$2
	_name=$(mcp_field "$_srv" name)
	[ -n "$_name" ] || die "mcp server $_srv has no 'name'"
	_cmd=$(mcp_field "$_srv" command)
	_url=$(mcp_field "$_srv" url)
	if [ -z "$_cmd" ] && [ -z "$_url" ]; then
		die "mcp server $_srv has neither command nor url"
	fi

	_block=$(mktemp)
	{
		printf '[mcp_servers.%s]\n' "$_name"
		if [ -n "$_cmd" ]; then
			printf 'command = %s\n' "$(toml_str "$_cmd")"
			_args=$(mcp_field "$_srv" arg)
			if [ -n "$_args" ]; then
				printf 'args = ['
				_first=1
				printf '%s\n' "$_args" | while IFS= read -r _a; do
					[ -n "$_a" ] || continue
					if [ "$_first" = 1 ]; then _first=0; else printf ', '; fi
					printf '%s' "$(toml_str "$_a")"
				done
				printf ']\n'
			fi
			_env=$(mcp_field "$_srv" env)
			if [ -n "$_env" ]; then
				printf 'env = { '
				_first=1
				printf '%s\n' "$_env" | while IFS= read -r _e; do
					[ -n "$_e" ] || continue
					_ek=${_e%%=*}; _ev=${_e#*=}
					if [ "$_first" = 1 ]; then _first=0; else printf ', '; fi
					printf '%s = %s' "$_ek" "$(toml_str "$_ev")"
				done
				printf ' }\n'
			fi
		else
			printf 'url = %s\n' "$(toml_str "$_url")"
		fi
	} > "$_block"

	mkdir -p "$(dirname -- "$_tgt")"
	if [ -f "$_tgt" ] && grep -q "^\[mcp_servers\.${_name}\]" "$_tgt"; then
		_merged=$(mktemp)
		awk -v hdr="[mcp_servers.${_name}]" -v blk="$_block" '
			function emitblk(   l) { while ((getline l < blk) > 0) print l; close(blk) }
			$0 == hdr { inblk = 1; emitblk(); next }
			inblk == 1 && /^\[/ { inblk = 0 }
			inblk == 1 { next }
			{ print }
		' "$_tgt" > "$_merged"
		mv "$_merged" "$_tgt"
	else
		[ -s "$_tgt" ] && printf '\n' >> "$_tgt"
		cat "$_block" >> "$_tgt"
	fi
	rm -f "$_block"
}

# Read one MCP server from a Claude JSON config, emitting the neutral registry
# format (FORMAT.md §7) to stdout; exits non-zero if the server is absent. The
# reverse of mcp_emit_claude. Args: <name> <config>
mcp_read_claude() {
	BRANDISH_NAME="$1" BRANDISH_CFG="$2" python3 - <<'PY'
import json, os, sys
name = os.environ["BRANDISH_NAME"]
cfg = os.environ["BRANDISH_CFG"]
try:
    with open(cfg) as f:
        data = json.load(f)
except Exception as e:
    sys.exit("ingest: cannot parse %s: %s" % (cfg, e))
servers = data.get("mcpServers", {}) if isinstance(data, dict) else {}
srv = servers.get(name)
if not isinstance(srv, dict):
    sys.exit("ingest: mcp server '%s' not found in %s" % (name, cfg))
out = ["name: " + name]
if "command" in srv:
    out.append("command: " + str(srv["command"]))
    for a in srv.get("args", []) or []:
        out.append("arg: " + str(a))
    for k, v in (srv.get("env", {}) or {}).items():
        out.append("env: %s=%s" % (k, v))
elif "url" in srv:
    out.append("url: " + str(srv["url"]))
else:
    sys.exit("ingest: mcp server '%s' has neither command nor url" % name)
sys.stdout.write("\n".join(out) + "\n")
PY
}

# Read one MCP server from a Codex TOML config, emitting the neutral registry
# format (FORMAT.md §7) to stdout; exits non-zero if absent. Needs Python >=3.11
# (tomllib) per the plan's scoping decision. The reverse of mcp_emit_codex.
# Args: <name> <config>
mcp_read_codex() {
	BRANDISH_NAME="$1" BRANDISH_CFG="$2" python3 - <<'PY'
import os, sys
try:
    import tomllib
except ModuleNotFoundError:
    sys.exit("ingest: reading Codex TOML needs Python >=3.11 (tomllib unavailable)")
name = os.environ["BRANDISH_NAME"]
cfg = os.environ["BRANDISH_CFG"]
try:
    with open(cfg, "rb") as f:
        data = tomllib.load(f)
except Exception as e:
    sys.exit("ingest: cannot parse %s: %s" % (cfg, e))
srv = data.get("mcp_servers", {}).get(name)
if not isinstance(srv, dict):
    sys.exit("ingest: mcp server '%s' not found in %s" % (name, cfg))
out = ["name: " + name]
if "command" in srv:
    out.append("command: " + str(srv["command"]))
    for a in srv.get("args", []) or []:
        out.append("arg: " + str(a))
    for k, v in (srv.get("env", {}) or {}).items():
        out.append("env: %s=%s" % (k, v))
elif "url" in srv:
    out.append("url: " + str(srv["url"]))
else:
    sys.exit("ingest: mcp server '%s' has neither command nor url" % name)
sys.stdout.write("\n".join(out) + "\n")
PY
}

# Emit every MCP server a skillset declares. Args: <harness> <skillset>
# (the harness adapter must already be sourced).
_emit_mcp() {
	_data=$(data_dir)
	_servers=$(mktemp)
	manifest_field "$2" mcp > "$_servers"
	while IFS= read -r _srv <&5; do
		case "$_srv" in ''|none) continue ;; esac
		_srvfile="$_data/registry/mcp/$_srv"
		[ -f "$_srvfile" ] || die "skillset '$2' declares mcp '$_srv' but registry/mcp/$_srv is missing"
		adapter_mcp_emit "$_srvfile"
		printf '%s: emitted MCP server "%s" for harness "%s"\n' "$PROG" "$_srv" "$1"
	done 5< "$_servers"
	rm -f "$_servers"
}

# --- registry / harness / state helpers -----------------------------------

list_skillsets() {
	_data=$(data_dir)
	[ -d "$_data/registry/skills" ] || return 0
	for _d in "$_data"/registry/skills/*/; do
		[ -f "${_d}manifest" ] || continue
		_b=${_d%/}
		printf '%s\n' "${_b##*/}"
	done
	return 0
}

# Echo values for a manifest key. Args: <skillset> <key>
manifest_field() {
	_data=$(data_dir)
	_m="$_data/registry/skills/$1/manifest"
	[ -f "$_m" ] || return 0
	while IFS= read -r _ln; do
		case "$_ln" in ''|\#*) continue ;; esac
		_k=${_ln%%:*}
		_v=${_ln#*:}; _v=${_v# }
		[ "$_k" = "$2" ] && printf '%s\n' "$_v"
	done < "$_m"
	return 0
}

list_adapters() {
	_root=$(brandi_sh_root)
	for _f in "$_root"/adapters/*.sh; do
		[ -f "$_f" ] || continue
		_b=${_f##*/}
		printf '%s\n' "${_b%.sh}"
	done
	return 0
}

# True (0) if the harness appears installed on this machine.
harness_detected() {
	_root=$(brandi_sh_root)
	_a="$_root/adapters/$1.sh"
	[ -f "$_a" ] || return 1
	# shellcheck disable=SC1090
	( . "$_a"; adapter_detect ) >/dev/null 2>&1
}

detect_harnesses() {
	list_adapters | while IFS= read -r _h; do
		if harness_detected "$_h"; then printf '%s\n' "$_h"; fi
	done
	return 0
}

state_harnesses() {
	_sf=$(state_file)
	[ -f "$_sf" ] || return 0
	awk -F'\t' '{print $1}' "$_sf" | sort -u
	return 0
}

# Split a comma list into one item per line, trimmed, no blanks.
_split_csv() {
	printf '%s' "$1" | tr ',' '\n' | sed 's/^[[:space:]]*//;s/[[:space:]]*$//' | grep -v '^$' || true
}

has_glob_chars() {
	case "$1" in
		*'*'*|*'?'*|*'['*) return 0 ;;
		*) return 1 ;;
	esac
}

# --- subcommands -----------------------------------------------------------

cmd_install() {
	_harg=''; _sarg=''
	while [ "$#" -gt 0 ]; do
		case "$1" in
			--harness) [ "$#" -ge 2 ] || die "install: --harness needs a value"; _harg=$2; shift 2 ;;
			--harness=*) _harg=${1#*=}; shift ;;
			--skillset) [ "$#" -ge 2 ] || die "install: --skillset needs a value"; _sarg=$2; shift 2 ;;
			--skillset=*) _sarg=${1#*=}; shift ;;
			-h|--help) printf 'usage: %s install [--harness a,b] [--skillset x,y]\n' "$PROG"; return 0 ;;
			*) die "install: unknown option '$1'" ;;
		esac
	done
	_root=$(brandi_sh_root)
	_data=$(data_dir)

	_ss=$(mktemp)
	if [ -n "$_sarg" ]; then _split_csv "$_sarg" > "$_ss"; else list_skillsets > "$_ss"; fi
	[ -s "$_ss" ] || { rm -f "$_ss"; die "no skillsets to install (registry is empty)"; }
	while IFS= read -r _s <&6; do
		[ -f "$_data/registry/skills/$_s/manifest" ] || die "no such skillset '$_s'"
	done 6< "$_ss"

	_hs=$(mktemp)
	if [ -n "$_harg" ]; then _split_csv "$_harg" > "$_hs"; else detect_harnesses > "$_hs"; fi
	if [ ! -s "$_hs" ]; then
		rm -f "$_ss" "$_hs"
		die "no harness detected; pass --harness (available: $(list_adapters | tr '\n' ',' | sed 's/,$//'))"
	fi
	while IFS= read -r _h <&6; do
		[ -f "$_root/adapters/$_h.sh" ] || die "no adapter for harness '$_h'"
	done 6< "$_hs"

	_n=0
	while IFS= read -r _h <&6; do
		while IFS= read -r _s <&7; do
			render_and_record "$_h" "$_s"
			printf '%s: installed skillset "%s" into harness "%s"\n' "$PROG" "$_s" "$_h"
			_n=$((_n + 1))
		done 7< "$_ss"
	done 6< "$_hs"
	rm -f "$_ss" "$_hs"
	printf '%s: install complete (%d skillset/harness pair[s]); state: %s\n' \
		"$PROG" "$_n" "$(state_file)"
}

cmd_list() {
	_sf=$(state_file)
	_any=0
	printf '%s: registry skillsets\n' "$PROG"
	list_skillsets | while IFS= read -r _s; do
		_any=1
		_desc=$(manifest_field "$_s" description)
		_skills=$(manifest_field "$_s" skill | tr '\n' ',' | sed 's/,$//;s/,/, /g')
		if [ -f "$_sf" ]; then
			_inst=$(awk -F'\t' -v s="$_s" '$2==s {print $1}' "$_sf" | sort -u | tr '\n' ',' | sed 's/,$//;s/,/, /g')
		else
			_inst=''
		fi
		[ -n "$_inst" ] || _inst='(none)'
		printf '  %s — %s\n' "$_s" "${_desc:-(no description)}"
		printf '    skills: %s\n' "$_skills"
		printf '    installed into: %s\n' "$_inst"
	done
	if [ "$(list_skillsets | wc -l | tr -d ' ')" = 0 ]; then
		printf '  (registry has no skillsets)\n'
	fi
}

cmd_add() {
	[ "$#" -ge 1 ] || die "usage: $PROG add <skillset>"
	_s=$1
	_data=$(data_dir)
	[ -f "$_data/registry/skills/$_s/manifest" ] || die "no such skillset '$_s'"
	_sf=$(state_file)
	[ -f "$_sf" ] || die "nothing installed yet; run '$PROG install' first"
	_hs=$(mktemp); state_harnesses > "$_hs"
	[ -s "$_hs" ] || { rm -f "$_hs"; die "no harnesses recorded in state"; }
	while IFS= read -r _h <&6; do
		render_and_record "$_h" "$_s"
		printf '%s: added skillset "%s" into harness "%s"\n' "$PROG" "$_s" "$_h"
	done 6< "$_hs"
	rm -f "$_hs"
}

cmd_sync() {
	_sf=$(state_file)
	if [ ! -f "$_sf" ]; then printf '%s: sync: nothing installed.\n' "$PROG"; return 0; fi
	_pairs=$(mktemp); awk -F'\t' '{print $1"\t"$2}' "$_sf" | sort -u > "$_pairs"
	while IFS="$TAB" read -r _h _s <&6; do
		render_and_record "$_h" "$_s"
		printf '%s: synced skillset "%s" -> harness "%s"\n' "$PROG" "$_s" "$_h"
	done 6< "$_pairs"
	rm -f "$_pairs"
}

cmd_doctor() {
	_sf=$(state_file)
	_root=$(brandi_sh_root)
	if [ ! -f "$_sf" ]; then printf '%s: doctor: nothing installed (no state). clean.\n' "$PROG"; return 0; fi

	_pairs=$(mktemp); awk -F'\t' '{print $1"\t"$2}' "$_sf" | sort -u > "$_pairs"
	_issues=$(mktemp); : > "$_issues"

	while IFS="$TAB" read -r _h _s <&6; do
		_adapter="$_root/adapters/$_h.sh"
		if [ ! -f "$_adapter" ]; then
			printf 'missing adapter for harness %s\n' "$_h" >> "$_issues"; continue
		fi
		# shellcheck disable=SC1090
		if ! _real_skills=$( . "$_adapter"; adapter_skills_dir 2>/dev/null ); then
			printf 'harness %s: skills directory not found\n' "$_h" >> "$_issues"; continue
		fi
		# shellcheck disable=SC1090
		_real_shared=$( . "$_adapter"; adapter_shared_dir "$_s" )

		_ddir=$(mktemp -d)
		RENDER_OUT_SKILLS="$_ddir/skills"; RENDER_OUT_SHARED="$_ddir/shared"
		RENDER_QUIET=1; RENDER_RECORD=''
		render_skillset "$_s" "$_h"
		RENDER_OUT_SKILLS=''; RENDER_OUT_SHARED=''; RENDER_QUIET=''

		# Expected = freshly rendered temp files mapped to their real path.
		_exp=$(mktemp)
		find "$_ddir/skills" -type f 2>/dev/null | while IFS= read -r _tf; do
			printf '%s\t%s/%s\n' "$_tf" "$_real_skills" "${_tf#"$_ddir"/skills/}"
		done >> "$_exp"
		find "$_ddir/shared" -type f 2>/dev/null | while IFS= read -r _tf; do
			printf '%s\t%s/%s\n' "$_tf" "$_real_shared" "${_tf#"$_ddir"/shared/}"
		done >> "$_exp"

		while IFS="$TAB" read -r _tf _rf <&7; do
			if [ ! -f "$_rf" ]; then
				printf 'missing (registry would render): %s\n' "$_rf" >> "$_issues"
			elif ! cmp -s "$_tf" "$_rf"; then
				printf 'modified/drift: %s\n' "$_rf" >> "$_issues"
			fi
		done 7< "$_exp"

		# Orphans: recorded dests the registry no longer renders.
		_expreal=$(mktemp); awk -F'\t' '{print $2}' "$_exp" > "$_expreal"
		awk -F'\t' -v h="$_h" -v s="$_s" '$1==h && $2==s {print $4}' "$_sf" > "$_ddir/recorded"
		while IFS= read -r _rd <&8; do
			if ! grep -qxF "$_rd" "$_expreal"; then
				[ -e "$_rd" ] && printf 'orphan (installed, not in registry): %s\n' "$_rd" >> "$_issues"
			fi
		done 8< "$_ddir/recorded"

		rm -rf "$_ddir"; rm -f "$_exp" "$_expreal"
	done 6< "$_pairs"
	rm -f "$_pairs"

	if [ -s "$_issues" ]; then
		printf '%s: doctor found drift/issues:\n' "$PROG" >&2
		sed 's/^/  - /' "$_issues" >&2
		rm -f "$_issues"
		return 1
	fi
	rm -f "$_issues"
	printf '%s: doctor: clean (all installed outputs match the registry)\n' "$PROG"
}

cmd_uninstall() {
	_harg=''
	while [ "$#" -gt 0 ]; do
		case "$1" in
			--harness) [ "$#" -ge 2 ] || die "uninstall: --harness needs a value"; _harg=$2; shift 2 ;;
			--harness=*) _harg=${1#*=}; shift ;;
			-h|--help) printf 'usage: %s uninstall [--harness a,b]\n' "$PROG"; return 0 ;;
			*) die "uninstall: unknown option '$1'" ;;
		esac
	done
	_sf=$(state_file)
	if [ ! -f "$_sf" ]; then printf '%s: uninstall: nothing installed.\n' "$PROG"; return 0; fi

	_targets=$(mktemp)
	if [ -n "$_harg" ]; then _split_csv "$_harg" > "$_targets"; else state_harnesses > "$_targets"; fi

	_bakroot="$(state_dir)/backups"
	_dirs=$(mktemp); : > "$_dirs"
	_removed=0; _restored=0
	_recs=$(mktemp)
	while IFS= read -r _h <&6; do
		awk -F'\t' -v h="$_h" '$1==h {print $4}' "$_sf" > "$_recs"
		while IFS= read -r _dest <&7; do
			_bak=$(find "$_bakroot" -type f -path "*/$_h/${_dest#/}" 2>/dev/null | sort | tail -1)
			if [ -n "$_bak" ] && [ -f "$_bak" ]; then
				cp "$_bak" "$_dest"; _restored=$((_restored + 1))
			else
				rm -f "$_dest"; _removed=$((_removed + 1))
			fi
			printf '%s\n' "$(dirname -- "$_dest")" >> "$_dirs"
		done 7< "$_recs"
	done 6< "$_targets"
	rm -f "$_recs"

	# Remove now-empty directories we created (deepest first); rmdir is a no-op
	# on non-empty dirs, so unrelated content is never touched.
	sort -u "$_dirs" | sort -r | while IFS= read -r _d; do rmdir "$_d" 2>/dev/null || true; done
	rm -f "$_dirs"

	_merged=$(mktemp)
	awk -F'\t' 'NR==FNR{t[$0]=1; next} !($1 in t)' "$_targets" "$_sf" > "$_merged"
	rm -f "$_targets"
	if [ -s "$_merged" ]; then mv "$_merged" "$_sf"; else rm -f "$_merged" "$_sf"; fi

	printf '%s: uninstall complete (removed %d, restored %d).\n' "$PROG" "$_removed" "$_restored"
}

# --- ingest (reverse render) ----------------------------------------------

# Reverse-render one file from a harness install back into canonical form:
# re-tokenize the harness's shared/skills absolute paths into placeholders
# (best-effort; an unmatched path is copied verbatim) and normalize the
# frontmatter key skill_name: -> name:. Args: <src> <dst> <shared_dir> <skills_dir>
reverse_render_file() {
	_src=$1; _dst=$2; _sh=$3; _kd=$4
	_shp=$(sed_escape_pat "$_sh")
	_kdp=$(sed_escape_pat "$_kd")
	_t=$(mktemp) || die "mktemp failed"
	# The shared dir is a sub-path of the skills dir, so tokenize it first so the
	# longer/more-specific match wins.
	sed -e "s|$_shp|{{SHARED_DIR}}|g" -e "s|$_kdp|{{SKILLS_DIR}}|g" "$_src" > "$_t"
	awk '
		/^---$/ { f++ }
		f<=1 && !done && /^skill_name:/ { sub(/^skill_name:/, "name:"); done=1 }
		{ print }
	' "$_t" > "$_dst"
	rm -f "$_t"
}

# Ensure a skillset manifest exists (created with skillset: + description: on
# first ingest; an existing manifest is left untouched). Args: <setdir> <skillset>
manifest_ensure() {
	[ -f "$1/manifest" ] && return 0
	mkdir -p "$1"
	printf 'skillset: %s\ndescription: ingested skillset %s\n' "$2" "$2" > "$1/manifest"
}

# Append "key: value" to a manifest unless that exact line already exists
# (idempotent merge). Args: <manifest> <key> <value>
manifest_append() {
	_line="$2: $3"
	[ -f "$1" ] && grep -qxF "$_line" "$1" && return 0
	printf '%s\n' "$_line" >> "$1"
}

# Expand one --skill selector. Exact names pass through; shell-style patterns
# match direct child directories of the harness skills root.
# Args: <harness> <skills_dir> <selector>
expand_skill_selector() {
	_h=$1; _hskills=$2; _sel=$3

	if ! has_glob_chars "$_sel"; then
		printf '%s\n' "$_sel"
		return 0
	fi

	_found=0
	for _dir in "$_hskills"/*; do
		[ -d "$_dir" ] || continue
		_name=${_dir##*/}
		case "$_name" in
			$_sel)
				printf '%s\n' "$_name"
				_found=1
				;;
		esac
	done

	[ "$_found" = 1 ] || die "ingest: skill pattern '$_sel' matched no skills in harness '$_h' ($_hskills)"
}

# Ingest one skill from a harness into the data-dir registry skillset.
# Args: <harness> <skillset> <skill> <h_skills_dir> <h_shared_dir> <setdir>
ingest_skill() {
	_h=$1; _set=$2; _sk=$3; _hskills=$4; _hshared=$5; _setdir=$6
	_srcdir="$_hskills/$_sk"
	[ -d "$_srcdir" ] || die "ingest: skill '$_sk' not found in harness '$_h' ($_srcdir)"
	_dstdir="$_setdir/$_sk"
	mkdir -p "$_dstdir"

	_list=$(mktemp) || die "mktemp failed"
	find "$_srcdir" -type f > "$_list"
	while IFS= read -r _srcf <&8; do
		_rel=${_srcf#"$_srcdir"/}
		_dstf="$_dstdir/$_rel"
		mkdir -p "$(dirname -- "$_dstf")"
		reverse_render_file "$_srcf" "$_dstf" "$_hshared" "$_hskills"
	done 8< "$_list"
	rm -f "$_list"

	manifest_ensure "$_setdir" "$_set"
	manifest_append "$_setdir/manifest" skill "$_sk"
	printf '%s: ingested skill "%s" from "%s" -> %s\n' "$PROG" "$_sk" "$_h" "$_dstdir"
}

# Ingest one MCP server from a harness config into the data-dir registry and
# wire it into the skillset manifest (the adapter must already be sourced).
# Args: <harness> <skillset> <server> <setdir> <mcpdir>
ingest_mcp() {
	_h=$1; _set=$2; _srv=$3; _setdir=$4; _mcpdir=$5
	_neutral=$(adapter_mcp_read "$_srv") || \
		die "ingest: could not read mcp server '$_srv' from harness '$_h'"
	[ -n "$_neutral" ] || die "ingest: mcp server '$_srv' produced an empty definition"
	mkdir -p "$_mcpdir"
	printf '%s\n' "$_neutral" > "$_mcpdir/$_srv"
	manifest_ensure "$_setdir" "$_set"
	manifest_append "$_setdir/manifest" mcp "$_srv"
	printf '%s: ingested mcp server "%s" from "%s" -> %s\n' "$PROG" "$_srv" "$_h" "$_mcpdir/$_srv"
}

# ingest: reverse-render a harness's skills and MCP servers into the user's
# data-dir registry, in canonical placeholder form.
cmd_ingest() {
	_harg=''; _set=''; _skills=''; _mcps=''
	while [ "$#" -gt 0 ]; do
		case "$1" in
			--harness)    [ "$#" -ge 2 ] || die "ingest: --harness needs a value"; _harg=$2; shift 2 ;;
			--harness=*)  _harg=${1#*=}; shift ;;
			--skillset)   [ "$#" -ge 2 ] || die "ingest: --skillset needs a value"; _set=$2; shift 2 ;;
			--skillset=*) _set=${1#*=}; shift ;;
			--skill)      [ "$#" -ge 2 ] || die "ingest: --skill needs a value"; _skills=$2; shift 2 ;;
			--skill=*)    _skills=${1#*=}; shift ;;
			--mcp)        [ "$#" -ge 2 ] || die "ingest: --mcp needs a value"; _mcps=$2; shift 2 ;;
			--mcp=*)      _mcps=${1#*=}; shift ;;
			-h|--help)    printf 'usage: %s ingest --harness <h> --skillset <set> [--skill a,b] [--mcp x,y]\n' "$PROG"; return 0 ;;
			*) die "ingest: unknown option '$1'" ;;
		esac
	done

	[ -n "$_harg" ] || die "ingest: --harness <h> is required"
	[ -n "$_set" ]  || die "ingest: --skillset <set> is required"
	[ -n "$_skills" ] || [ -n "$_mcps" ] || \
		die "ingest: give at least one of --skill <csv> or --mcp <csv>"

	# Adapter (harness conventions) loads from the engine root; output goes to the
	# user data-dir registry.
	_root=$(brandi_sh_root)
	_adapter="$_root/adapters/$_harg.sh"
	[ -f "$_adapter" ] || die "ingest: unknown harness '$_harg' (no adapter at $_adapter)"
	# shellcheck disable=SC1090
	. "$_adapter"
	[ "${ADAPTER_NAME:-}" = "$_harg" ] || \
		die "ingest: adapter $_adapter declares ADAPTER_NAME='${ADAPTER_NAME:-}', expected '$_harg'"

	_data=$(data_dir)
	_setdir="$_data/registry/skills/$_set"
	_hskills=$(adapter_skills_dir) || die "ingest: cannot locate '$_harg' skills dir"
	_hshared=$(adapter_shared_dir "$_set")

	if [ -n "$_skills" ]; then
		_sl=$(mktemp) || die "mktemp failed"
		_rawsl=$(mktemp) || die "mktemp failed"
		_split_csv "$_skills" > "$_rawsl"
		while IFS= read -r _sel <&7; do
			expand_skill_selector "$_harg" "$_hskills" "$_sel"
		done 7< "$_rawsl" > "$_sl"
		rm -f "$_rawsl"
		while IFS= read -r _sk <&7; do
			ingest_skill "$_harg" "$_set" "$_sk" "$_hskills" "$_hshared" "$_setdir"
		done 7< "$_sl"
		rm -f "$_sl"
	fi

	if [ -n "$_mcps" ]; then
		command -v python3 >/dev/null 2>&1 || \
			die "ingest: --mcp needs python3 to read the harness MCP config (none found)"
		_mcptarget=$(adapter_mcp_target)
		[ -f "$_mcptarget" ] || die "ingest: $_harg MCP config not found: $_mcptarget"
		_mcpdir="$_data/registry/mcp"
		_ml=$(mktemp) || die "mktemp failed"
		_split_csv "$_mcps" > "$_ml"
		while IFS= read -r _mc <&7; do
			ingest_mcp "$_harg" "$_set" "$_mc" "$_setdir" "$_mcpdir"
		done 7< "$_ml"
		rm -f "$_ml"
	fi

	printf '%s: ingest complete; skillset "%s" registry at %s\n' "$PROG" "$_set" "$_setdir"
}

# --- help / dispatch -------------------------------------------------------

usage() {
	cat <<EOF
brandi.sh — install & sync Agent Skills and MCP servers across coding-agent harnesses.

Usage: ${PROG} <command> [options]

Commands:
  install     Render skillset(s) into detected/selected harnesses
  list        Show registry skillsets/skills and where they are installed
  add         Render an additional skillset into targeted harnesses
  sync        Re-render to reconcile installed outputs with the registry
  doctor      Report drift and missing harness dirs (non-zero on problems)
  uninstall   Remove rendered files this tool created; restore backups
  ingest      Reverse-render a harness's skills/MCP into your registry

Options:
  -h, --help     Show this help and exit
  --version      Print version and exit
EOF
}

main() {
	cmd=${1:-}
	if [ "$#" -gt 0 ]; then
		shift
	fi

	case "$cmd" in
		install)    cmd_install "$@" ;;
		list)       cmd_list "$@" ;;
		add)        cmd_add "$@" ;;
		sync)       cmd_sync "$@" ;;
		doctor)     cmd_doctor "$@" ;;
		uninstall)  cmd_uninstall "$@" ;;
		ingest)     cmd_ingest "$@" ;;
		_render)
			# Internal: render a skillset into a harness without touching state.
			[ "$#" -ge 2 ] || die "usage: $PROG _render <skillset> <harness>"
			render_skillset "$1" "$2"
			;;
		_mcp)
			# Internal: emit one MCP server with an explicit target file.
			[ "$#" -ge 3 ] || die "usage: $PROG _mcp <claude|codex> <serverfile> <target>"
			case "$1" in
				claude) mcp_emit_claude "$2" "$3" ;;
				codex)  mcp_emit_codex "$2" "$3" ;;
				*) die "_mcp: unknown emitter '$1'" ;;
			esac
			;;
		-h|--help|help|'')
			usage
			;;
		--version)
			printf '%s %s\n' "$PROG" "$VERSION"
			;;
		*)
			printf '%s: unknown command "%s"\n\n' "$PROG" "$cmd" >&2
			usage >&2
			return 2
			;;
	esac
}

main "$@"
