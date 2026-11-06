#!/bin/sh
# SPDX-License-Identifier: GPL-3.0-or-later
#
# The core's REST API, for the LuCI "Proxies" page: a dashboard of its own
# for routers with no room for a web one (meow-openwrt tiny on 16 MB flash).
# The router asks, not the browser, so the controller may listen on
# 127.0.0.1 only and its secret never leaves the router.
#
# Usage: apictl.sh proxies              GET /proxies, as JSON
#        apictl.sh select <group> <name> picks a node in a selector group
#        apictl.sh delay <group>         times every node of a group, as JSON

DIR="$(uci -q get clashwrt.config.mihomo_dir)"
CONF="${CLASHWRT_CONF:-${DIR:-/etc/mihomo}/config.yaml}"

die() { echo "ERROR: $*" >&2; exit 1; }

# the same reading of external-controller and secret as confctl.sh
api_base() {
	local ctl port host
	ctl="$(sed -n 's/^external-controller:[ \t]*//p' "$CONF" | head -n1 | tr -d "\"'" | sed 's/[ \t]*#.*//')"
	port="${ctl##*:}"
	case "$port" in ''|*[!0-9]*) return 1 ;; esac
	host="${ctl%:*}"
	case "$host" in ''|0.0.0.0|'[::]'|::) host=127.0.0.1 ;; esac
	echo "http://$host:$port"
}

api_secret() {
	sed -n 's/^secret:[ \t]*//p' "$CONF" | head -n1 | sed 's/[ \t]#.*//; s/^["'"'"']//; s/["'"'"'][ \t]*$//'
}

# every byte as %XX, as watchdog.sh does it (busybox has no od)
urlenc() {
	local LC_ALL=C s="$1" rest c v
	while [ -n "$s" ]; do
		rest="${s#?}"
		c="${s%"$rest"}"
		s="$rest"
		case "$c" in
			[!\ -~])
				v="$(printf '%02x' "'$c")"
				printf '%%%s' "${v#"${v%??}"}"
				;;
			*) printf '%%%02x' "'$c" ;;
		esac
	done
}

api() {
	local base secret
	base="$(api_base)" || die "no external-controller in $CONF"
	secret="$(api_secret)"
	curl -sS -f -m "${API_TIMEOUT:-10}" ${secret:+-H "Authorization: Bearer $secret"} "$@" "$base$API_PATH" ||
		die "the core did not answer (is it running?)"
}

case "${1:-}" in
	proxies)
		API_PATH=/proxies api
		;;
	select)
		[ -n "${2:-}" ] && [ -n "${3:-}" ] || die "usage: $0 select <group> <name>"
		name="$(printf '%s' "$3" | sed 's/\\/\\\\/g; s/"/\\"/g')"
		API_PATH="/proxies/$(urlenc "$2")" api -X PUT -H 'Content-Type: application/json' -d "{\"name\":\"$name\"}" >/dev/null
		echo "selected"
		;;
	delay)
		[ -n "${2:-}" ] || die "usage: $0 delay <group>"
		API_TIMEOUT=20 API_PATH="/group/$(urlenc "$2")/delay?url=$(urlenc "${3:-https://www.gstatic.com/generate_204}")&timeout=5000" api
		;;
	*)
		die "usage: $0 proxies | select <group> <name> | delay <group>"
		;;
esac
