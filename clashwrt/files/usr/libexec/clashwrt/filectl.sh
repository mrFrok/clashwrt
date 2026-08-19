#!/bin/sh
# SPDX-License-Identifier: GPL-3.0-or-later
#
# Rule-list file manager for the LuCI "Rule files" page.
#
# These are the hand-maintained lists a config refers to, e.g.
#   rule-providers:
#     kinopub: { behavior: classical, type: file, format: text, path: ./lst/kinopub.txt }
#
# Everything is confined to one directory and to plain names: the web UI hands
# this script a file name, never a path, and anything containing a slash or a
# leading dot is rejected. Editing rule lists must not turn into a way to
# write arbitrary files as root.
#
# Usage: filectl.sh list|read <name>|save <name>|delete <name>|dir

. /lib/functions.sh

STAGING="/tmp/clashwrt-staging"

config_load clashwrt
config_get MIHOMO_DIR config mihomo_dir /etc/mihomo
config_get LIST_SUBDIR config list_subdir lst

BASE="$MIHOMO_DIR/$LIST_SUBDIR"

die() { echo "ERROR: $*" >&2; exit 1; }

check_name() {
	local n="$1"
	[ -n "$n" ] || die "no file name given"
	case "$n" in
		*/*|.*|*..*) die "invalid file name: $n" ;;
	esac
	# keep it to things that are unambiguously a plain file name
	case "$n" in
		*[!A-Za-z0-9._-]*) die "invalid file name: $n" ;;
	esac
	return 0
}

do_dir() { echo "$BASE"; }

do_list() {
	[ -d "$BASE" ] || return 0
	# name<TAB>bytes<TAB>lines -- enough for the page to render a table
	for f in "$BASE"/*; do
		[ -f "$f" ] || continue
		printf '%s\t%s\t%s\n' \
			"$(basename "$f")" \
			"$(wc -c < "$f" | tr -d ' ')" \
			"$(grep -c '' "$f" 2>/dev/null || echo 0)"
	done
}

do_read() {
	check_name "$1"
	[ -f "$BASE/$1" ] || die "no such file: $1"
	cat "$BASE/$1"
}

do_save() {
	check_name "$1"
	[ -f "$STAGING" ] || die "nothing staged at $STAGING"
	mkdir -p "$BASE"
	cat "$STAGING" > "$BASE/$1"
	rm -f "$STAGING"
	echo "saved $BASE/$1"
}

do_delete() {
	check_name "$1"
	[ -f "$BASE/$1" ] || die "no such file: $1"
	rm -f "$BASE/$1"
	echo "deleted $1"
}

# Reloading rule providers does not need a full restart: mihomo re-reads
# file-backed providers on demand through its API.
do_reload() {
	config_get API_PORT config api_port 9090
	curl -s -m 5 -X PUT "http://127.0.0.1:${API_PORT}/providers/rules/${1}" >/dev/null 2>&1 \
		&& echo "asked mihomo to reload provider ${1}" \
		|| echo "could not reach mihomo API; restart it to pick the change up"
}

case "${1:-}" in
	dir)    do_dir ;;
	list)   do_list ;;
	read)   do_read "${2:-}" ;;
	save)   do_save "${2:-}" ;;
	delete) do_delete "${2:-}" ;;
	reload) do_reload "${2:-}" ;;
	*) echo "usage: $0 list|read <name>|save <name>|delete <name>|reload <provider>|dir" >&2; exit 1 ;;
esac
