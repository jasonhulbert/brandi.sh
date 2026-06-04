#!/bin/sh
# install.sh — bootstrap the brandi.sh ENGINE onto this machine.
#
# This is the "place the tool on the machine" step. It is DISTINCT from
# "brandi.sh install", which renders skills into your coding-agent harnesses.
#
# The ENGINE is the CLI script + adapters. Your REGISTRY (skillsets + MCP
# servers), state record, and backups live in a separate, user-owned DATA dir
# that this bootstrap creates but never overwrites or deletes (without --purge).
# By default the engine and data dir share one directory ($XDG_DATA_HOME/brandi.sh)
# but occupy distinct subpaths:
#   engine -> $INSTALL_DIR/brandi.sh + $INSTALL_DIR/adapters/
#   data   -> $DATA_DIR/registry/ + $DATA_DIR/state + $DATA_DIR/backups/
# No sudo; everything lives under your home by default; idempotent.
set -eu

PROG=install.sh
TOOL=brandi.sh

: "${XDG_DATA_HOME:=$HOME/.local/share}"
: "${INSTALL_DIR:=$XDG_DATA_HOME/$TOOL}"
: "${BIN_DIR:=$HOME/.local/bin}"
# User data dir (registry + state + backups). Resolved exactly as brandi.sh does:
# BRANDI_SH_DATA wins; else $XDG_DATA_HOME/$TOOL (coincides with INSTALL_DIR by default).
DATA_DIR="${BRANDI_SH_DATA:-$XDG_DATA_HOME/$TOOL}"

SRC=''        # resolved source tree (holds brandi.sh + adapters/)
CLEANUP=''    # temp dir to remove on exit, if we extracted a tarball

die() { printf '%s: %s\n' "$PROG" "$*" >&2; exit 1; }
info() { printf '%s: %s\n' "$PROG" "$*"; }
cleanup() { [ -n "$CLEANUP" ] && rm -rf "$CLEANUP" || true; }
trap cleanup EXIT

usage() {
	cat <<EOF
$PROG — install the $TOOL engine (no sudo, idempotent).

Usage:
  sh $PROG [--uninstall [--purge]]

The engine is the CLI + adapters. Your registry, state, and backups live in a
separate data dir that this bootstrap creates but never overwrites.

Env overrides:
  BIN_DIR                CLI launcher location           (default ~/.local/bin)
  INSTALL_DIR            engine: CLI + adapters/         (default \$XDG_DATA_HOME/$TOOL)
  XDG_DATA_HOME          base for INSTALL_DIR + data dir (default ~/.local/share)
  BRANDI_SH_DATA         user data dir (registry/state)  (default \$XDG_DATA_HOME/$TOOL)
  BRANDI_SH_SRC          install from this local source tree (skips auto-detect)
  BRANDI_SH_TARBALL      install from this local .tar.gz
  BRANDI_SH_TARBALL_URL  download and install from this remote .tar.gz

After installing, run "$TOOL install" to render skills into your harnesses.
To remove the engine (keeping your data):  sh $PROG --uninstall
To also delete your data dir:               sh $PROG --uninstall --purge
EOF
}

# Resolve a source tree containing brandi.sh + adapters/ (the engine). Sets SRC.
# The registry is no longer shipped, so it is not required in the source.
resolve_src() {
	if [ -n "${BRANDI_SH_SRC:-}" ]; then
		SRC="$BRANDI_SH_SRC"
		return 0
	fi

	_self=$(CDPATH='' cd -- "$(dirname -- "$0")" 2>/dev/null && pwd || true)
	if [ -n "$_self" ] && [ -f "$_self/$TOOL" ] && [ -d "$_self/adapters" ]; then
		SRC="$_self"
		return 0
	fi

	# No local tree (e.g. piped via curl|sh): fetch/extract a tarball.
	CLEANUP=$(mktemp -d)
	_tb=''
	if [ -n "${BRANDI_SH_TARBALL:-}" ]; then
		_tb="$BRANDI_SH_TARBALL"
	elif [ -n "${BRANDI_SH_TARBALL_URL:-}" ]; then
		_tb="$CLEANUP/src.tar.gz"
		if command -v curl >/dev/null 2>&1; then
			curl -fsSL "$BRANDI_SH_TARBALL_URL" -o "$_tb" || die "download failed: $BRANDI_SH_TARBALL_URL"
		elif command -v wget >/dev/null 2>&1; then
			wget -qO "$_tb" "$BRANDI_SH_TARBALL_URL" || die "download failed: $BRANDI_SH_TARBALL_URL"
		else
			die "need curl or wget to download $BRANDI_SH_TARBALL_URL"
		fi
	else
		die "cannot locate a $TOOL source tree; run from a clone, or set BRANDI_SH_SRC / BRANDI_SH_TARBALL / BRANDI_SH_TARBALL_URL"
	fi

	[ -f "$_tb" ] || die "tarball not found: $_tb"
	tar -xzf "$_tb" -C "$CLEANUP" || die "failed to extract $_tb"
	if [ -f "$CLEANUP/$TOOL" ] && [ -d "$CLEANUP/adapters" ]; then
		SRC="$CLEANUP"
		return 0
	fi
	for _d in "$CLEANUP"/*/; do
		if [ -f "${_d}$TOOL" ] && [ -d "${_d}adapters" ]; then
			SRC="${_d%/}"
			return 0
		fi
	done
	die "extracted tarball has no $TOOL source tree (need $TOOL + adapters/)"
}

do_install() {
	resolve_src
	[ -f "$SRC/$TOOL" ] || die "source tree missing $TOOL: $SRC"
	[ -d "$SRC/adapters" ] || die "source tree missing adapters/: $SRC"

	mkdir -p "$INSTALL_DIR" "$BIN_DIR"

	# Install/refresh ONLY the engine (the script + adapters). Adapters are
	# replaced wholesale so removed files don't linger; the registry is NEVER
	# touched here — it is user-owned data that may sit beside the engine.
	cp "$SRC/$TOOL" "$INSTALL_DIR/$TOOL"
	rm -rf "$INSTALL_DIR/adapters"
	cp -R "$SRC/adapters" "$INSTALL_DIR/adapters"
	chmod +x "$INSTALL_DIR/$TOOL"

	# Ensure the user data-dir registry exists — WITHOUT clobbering any content
	# (mkdir -p is a no-op on existing dirs and never removes files).
	mkdir -p "$DATA_DIR/registry/skills" "$DATA_DIR/registry/mcp"

	# Launcher: a tiny script that points the CLI at its installed engine. The
	# data dir is resolved by the CLI at runtime (XDG default or BRANDI_SH_DATA),
	# so the launcher pins only the engine root.
	_launcher="$BIN_DIR/$TOOL"
	cat > "$_launcher" <<EOF
#!/bin/sh
# $TOOL launcher (generated by $PROG). Points the CLI at its installed engine.
BRANDI_SH_ROOT='$INSTALL_DIR'
export BRANDI_SH_ROOT
exec '$INSTALL_DIR/$TOOL' "\$@"
EOF
	chmod +x "$_launcher"

	info "installed CLI launcher -> $_launcher"
	info "installed engine       -> $INSTALL_DIR ($TOOL + adapters/)"
	info "registry data dir      -> $DATA_DIR/registry (your content; left intact)"
	check_path
	info "next: run '$TOOL install' to render skills into your harnesses."
}

check_path() {
	case ":$PATH:" in
		*":$BIN_DIR:"*)
			: ;;
		*)
			info "NOTE: $BIN_DIR is not on your PATH. Add it with:"
			info "  export PATH=\"$BIN_DIR:\$PATH\""
			;;
	esac
}

do_uninstall() {
	_purge=''
	while [ "$#" -gt 0 ]; do
		case "$1" in
			--purge) _purge=1; shift ;;
			*) die "uninstall: unknown option '$1' (try --help)" ;;
		esac
	done

	_launcher="$BIN_DIR/$TOOL"
	if [ -e "$_launcher" ]; then
		rm -f "$_launcher"
		info "removed CLI launcher $_launcher"
	else
		info "no CLI launcher at $_launcher"
	fi

	# Remove ONLY the engine (the script + adapters). Never "rm -rf $INSTALL_DIR":
	# it may be the same directory as the data dir, which holds the user's
	# registry, state, and backups.
	if [ -e "$INSTALL_DIR/$TOOL" ] || [ -d "$INSTALL_DIR/adapters" ]; then
		rm -f "$INSTALL_DIR/$TOOL"
		rm -rf "$INSTALL_DIR/adapters"
		info "removed engine ($TOOL + adapters/) from $INSTALL_DIR"
	else
		info "no engine at $INSTALL_DIR"
	fi
	# Drop the engine dir only if it is now empty (i.e. the data dir is elsewhere).
	rmdir "$INSTALL_DIR" 2>/dev/null || true

	if [ -n "$_purge" ]; then
		if [ -d "$DATA_DIR" ]; then
			rm -rf "$DATA_DIR"
			info "PURGED user data dir $DATA_DIR (registry, state, backups)"
		else
			info "no data dir at $DATA_DIR to purge"
		fi
		info "bootstrap uninstall complete (engine + data removed)."
		return 0
	fi

	# Default: preserve all user data; say what was kept and how to remove it.
	if [ -d "$DATA_DIR" ]; then
		info "PRESERVED your data dir $DATA_DIR (registry, state, backups)."
		info "  to remove it too, re-run: sh $PROG --uninstall --purge"
	fi
	if [ -f "$DATA_DIR/state" ]; then
		info "NOTE: rendered harness skills may still be installed (tracked in $DATA_DIR/state)."
		info "  bootstrap-uninstall does NOT remove them; run '$TOOL uninstall' FIRST to do so."
	fi
	info "bootstrap uninstall complete (engine removed; user data left untouched)."
}

main() {
	case "${1:-}" in
		-h|--help) usage; exit 0 ;;
		--uninstall) shift; do_uninstall "$@"; exit 0 ;;
		'') do_install ;;
		*) die "unknown argument '$1' (try --help)" ;;
	esac
}

main "$@"
