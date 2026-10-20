#!/bin/sh
# SPDX-License-Identifier: GPL-3.0-or-later
#
# Install a Clash/mihomo web dashboard into $MIHOMO_DIR/ui.
#
# Dashboards ship as tarballs of a gh-pages branch. Note that OpenWrt images
# routinely lack unzip, so the .zip release assets most projects advertise are
# useless here -- the branch archive, which GitHub always offers as .tar.gz,
# is the portable route.
#
# Those archives wrap everything in one top-level directory, which GNU tar
# would strip with --strip-components=1. busybox tar has no such option, and
# busybox is what OpenWrt actually ships, so the wrapper directory is detected
# and stepped into after extraction instead.
#
# Usage: uictl.sh list|current|install <name>|install-url <url>

. /lib/functions.sh
# Downloads go through the proxy first (net.sh); a copy of this script run
# on its own, without net.sh beside it, fetches directly.
CW_NET="${CLASHWRT_LIBEXEC:-$(dirname "$0")}/net.sh"
if [ -f "$CW_NET" ]; then
	# shellcheck source=net.sh
	. "$CW_NET"
else
	cw_proxy_url() { return 1; }
	cw_curl() { curl "$@"; }
fi

config_load clashwrt
config_get MIHOMO_DIR config mihomo_dir /etc/mihomo

UI_DIR="$MIHOMO_DIR/ui"

die() { echo "ERROR: $*" >&2; exit 1; }

url_for() {
	case "$1" in
		metacubexd) echo "https://github.com/MetaCubeX/metacubexd/archive/refs/heads/gh-pages.tar.gz" ;;
		zashboard)  echo "https://github.com/Zephyruso/zashboard/archive/refs/heads/gh-pages.tar.gz" ;;
		yacd)       echo "https://github.com/MetaCubeX/Yacd-meta/archive/refs/heads/gh-pages.tar.gz" ;;
		*) return 1 ;;
	esac
}

do_list() {
	echo "metacubexd	MetaCubeX metacubexd (default)"
	echo "zashboard	zashboard"
	echo "yacd	Yacd-meta"
}

# Every one of these dashboards ships a service worker that caches the whole
# app shell in the browser. On a router that is all cost and no benefit: the
# panel is one hop away over the LAN, while the cache makes switching
# dashboards look broken -- the files change, the service worker keeps serving
# the old app, and the user is told the install succeeded while seeing the
# previous panel. It cannot be cleared from the LuCI side either, since the
# panel lives on a different port and is therefore a different origin.
#
# So the worker is replaced with one that unregisters itself, drops the caches
# and reloads any open window. Browsers re-check sw.js on navigation, so an
# already-registered worker from a previous dashboard picks this up and
# disappears on the next visit.
neuter_service_worker() {
	local root="$1"
	[ -f "$root/sw.js" ] || return 0

	cat > "$root/sw.js" <<'SW'
/* Replaced by ClashWrt: a router dashboard has no use for offline caching,
   and a stale cache makes switching dashboards look like it failed. */
self.addEventListener('install', function () { self.skipWaiting(); });
self.addEventListener('activate', function (event) {
	event.waitUntil((async function () {
		try {
			var keys = await caches.keys();
			await Promise.all(keys.map(function (k) { return caches.delete(k); }));
		} catch (e) { /* caches may be unavailable; unregistering still matters */ }
		await self.registration.unregister();
		var clients = await self.clients.matchAll({ type: 'window' });
		clients.forEach(function (c) { c.navigate(c.url); });
	})());
});
SW
	echo "replaced the dashboard's service worker with a self-unregistering one"
}

do_current() {
	if [ -f "$UI_DIR/.clashwrt-source" ]; then
		cat "$UI_DIR/.clashwrt-source"
	elif [ -d "$UI_DIR" ]; then
		echo "unknown (directory exists)"
	else
		echo "none"
	fi
}

install_from() {
	local url="$1" label="$2"
	local tmp tgz
	tmp="$(mktemp -d /tmp/clashwrt-ui.XXXXXX)" || die "cannot create a temporary directory"
	tgz="$tmp/ui.tar.gz"

	echo "downloading $url"
	if ! cw_curl -sSL --fail --proto '=https' --max-filesize 67108864 -m 180 -o "$tgz" "$url"; then
		rm -rf "$tmp"
		die "download failed"
	fi
	[ -s "$tgz" ] || { rm -rf "$tmp"; die "downloaded file is empty"; }

	mkdir -p "$tmp/x"
	tar xzf "$tgz" -C "$tmp/x" 2>/dev/null || {
		rm -rf "$tmp"
		die "could not extract the archive (is it a .tar.gz?)"
	}

	# step into the wrapper directory if that is all the archive contains
	local root="$tmp/x"
	if [ ! -f "$root/index.html" ]; then
		local only
		only="$(find "$root" -mindepth 1 -maxdepth 1)"
		if [ "$(echo "$only" | wc -l)" = "1" ] && [ -d "$only" ] && [ ! -L "$only" ]; then
			root="$only"
		fi
	fi

	[ -f "$root/index.html" ] || {
		rm -rf "$tmp"
		die "extracted archive has no index.html -- this does not look like a dashboard"
	}

	# swap in place only once the new copy is known good, so a failed
	# download never leaves the router without a usable dashboard
	neuter_service_worker "$root"

	# /tmp is RAM and the dashboard goes to flash, so this mv is a copy that
	# can run out of room halfway; the old copy goes only once it has not
	rm -rf "$UI_DIR.old"
	[ -d "$UI_DIR" ] && mv "$UI_DIR" "$UI_DIR.old"
	mkdir -p "$(dirname "$UI_DIR")"
	if ! mv "$root" "$UI_DIR"; then
		rm -rf "$UI_DIR"
		[ -d "$UI_DIR.old" ] && mv "$UI_DIR.old" "$UI_DIR"
		rm -rf "$tmp"
		die "could not copy the dashboard into $UI_DIR (out of space?); the previous one is back"
	fi
	echo "$label" > "$UI_DIR/.clashwrt-source"
	rm -rf "$UI_DIR.old" "$tmp"

	echo "installed $label into $UI_DIR"
	echo "make sure config.yaml has: external-ui: $UI_DIR"
}

case "${1:-}" in
	list)    do_list ;;
	current) do_current ;;
	install)
		name="${2:-}"
		url="$(url_for "$name")" || die "unknown dashboard: $name"
		install_from "$url" "$name"
		;;
	install-url)
		url="${2:-}"
		[ -n "$url" ] || die "no URL given"
		case "$url" in
			# what this fetches runs in the browser next to the API secret,
			# so it is not taken over a connection anyone on the way can edit
			https://*) ;;
			*) die "URL must start with https://" ;;
		esac
		install_from "$url" "custom: $url"
		;;
	*) echo "usage: $0 list|current|install <name>|install-url <url>" >&2; exit 1 ;;
esac
