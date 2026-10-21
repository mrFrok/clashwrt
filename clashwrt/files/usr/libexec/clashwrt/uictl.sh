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
# Where it is kept between boots is ui_store, as core_store is for the core
# (updctl.sh): 'flash' (the directory itself), 'gz' (the archive on flash,
# unpacked into RAM at boot) or 'ram' (downloaded again after every boot,
# through the proxy once mihomo is up). With gz and ram, $MIHOMO_DIR/ui is a
# symlink into $UI_RAM, which mihomo follows.
#
# Usage: uictl.sh list|current|install <name>|install-url <url>
#        uictl.sh store flash|gz|ram|prepare|status

# shellcheck source=/dev/null
. "${CLASHWRT_FUNCTIONS:-/lib/functions.sh}"
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
STORE_DIR="${CLASHWRT_STORE_DIR:-/etc/clashwrt/store}"
UI_GZ="$STORE_DIR/ui.tar.gz"
# "<url> <label>" of the dashboard kept, for ram to fetch again
UI_NOTE="$STORE_DIR/ui.note"
UI_RAM="${CLASHWRT_UI_RAM:-/tmp/clashwrt-ui}"
MEMINFO="${CLASHWRT_MEMINFO:-/proc/meminfo}"

ui_store() {
	case "$(uci -q get clashwrt.config.ui_store)" in
		gz) echo gz ;; ram) echo ram ;; *) echo flash ;;
	esac
}

avail_kb() {
	df -k "$1" 2>/dev/null | awk 'END { for (i = 1; i <= NF; i++) if ($i ~ /%$/) { print $(i-1); exit } }'
}
meminfo_kb() { awk -v k="$1:" '$1 == k { print $2; f = 1 } END { if (!f) print 0 }' "$MEMINFO" 2>/dev/null; }

# Why RAM cannot take $1 KB more, or nothing (and failure) when it can; the
# same measure as for the core and the providers.
ram_no_room() {
	local need=$(( $1 + 1024 )) total avail floor
	total="$(meminfo_kb MemTotal)"
	avail="$(meminfo_kb MemAvailable)"
	[ "$total" -ge 262144 ] || { echo "the router has under 256 MB of RAM"; return 0; }
	floor=$((total * 15 / 100)); [ "$floor" -ge 32768 ] || floor=32768
	[ $((avail - need)) -ge "$floor" ] || { echo "too little free RAM (${avail}K free, ${need}K needed)"; return 0; }
	return 1
}

dir_kb() { du -sk "$1" 2>/dev/null | awk '{ print $1 + 0 }'; }

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

# Unpacks archive $1 into $2 and prints the directory holding index.html:
# the archive's own wrapper directory is stepped into if that is all there is.
unpack_ui() {
	local tgz="$1" dest="$2" root only
	mkdir -p "$dest"
	tar xzf "$tgz" -C "$dest" 2>/dev/null || return 1
	root="$dest"
	if [ ! -f "$root/index.html" ]; then
		only="$(find "$root" -mindepth 1 -maxdepth 1)"
		if [ "$(echo "$only" | wc -l)" = "1" ] && [ -d "$only" ] && [ ! -L "$only" ]; then
			root="$only"
		fi
	fi
	[ -f "$root/index.html" ] || return 1
	echo "$root"
}

# Puts directory $1 into RAM as the dashboard and points $UI_DIR at it. New
# first, then the link, then the old copy: mihomo always has one to serve.
to_ram() {
	local src="$1"
	rm -rf "$UI_RAM.new"
	mkdir -p "$(dirname "$UI_RAM")"
	cp -a "$src" "$UI_RAM.new" 2>/dev/null || { rm -rf "$UI_RAM.new"; return 1; }
	rm -rf "$UI_RAM.old"
	[ -d "$UI_RAM" ] && mv "$UI_RAM" "$UI_RAM.old"
	mv "$UI_RAM.new" "$UI_RAM" || return 1
	link_ui
	rm -rf "$UI_RAM.old"
}

link_ui() {
	[ "$(readlink "$UI_DIR" 2>/dev/null)" = "$UI_RAM" ] && return 0
	mkdir -p "$(dirname "$UI_DIR")"
	if [ -d "$UI_DIR" ] && [ ! -L "$UI_DIR" ]; then
		rm -rf "$UI_DIR.old"; mv "$UI_DIR" "$UI_DIR.old"
	fi
	rm -f "$UI_DIR"
	ln -s "$UI_RAM" "$UI_DIR"
	rm -rf "$UI_DIR.old"
}

# Directory $1 as the dashboard on flash; a link into RAM is replaced.
to_flash() {
	local src="$1"
	rm -rf "$UI_DIR.new"
	mkdir -p "$(dirname "$UI_DIR")"
	if ! cp -a "$src" "$UI_DIR.new" 2>/dev/null; then
		rm -rf "$UI_DIR.new"
		return 1
	fi
	rm -rf "$UI_DIR.old"
	if [ -L "$UI_DIR" ]; then rm -f "$UI_DIR"; elif [ -d "$UI_DIR" ]; then mv "$UI_DIR" "$UI_DIR.old"; fi
	mv "$UI_DIR.new" "$UI_DIR" || return 1
	rm -rf "$UI_DIR.old"
}

# Keeps archive $1 on flash as the packed dashboard.
keep_gz() {
	local tgz="$1" kb old=0
	mkdir -p "$STORE_DIR" || return 1
	kb="$(( $(wc -c < "$tgz") / 1024 ))"
	[ -f "$UI_GZ" ] && old="$(( $(wc -c < "$UI_GZ") / 1024 ))"
	if [ $(( $(avail_kb "$STORE_DIR") + old )) -lt $((kb + 512)) ]; then
		echo "ERROR: not enough room on flash for the packed dashboard (${kb}K)" >&2
		return 1
	fi
	if ! { cp -f "$tgz" "$UI_GZ.new" && mv -f "$UI_GZ.new" "$UI_GZ"; }; then
		rm -f "$UI_GZ.new"
		return 1
	fi
}

install_from() {
	local url="$1" label="$2" mode
	local tmp tgz root why
	mode="$(ui_store)"
	tmp="$(mktemp -d /tmp/clashwrt-ui.XXXXXX)" || die "cannot create a temporary directory"
	tgz="$tmp/ui.tar.gz"

	echo "downloading $url"
	if ! cw_curl -sSL --fail --proto '=https' --max-filesize 67108864 -m 180 -o "$tgz" "$url"; then
		rm -rf "$tmp"
		die "download failed"
	fi
	[ -s "$tgz" ] || { rm -rf "$tmp"; die "downloaded file is empty"; }

	root="$(unpack_ui "$tgz" "$tmp/x")" || {
		rm -rf "$tmp"
		die "the archive could not be extracted or has no index.html -- this does not look like a dashboard"
	}

	# swap in place only once the new copy is known good, so a failed
	# download never leaves the router without a usable dashboard
	neuter_service_worker "$root"
	echo "$label" > "$root/.clashwrt-source"

	case "$mode" in
	flash)
		# /tmp is RAM and the dashboard goes to flash, so this is a copy that
		# can run out of room halfway; the old copy goes only once it has not
		to_flash "$root" || { rm -rf "$tmp"; die "could not copy the dashboard into $UI_DIR (out of space?); the previous one is still there"; }
		rm -rf "$UI_RAM"; rm -f "$UI_GZ" "$UI_NOTE"
		;;
	gz|ram)
		why="$(ram_no_room "$(dir_kb "$root")")" && { rm -rf "$tmp"; die "no room in RAM for the dashboard: $why"; }
		if [ "$mode" = gz ]; then
			keep_gz "$tgz" || { rm -rf "$tmp"; die "could not keep the dashboard on flash"; }
		else
			rm -f "$UI_GZ"
		fi
		to_ram "$root" || { rm -rf "$tmp"; die "could not put the dashboard into $UI_RAM"; }
		mkdir -p "$STORE_DIR" && echo "$url $label" > "$UI_NOTE"
		;;
	esac
	rm -rf "$tmp"

	echo "installed $label ($mode)"
	echo "make sure config.yaml has: external-ui: $UI_DIR"
}

# Puts the dashboard into RAM for gz and ram; nothing when it is there. For
# ram the download goes through mihomo, so it is retried for a few minutes
# while the core comes up (from init.d/clashwrt, in the background).
do_prepare() {
	local mode url label tmp root i=0
	mode="$(ui_store)"
	[ "$mode" = flash ] && return 0
	if [ -f "$UI_RAM/index.html" ]; then link_ui; return 0; fi
	[ -f "$UI_NOTE" ] || return 0
	read -r url label < "$UI_NOTE"
	tmp="$(mktemp -d /tmp/clashwrt-ui.XXXXXX)" || die "cannot create a temporary directory"
	if [ "$mode" = gz ]; then
		[ -f "$UI_GZ" ] || { rm -rf "$tmp"; die "ui_store is 'gz' but $UI_GZ is missing; install the dashboard again"; }
		cp "$UI_GZ" "$tmp/ui.tar.gz"
	else
		case "$url" in https://*) ;; *) rm -rf "$tmp"; die "bad URL in $UI_NOTE" ;; esac
		while ! cw_curl -sSL --fail --proto '=https' --max-filesize 67108864 -m 180 -o "$tmp/ui.tar.gz" "$url"; do
			i=$((i + 1))
			[ "$i" -lt "${UI_RETRIES:-20}" ] || { rm -rf "$tmp"; die "could not download the dashboard"; }
			sleep "${UI_RETRY_DELAY:-30}"
		done
	fi
	root="$(unpack_ui "$tmp/ui.tar.gz" "$tmp/x")" || { rm -rf "$tmp"; die "could not unpack the dashboard"; }
	neuter_service_worker "$root" >/dev/null
	echo "$label" > "$root/.clashwrt-source"
	to_ram "$root" || { rm -rf "$tmp"; die "could not put the dashboard into $UI_RAM"; }
	rm -rf "$tmp"
	echo "dashboard ready in RAM"
}

# Moves the dashboard installed between flash, gz and ram, without a download.
do_store() {
	local new="$1" src tmp why label
	case "$new" in flash|gz|ram) ;; *) die "usage: store flash|gz|ram" ;; esac
	src=""
	if [ -f "$UI_RAM/index.html" ]; then src="$UI_RAM"
	elif [ -d "$UI_DIR" ] && [ ! -L "$UI_DIR" ] && [ -f "$UI_DIR/index.html" ]; then src="$UI_DIR"
	fi
	if [ -z "$src" ]; then
		uci set "clashwrt.config.ui_store=$new"; uci commit clashwrt
		echo "no dashboard installed; the next one will be kept as '$new'"
		return 0
	fi
	label="$(cat "$src/.clashwrt-source" 2>/dev/null)"

	case "$new" in
	flash)
		to_flash "$src" || die "could not copy the dashboard to flash (out of space?); it stays where it was"
		rm -rf "$UI_RAM"; rm -f "$UI_GZ" "$UI_NOTE"
		;;
	gz|ram)
		if [ "$src" != "$UI_RAM" ]; then
			why="$(ram_no_room "$(dir_kb "$src")")" && die "no room in RAM for the dashboard: $why"
		fi
		if [ "$new" = gz ]; then
			tmp="$(mktemp -d /tmp/clashwrt-ui.XXXXXX)" || die "cannot create a temporary directory"
			if ! { tar czf "$tmp/ui.tar.gz" -C "$src" . 2>/dev/null && keep_gz "$tmp/ui.tar.gz"; }; then
				rm -rf "$tmp"; die "could not pack the dashboard"
			fi
			rm -rf "$tmp"
		else
			rm -f "$UI_GZ"
			case "$label" in
				custom:\ https://*) ;;
				*) url_for "$label" >/dev/null || die "cannot tell where '$label' comes from, so it could not be fetched again at boot" ;;
			esac
		fi
		[ "$src" = "$UI_RAM" ] || to_ram "$src" || die "could not put the dashboard into $UI_RAM"
		mkdir -p "$STORE_DIR"
		case "$label" in
			custom:\ https://*) echo "${label#custom: } $label" > "$UI_NOTE" ;;
			*) echo "$(url_for "$label" 2>/dev/null || echo -) $label" > "$UI_NOTE" ;;
		esac
		;;
	esac
	uci set "clashwrt.config.ui_store=$new"; uci commit clashwrt
	echo "the dashboard is kept as '$new' now"
}

do_status() {
	echo "store:     $(ui_store)"
	echo "current:   $(do_current)"
	if [ -L "$UI_DIR" ]; then
		echo "location:  ram $(dir_kb "$UI_RAM")K$( [ -f "$UI_GZ" ] && echo ", packed on flash $(( $(wc -c < "$UI_GZ") / 1024 ))K")"
	elif [ -d "$UI_DIR" ]; then
		echo "location:  flash $(dir_kb "$UI_DIR")K"
	else
		echo "location:  none"
	fi
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
	prepare) do_prepare ;;
	store)   do_store "${2:-}" ;;
	status)  do_status ;;
	*) echo "usage: $0 list|current|install <name>|install-url <url>|prepare|store flash|gz|ram|status" >&2; exit 1 ;;
esac
