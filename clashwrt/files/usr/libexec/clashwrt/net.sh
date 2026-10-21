#!/bin/sh
# SPDX-License-Identifier: GPL-3.0-or-later
#
# How the router fetches things for itself: the mihomo core, ClashWrt's own
# updates, dashboards, bypass lists. Sourced, not run.
#
# The router's own connections are not intercepted -- the firewall only
# steers LAN traffic -- so a plain curl goes straight out the WAN, and where
# GitHub is throttled or blocked that is exactly where it fails. So the
# proxy is tried first and the WAN second:
#
#   1. the wizard's 'clashwrt-fetch' listener on 127.0.0.1, whose traffic
#      mihomo sends to the Proxy group whatever the rules say (a plain
#      mixed-port would follow them, and "direct except the lists" would send
#      github.com DIRECT);
#   2. else the config's own mixed-port or socks-port, which do follow the
#      rules but are the best a hand-written config offers;
#   3. else, or when that fails, directly.
#
# fetch_via_proxy '0' in /etc/config/clashwrt skips straight to 3.
#
#   cw_curl <curl arguments>   same arguments, same exit status as curl

# socks5h: names are resolved at the far end too, so a poisoned local
# answer for github.com cannot send the download somewhere else.
cw_proxy_url() {
	local dir conf port
	[ "$(uci -q get clashwrt.config.fetch_via_proxy)" = 0 ] && return 1
	pidof mihomo >/dev/null 2>&1 || return 1
	dir="$(uci -q get clashwrt.config.mihomo_dir)"
	conf="${dir:-/etc/mihomo}/config.yaml"
	[ -r "$conf" ] || return 1

	port="$(awk '
		/^listeners:/ { l = 1; next }
		/^[A-Za-z0-9_-]+:/ { l = 0 }
		l && /name:[ \t]*clashwrt-fetch/ { f = 1 }
		l && f && /port:[ \t]*[0-9]+/ { sub(/.*port:[ \t]*/, ""); sub(/[^0-9].*/, ""); print; exit }
	' "$conf")"
	[ -n "$port" ] || port="$(sed -n 's/^mixed-port:[ \t]*\([0-9][0-9]*\).*/\1/p' "$conf" | head -n1)"
	[ -n "$port" ] || port="$(sed -n 's/^socks-port:[ \t]*\([0-9][0-9]*\).*/\1/p' "$conf" | head -n1)"
	[ -n "$port" ] || return 1
	echo "socks5h://127.0.0.1:$port"
}

cw_curl() {
	local p out rc
	if p="$(cw_proxy_url)"; then
		# Captured, not streamed: a transfer that dies halfway must not leave
		# its first half in front of the direct attempt's whole answer. With
		# -o the file is simply written again by the second attempt.
		if out="$(curl --proxy "$p" "$@")"; then
			[ -n "$out" ] && printf '%s\n' "$out"
			return 0
		fi
		rc=$?
		logger -t clashwrt "fetch through the proxy failed (curl $rc), trying directly" 2>/dev/null
	fi
	curl "$@"
}

# The SHA-256 GitHub computed for one file of a release, from the API, or
# nothing when it does not say (a release from before GitHub kept digests,
# the API out of reach). Neither mihomo nor ClashWrt signs its releases; this
# catches a download corrupted, cut short or swapped on the way -- through a
# proxy node, say -- not a release that was bad at its source.
#
#   asset_digest <owner/repo> <tag> <file name>
#
# The API answer is pretty-printed, one key per line; each asset lists its
# "name" before its "digest", and nothing nested in it has a "name" of its own.
asset_digest() {
	cw_curl -sSL --fail --proto '=https' -m 30 \
		"https://api.github.com/repos/$1/releases/tags/$2" 2>/dev/null |
		awk -v want="$3" '
			/^[ \t]*"name":/ { n = $0; sub(/^[^:]*:[ \t]*"/, "", n); sub(/".*/, "", n) }
			/^[ \t]*"digest":[ \t]*"sha256:[0-9a-f]{64}"/ && n == want {
				d = $0; sub(/.*"sha256:/, "", d); sub(/".*/, "", d); print d; exit
			}'
}

# The SHA-256 of a file, or of stdin, as bare hex.
sha256_of() {
	sha256sum ${1:+"$1"} 2>/dev/null | awk '{ print $1; exit }'
}
