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
# ...and "auto", which works the pairing out instead of asking for it. The
# direction is not a preference: the set holds the exceptions to whatever
# mihomo does by default, so the default decides which way round it goes.
# mihomo states that default in one line -- its terminal MATCH rule -- and
# reading it is exact where guessing from the addresses would not be.
#
# Usage: setctl.sh update [force] | load | status | clear | sources
#        setctl.sh direction | detect

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
	config_get mihomo_dir   config mihomo_dir          /etc/mihomo

	MIHOMO_CONF="$mihomo_dir/config.yaml"

	# Kept apart from set_mode so status can show both what was configured
	# and what it came out as.
	set_mode_raw="$set_mode"
	set_mode_why=""

	# Resolved softly: 'status' and 'detect' exist to explain a failure here,
	# so load_cfg must not be what stops them from running. An unresolved
	# 'auto' leaves set_mode empty, and require_direction() is what refuses.
	if [ "$set_mode" = "auto" ]; then
		if detect_direction; then
			set_mode="$DETECT_DIR"
			set_mode_why="$DETECT_WHY"
		else
			set_mode=""
			set_mode_why=""
		fi
	fi
}

# Anything about to build a rule or fetch a list needs a real direction.
require_direction() {
	[ -n "$set_mode" ] && return 0
	die "$(detect_failure_message)"
}

# Which way round the set goes, worked out rather than asked for.
#
# The set holds the exceptions to mihomo's default, so the default is what
# decides the direction. If everything is proxied unless a rule says otherwise,
# the list is what comes out of the proxy -- exclude. If everything is direct
# unless a rule says otherwise, the list is what goes into it -- include.
#
# mihomo states that default in exactly one place: the terminal MATCH rule at
# the end of its rules. Reading it is exact, and it is the only source that is
# also right for a config somebody wrote by hand. The wizard's stored answer
# says the same thing, but only if the wizard is what wrote the config, so it
# is the fallback and not the first choice.
#
# Answers through DETECT_DIR and DETECT_WHY rather than through stdout: every
# caller wants the evidence as well as the verdict, and $(...) would run this
# in a subshell where a second variable could not come back. DETECT_WHY exists
# at all because an automatic decision nobody can see the reasoning for is
# worse than a question.
DETECT_DIR=""
DETECT_WHY=""

detect_direction() {
	DETECT_DIR=""
	DETECT_WHY=""

	local last=""
	if [ -f "$MIHOMO_CONF" ]; then
		# Only list entries: a commented-out "# - MATCH,DIRECT" must not count,
		# and neither must the word appearing in prose.
		last="$(sed -n 's/^[[:space:]]*-[[:space:]]*MATCH,[[:space:]]*\([^ ,#]*\).*/\1/p' \
			"$MIHOMO_CONF" 2>/dev/null | tail -n1)"
	fi

	case "$last" in
		DIRECT)
			DETECT_WHY="MATCH,DIRECT in $MIHOMO_CONF"
			DETECT_DIR=include; return 0 ;;
		# REJECT means the default is to drop, which is neither direction.
		REJECT|"")
			;;
		*)
			DETECT_WHY="MATCH,$last in $MIHOMO_CONF"
			DETECT_DIR=exclude; return 0 ;;
	esac

	case "$(uci -q get "$NAME".wizard.routing)" in
		direct_except_list)
			DETECT_WHY="the wizard's routing strategy (direct except the lists)"
			DETECT_DIR=include; return 0 ;;
		proxy_except_ru)
			DETECT_WHY="the wizard's routing strategy (proxy except Russia)"
			DETECT_DIR=exclude; return 0 ;;
	esac

	return 1
}

# Say which two things failed to answer and what to do about it, in the shape
# fw.sh uses for the config disagreements it refuses to guess through.
detect_failure_message() {
	if [ ! -f "$MIHOMO_CONF" ]; then
		echo "bypass_set_mode is 'auto', but $MIHOMO_CONF does not exist yet, so there is no default routing to read the direction from. Run the setup wizard, or set bypass_set_mode to 'exclude' (the listed addresses go direct) or 'include' (only the listed addresses are intercepted)."
		return 0
	fi
	echo "bypass_set_mode is 'auto', but $MIHOMO_CONF has no terminal 'MATCH' rule to read the default routing from, and no wizard answer is stored either. Add a MATCH rule to the end of your rules (MATCH,DIRECT or MATCH,<your proxy group>), or set bypass_set_mode to 'exclude' or 'include' explicitly."
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
	echo "ru	exclude	Russian networks (ipdeny)"
	echo "ru-geoip	exclude	Russian networks (meta-rules-dat geoip)"
	echo "refilter	include	Re-filter blocked IP ranges"
	echo "custom	any	A URL of your own"
}

# Which direction a list is meant for. Getting this backwards is not a subtle
# misconfiguration: re-filter is a list of addresses that are *blocked* in
# Russia, so putting it behind "exclude" would send exactly the traffic that
# needs the proxy straight out the WAN instead. The reverse is just as wrong --
# "include" on a list of Russian networks would proxy the one thing that has no
# reason to be proxied and send everything else direct.
intended_mode() {
	case "$1" in
		ru|ru-geoip) echo "exclude" ;;
		refilter)    echo "include" ;;
		*)           echo "any" ;;
	esac
}

check_pairing() {
	local want
	want="$(intended_mode "$set_source")"
	[ "$want" = "any" ] && return 0

	# Nothing to disagree with: 'auto' derived the direction from the routing
	# rather than being told it.
	[ "$set_mode_raw" = "auto" ] || {
		[ "$want" = "$set_mode" ] && return 0

		if [ "$set_source" = "refilter" ]; then
			die "'refilter' lists addresses that are blocked in Russia, so they are what needs the proxy. Use it with mode 'include' (intercept only these), not '$set_mode'."
		fi
		die "'$set_source' lists Russian networks, which is what should skip the proxy. Use it with mode 'exclude' (these bypass), not '$set_mode'."
	}
	return 0
}

# A preset and a direction can agree with each other and still both be wrong
# for the routing actually configured -- 'refilter' with mode 'include' is a
# valid pair, and useless against a config that proxies everything by default,
# because then the set turns off the proxy for all the traffic not on the list.
# The old check could not see that; it only compared the list against the mode.
#
# This one warns rather than refusing. The detected routing is evidence, not
# authority: a config the parser read wrongly, or a deliberate arrangement,
# should not be able to stop a list from refreshing.
check_against_routing() {
	local want detected
	want="$(intended_mode "$set_source")"
	[ "$want" = "any" ] && return 0
	[ "$set_mode_raw" = "auto" ] && return 0

	detect_direction || return 0
	detected="$DETECT_DIR"
	[ "$detected" = "$set_mode" ] && return 0

	log "WARNING: '$set_source' is set to '$set_mode', but $DETECT_WHY says the direction should be '$detected'. As configured, the proxy is skipped for the traffic that needs it."
	return 0
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
	[ "$set_mode_raw" = "off" ] && { log "bypass set disabled"; return 0; }
	require_direction

	check_pairing
	check_against_routing

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
	[ "$set_mode_raw" = "off" ] && return 0
	require_direction
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
	if [ "$set_mode_raw" != "auto" ]; then
		echo "mode:     $set_mode"
	elif [ -n "$set_mode" ]; then
		echo "mode:     auto -> $set_mode ($set_mode_why)"
	else
		echo "mode:     auto -> undecided"
		echo "WARNING:  $(detect_failure_message)"
	fi
	echo "source:   $set_source"
	if [ "$set_mode" != "off" ] && [ -n "$set_mode" ]; then
		want="$(intended_mode "$set_source")"
		if [ "$want" != "any" ] && [ "$want" != "$set_mode" ]; then
			echo "WARNING:  this list is meant for mode '$want' -- the current pairing sends the wrong traffic through the proxy"
		fi
		if detect_direction && [ "$DETECT_DIR" != "$set_mode" ]; then
			echo "WARNING:  $DETECT_WHY says the direction should be '$DETECT_DIR', not '$set_mode'"
		fi
	fi
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

# Just the answer, for fw.sh, which builds the nft rule from it and has no
# use for the reasoning.
do_direction() {
	load_cfg
	[ "$set_mode_raw" = "off" ] && { echo "off"; return 0; }
	require_direction
	echo "$set_mode"
}

# The answer with its evidence, for the settings page. Reports on 'auto'
# whether or not it is what is configured, so the page can show what would
# happen before anyone commits to it.
do_detect() {
	load_cfg
	if detect_direction; then
		echo "direction: $DETECT_DIR"
		echo "from:      $DETECT_WHY"
	else
		echo "direction: unknown"
		echo "from:      $(detect_failure_message)"
	fi
	echo "configured: $set_mode_raw"
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
	direction) do_direction ;;
	detect)  do_detect ;;
	*) echo "usage: $0 update [force] | load | status | clear | sources | direction | detect" >&2; exit 1 ;;
esac
