#!/bin/sh
# SPDX-License-Identifier: GPL-3.0-or-later
#
# Publishes the LuCI pages under content-addressed names.
#
# LuCI appends one ?v= to every resource it loads, taken from the luci.js
# script tag, and that token only changes when luci-base itself does. A view
# therefore keeps the same URL for the life of the installed LuCI, and a
# browser that already holds it will not fetch it again -- the scheme treats
# these files as immutable. Replacing one on disk reaches nobody.
#
# That cost four rounds of "it still shows the old page" on a real install,
# including one where the page was new but the module it requires was not:
# renaming a view is only half of it, because everything it pulls in is cached
# independently and has to move too.
#
# So the canonical files live outside the web root, and this publishes copies
# whose names carry a hash of their own contents. Change anything and every
# URL changes with it; change nothing and republishing is a no-op.
#
# Usage: uistamp.sh apply | current | clean

SRC="/usr/share/clashwrt/ui"
WWW="/www/luci-static/resources"
MENU="/usr/share/luci/menu.d/luci-app-clashwrt.json"

log() { logger -t clashwrt "$@"; [ -t 1 ] && echo "clashwrt: $*" >&2; return 0; }
die() { echo "clashwrt: ERROR: $*" >&2; exit 1; }

[ -d "$SRC/view" ] || die "no canonical UI at $SRC"

# One token over every file, not per file: a view and the module it requires
# have to move together, or a fresh page loads a stale module.
token() {
	cat "$SRC"/view/*.js "$SRC"/mod/*.js "$SRC"/menu.json 2>/dev/null \
		| md5sum | cut -c1-8
}

do_current() {
	ls "$WWW/view/clashwrt"/*.js 2>/dev/null \
		| sed -n 's/.*-\([0-9a-f]\{8\}\)\.js$/\1/p' | sort -u
}

do_clean() {
	rm -f "$WWW/view/clashwrt"/*.js "$WWW/clashwrt"/*.js
	rmdir "$WWW/view/clashwrt" "$WWW/clashwrt" 2>/dev/null
	log "removed published pages"
}

do_apply() {
	local t b
	t="$(token)"
	[ -n "$t" ] || die "could not hash the UI sources"

	if [ "$(do_current)" = "$t" ]; then
		log "pages already published as $t"
		return 0
	fi

	mkdir -p "$WWW/view/clashwrt" "$WWW/clashwrt"

	# Everything old goes, including previous tokens: leaving them behind
	# would accumulate a copy of the whole UI on every update.
	rm -f "$WWW/view/clashwrt"/*.js "$WWW/clashwrt"/*.js

	for f in "$SRC"/mod/*.js; do
		[ -f "$f" ] || continue
		b="$(basename "$f" .js)"
		cp "$f" "$WWW/clashwrt/$b-$t.js"
	done

	# The require line names a module without its extension, so it has to be
	# rewritten to the stamped name or the page loads nothing.
	for f in "$SRC"/view/*.js; do
		[ -f "$f" ] || continue
		b="$(basename "$f" .js)"
		sed "s#'require clashwrt\.\([A-Za-z0-9_-]*\) as #'require clashwrt.\1-$t as #g" \
			"$f" > "$WWW/view/clashwrt/$b-$t.js"
	done

	sed "s#\"clashwrt/\([A-Za-z0-9_-]*\)\"#\"clashwrt/\1-$t\"#g" \
		"$SRC/menu.json" > "$MENU"

	chmod 0644 "$WWW/view/clashwrt"/*.js "$WWW/clashwrt"/*.js "$MENU" 2>/dev/null

	rm -f /tmp/luci-indexcache* 2>/dev/null
	/etc/init.d/rpcd restart >/dev/null 2>&1

	log "published pages as $t"
	echo "$t"
}

case "${1:-apply}" in
	apply)   do_apply ;;
	current) do_current ;;
	clean)   do_clean ;;
	*) echo "usage: $0 apply|current|clean" >&2; exit 1 ;;
esac
