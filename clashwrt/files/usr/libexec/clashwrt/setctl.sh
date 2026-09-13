#!/bin/sh
# SPDX-License-Identifier: GPL-3.0-or-later
#
# Maintains the nftables set that decides, before any marking happens, which
# destinations skip the proxy entirely.
#
# mihomo can do this itself with route-exclude-address-set, but only when it
# owns the firewall: that option requires auto-route and auto-redirect and is
# incompatible with routing-mark, which is exactly the arrangement ClashWrt
# does not use -- the four interception modes exist because mihomo's own
# routing cannot be relied on. So the same idea is implemented here instead,
# where it costs nothing architecturally.
#
# Why it matters: a DIRECT rule inside mihomo is not a fast path. The
# connection still terminates on the router and is relayed through userspace,
# which costs throughput and also collapses every device behind one address,
# so a shaper like cake can no longer tell hosts apart. Traffic excluded here
# never reaches mihomo at all.
#
# Two modes, mirroring mihomo's own pair:
#
#   exclude  listed destinations bypass the proxy, everything else is
#            intercepted. Pair with "everything through the proxy except
#            Russia": the list is Russian networks.
#
#   include  only listed destinations are intercepted, everything else
#            bypasses. Pair with "everything direct except the lists": the
#            list is what actually needs a proxy.
#
# Usage: setctl.sh update [force] | load | status | clear | sources

. /lib/functions.sh

NAME="clashwrt"
TABLE="inet clashwrt"
SET4="bypass4"
STATE_DIR="/etc/clashwrt"
LIST="$STATE_DIR/bypass4.list"
STAMP="$STATE_DIR/bypass4.stamp"

log() { logger -t "$NAME" "$@"; [ -t 1 ] && echo "$NAME: $*" >&2; return 0; }
die() { logger -t "$NAME" "ERROR: $*"; echo "$NAME: ERROR: $*" >&2; exit 1; }

load_cfg() {
	config_load "$NAME"
	config_get set_mode     config bypass_set_mode     off
	config_get set_source   config bypass_set_source   ru
	config_get set_url      config bypass_set_url      ""
	config_get set_interval config bypass_set_interval 86400
}

# Presets are plain-CIDR-per-line or a YAML payload list; both parse the same
# way, so a custom URL in either shape works too.
source_url() {
	case "$1" in
		ru)        echo "https://www.ipdeny.com/ipblocks/data/countries/ru.zone" ;;
		ru-geoip)  echo "https://raw.githubusercontent.com/MetaCubeX/meta-rules-dat/refs/heads/meta/geo/geoip/ru.yaml" ;;
		refilter)  echo "https://github.com/1andrevich/Re-filter-lists/releases/latest/download/ipsum.lst" ;;
		custom)    echo "$set_url" ;;
		*)         return 1 ;;
	esac
}

do_sources() {
	echo "ru	Russian networks (ipdeny)"
	echo "ru-geoip	Russian networks (meta-rules-dat geoip)"
	echo "refilter	Re-filter blocked IP ranges"
	echo "custom	A URL of your own"
}

# Accepts both a bare CIDR list and a YAML "payload:" list, keeps only well
# formed IPv4 networks, and drops anything else rather than feeding nft a line
# it will refuse -- one bad entry would otherwise abort the whole load.
parse_list() {
	sed -e 's/#.*//' -e 's/^[[:space:]]*-[[:space:]]*//' -e 's/[[:space:]]//g' \
		-e "s/['\"]//g" \
	| grep -E '^([0-9]{1,3}\.){3}[0-9]{1,3}(/[0-9]{1,2})?$' \
	| awk '!seen[$0]++'
}

do_update() {
	load_cfg
	[ "$set_mode" = "off" ] && { log "bypass set disabled"; return 0; }

	local url
	url="$(source_url "$set_source")" || die "unknown source '$set_source'"
	[ -n "$url" ] || die "source 'custom' selected but bypass_set_url is empty"

	if [ "${1:-}" != "force" ] && [ -f "$STAMP" ] && [ -s "$LIST" ]; then
		local age now
		now="$(date +%s)"
		age=$((now - $(cat "$STAMP" 2>/dev/null || echo 0)))
		if [ "$age" -lt "$set_interval" ]; then
			log "list is ${age}s old, below the ${set_interval}s interval; not refetching"
			return 0
		fi
	fi

	mkdir -p "$STATE_DIR"
	local tmp="/tmp/clashwrt-set.$$"
	log "fetching $url"
	if ! curl -sSL --fail -m 180 -o "$tmp" "$url"; then
		rm -f "$tmp"
		# keep whatever we had: an empty set would silently proxy everything
		[ -s "$LIST" ] && { log "download failed, keeping the previous list"; return 0; }
		die "download failed and no previous list exists"
	fi

	parse_list < "$tmp" > "$tmp.parsed"
	rm -f "$tmp"

	local n
	n="$(grep -c . "$tmp.parsed" 2>/dev/null || echo 0)"
	if [ "$n" -lt 10 ]; then
		rm -f "$tmp.parsed"
		[ -s "$LIST" ] && { log "only $n networks parsed, keeping the previous list"; return 0; }
		die "only $n networks parsed from $url -- wrong format?"
	fi

	mv "$tmp.parsed" "$LIST"
	date +%s > "$STAMP"
	log "stored $n networks in $LIST"
	do_load
}

# Elements are loaded from one generated script rather than a call per entry:
# these lists run to tens of thousands of networks and per-element nft calls
# take minutes.
do_load() {
	load_cfg
	[ "$set_mode" = "off" ] && return 0
	nft list table $TABLE >/dev/null 2>&1 || { log "table not present yet; nothing to load into"; return 0; }
	[ -s "$LIST" ] || { log "no list to load"; return 0; }

	local f="/tmp/clashwrt-set-load.$$"
	{
		echo "flush set $TABLE $SET4"
		echo "add element $TABLE $SET4 {"
		awk 'NR>1{printf ",\n"} {printf "  %s", $0}' "$LIST"
		echo ""
		echo "}"
	} > "$f"

	if nft -f "$f" 2>/dev/null; then
		log "loaded $(grep -c . "$LIST") networks into $SET4"
		rm -f "$f"
		return 0
	fi
	rm -f "$f"
	log "WARNING: could not load the set"
	return 1
}

do_status() {
	load_cfg
	echo "mode:     $set_mode"
	echo "source:   $set_source"
	echo "url:      $(source_url "$set_source" 2>/dev/null)"
	echo "list:     $([ -s "$LIST" ] && grep -c . "$LIST" || echo 0) networks"
	if [ -f "$STAMP" ]; then
		echo "updated:  $(( ( $(date +%s) - $(cat "$STAMP") ) / 60 )) minutes ago"
	else
		echo "updated:  never"
	fi
	echo -n "in_kernel: "
	nft list set $TABLE $SET4 2>/dev/null | grep -c "elements" >/dev/null 2>&1 \
		&& nft list set $TABLE $SET4 2>/dev/null | tr -cd ',' | wc -c | awk '{print $1+1" entries"}' \
		|| echo "set not present"
}

do_clear() {
	rm -f "$LIST" "$STAMP"
	nft flush set $TABLE $SET4 2>/dev/null
	log "cleared"
}

case "${1:-}" in
	update)  do_update "${2:-}" ;;
	load)    do_load ;;
	status)  do_status ;;
	clear)   do_clear ;;
	sources) do_sources ;;
	*) echo "usage: $0 update [force] | load | status | clear | sources" >&2; exit 1 ;;
esac
