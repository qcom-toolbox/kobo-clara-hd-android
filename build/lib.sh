# Shared helpers for the build scripts. Sourced, never executed.

set -eu

say()  { printf '\n\033[1m==> %s\033[0m\n' "$*"; }
info() { printf '    %s\n' "$*"; }
warn() { printf '\033[33m    ! %s\033[0m\n' "$*" >&2; }
die()  { printf '\033[31m!! %s\033[0m\n' "$*" >&2; exit 1; }

# ask <variable> <prompt> [default]
# Takes the value from the environment if it is already set, so the whole
# build can run unattended with BUILD_VENDOR_ROOT=... BUILD_BASE_IMAGE=... etc.
ask() {
	_var=$1 _prompt=$2 _default=${3-}
	eval _cur=\${$_var-}
	if [ -n "${_cur:-}" ]; then
		info "$_var = $_cur"
		return
	fi
	if [ -n "$_default" ]; then
		printf '%s [%s]: ' "$_prompt" "$_default"
	else
		printf '%s: ' "$_prompt"
	fi
	read -r _answer || true
	[ -n "$_answer" ] || _answer=$_default
	[ -n "$_answer" ] || die "$_var is required"
	eval "$_var=\$_answer"
	export "$_var"
}

confirm() {
	printf '%s [y/N]: ' "$1"
	read -r _yn || true
	case "$_yn" in y|Y|yes|YES) return 0 ;; *) return 1 ;; esac
}

need() {
	for _t in "$@"; do
		command -v "$_t" >/dev/null 2>&1 || die "missing host tool: $_t"
	done
}

# fetch <url> <destination file>
fetch() {
	_url=$1 _dst=$2
	if [ -s "$_dst" ]; then
		info "have $(basename "$_dst")"
		return
	fi
	info "downloading $(basename "$_dst")"
	mkdir -p "$(dirname "$_dst")"
	curl -sSfL --retry 3 -o "$_dst.part" "$_url" || die "download failed: $_url"
	mv "$_dst.part" "$_dst"
}

# unpack_zip <zip> <directory> <marker inside directory>
unpack_zip() {
	_zip=$1 _dir=$2 _marker=$3
	if [ -e "$_dir/$_marker" ]; then
		info "have $(basename "$_dir")"
		return
	fi
	mkdir -p "$_dir"
	unzip -q -o "$_zip" -d "$_dir" || die "unzip failed: $_zip"
}

# git_at <url> <directory> <commit>
git_at() {
	_url=$1 _dir=$2 _commit=$3
	if [ -d "$_dir/.git" ]; then
		info "have $(basename "$_dir")"
	else
		info "cloning $(basename "$_dir")"
		git clone -q "$_url" "$_dir" || die "clone failed: $_url"
	fi
	( cd "$_dir" && git checkout -q "$_commit" ) || die "checkout $_commit failed in $_dir"
}

# Disassemble/assemble helpers. $SMALI_CP is set by 10-deps.sh.
baksmali() { java -cp "$SMALI_CP" org.jf.baksmali.Main "$@"; }
smali()    { java -cp "$SMALI_CP" org.jf.smali.Main "$@"; }

# dex_from_jar <jar> <outdir>  -> disassembles the jar's classes.dex
dex_from_jar() {
	_jar=$1 _out=$2
	rm -rf "$_out"
	_tmp=$(mktemp -d)
	unzip -q -o "$_jar" classes.dex -d "$_tmp" || die "no classes.dex in $_jar"
	baksmali d -a 19 -o "$_out" "$_tmp/classes.dex" >/dev/null
	rm -rf "$_tmp"
}

# jar_from_smali <smali dir> <original jar> <output jar>
jar_from_smali() {
	_smali=$1 _orig=$2 _out=$3
	case "$_out" in /*) ;; *) _out=$PWD/$_out ;; esac
	_tmp=$(mktemp -d)
	smali a -a 19 -o "$_tmp/classes.dex" "$_smali" >/dev/null
	cp "$_orig" "$_out"
	( cd "$_tmp" && zip -q "$_out" classes.dex )
	rm -rf "$_tmp"
}
