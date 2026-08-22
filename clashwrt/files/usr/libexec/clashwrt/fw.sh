#!/bin/sh
# SPDX-License-Identifier: GPL-3.0-or-later
#
# clashwrt -- transparent-proxy firewall engine for mihomo on OpenWrt.
#
# Builds one nftables table (inet clashwrt) plus whatever policy routing the
# selected proxy mode needs, driven entirely by UCI (/etc/config/clashwrt).
#
# Four modes, differing only in how TCP and UDP each reach mihomo:
#
#   tproxy        TCP+UDP -> nft tproxy   -> mihomo tproxy-port
#   tproxy_tun    TCP     -> nft tproxy   -> mihomo tproxy-port
#                 UDP     -> fwmark       -> policy route -> tun device
#   tun           TCP+UDP -> fwmark       -> policy route -> tun device
#   redirect_tun  TCP     -> nat dnat     -> mihomo redir-port
#                 UDP     -> fwmark       -> policy route -> tun device
#
# Why four modes exist at all:
#
#   TPROXY is the "correct" transparent proxy mechanism and the only one that
#   preserves the original destination for UDP without a tun device -- but it
#   is broken on some kernels/vendor trees, where the rule matches, marks and
#   routes the packet yet the kernel never delivers it to the IP_TRANSPARENT
#   socket (observed on MediaTek's mtk-openwrt-feeds kernel build: rule
#   counters increment, conntrack sits at SYN_SENT [UNREPLIED], listener sees
#   nothing). NAT redirect always works but cannot do UDP at all -- there is
#   no SO_ORIGINAL_DST for datagrams -- so it has to be paired with a tun
#   device for UDP. A tun device works everywhere but costs throughput
#   (userspace copies every packet). Hence the matrix: pick the fastest
#   mechanism your kernel actually honours for each protocol.
#
# Usage: fw.sh apply|flush|status|check

# Deliberately no `set -u`: OpenWrt's /lib/functions.sh reads IPKG_INSTROOT and
# friends unset, so nounset makes sourcing it abort.
. /lib/functions.sh
. /lib/functions/network.sh

NAME="clashwrt"
TABLE="inet clashwrt"

log() { logger -t "$NAME" "$@"; [ -t 1 ] && echo "$NAME: $*" >&2; return 0; }

# Failures always go to stderr, tty or not: this runs from init scripts, from
# hotplug and from LuCI, and a misconfiguration that explains itself only in
# syslog is a misconfiguration nobody reads.
die() {
	logger -t "$NAME" "ERROR: $*"
	echo "$NAME: ERROR: $*" >&2
	exit 1
}

# ---------------------------------------------------------------------------
# config
# ---------------------------------------------------------------------------

load_cfg() {
	config_load "$NAME"

	config_get enabled       config enabled       0
	config_get mode          config mode          redirect_tun
	config_get lan_device    config lan_device    auto
	config_get wan_device    config wan_device    auto
	config_get tun_device    config tun_device    clash-tun
	config_get mihomo_dir    config mihomo_dir    /etc/mihomo
	config_get self_mark     config self_mark     2
	config_get mark_tproxy   config mark_tproxy   1
	config_get mark_tun      config mark_tun      3
	config_get table_tproxy  config table_tproxy  100
	config_get table_tun     config table_tun     151
	config_get rule_pref     config rule_pref     1002
	config_get tproxy_port   config tproxy_port   ""
	config_get redir_port    config redir_port    ""
	config_get dns_port      config dns_port      1053
	config_get api_port      config api_port      9090
	config_get block_quic    config block_quic    0
	config_get dns_hijack    config dns_hijack    0
	config_get manage_zone   config manage_zone   1
	config_get tun_wait      config tun_wait      10

	config_get bypass_net    config bypass_net    ""
	config_get bypass_src    config bypass_src    ""
	config_get extra_ports   config extra_ports   ""

	MIHOMO_CONF="$mihomo_dir/config.yaml"

	[ -n "$bypass_net" ] || bypass_net="0.0.0.0/8 10.0.0.0/8 100.64.0.0/10 127.0.0.0/8 169.254.0.0/16 172.16.0.0/12 192.168.0.0/16 224.0.0.0/4 240.0.0.0/4"

	resolve_devices
}

# Ask netifd which device currently backs the lan/wan interfaces rather than
# assuming br-lan/eth1. Bridges get renamed, WAN can be a PPPoE or a DSA port,
# and a hardcoded guess silently intercepts nothing (or worse, the wrong
# direction). "auto" is the default; an explicit device in UCI always wins.
resolve_devices() {
	network_flush_cache

	if [ -z "$lan_device" ] || [ "$lan_device" = auto ]; then
		network_get_device lan_device lan || lan_device=""
		[ -n "$lan_device" ] || lan_device="br-lan"
	fi

	if [ -z "$wan_device" ] || [ "$wan_device" = auto ]; then
		network_get_device wan_device wan || wan_device=""
	fi
}

# Read a *top-level* scalar out of mihomo's config.yaml. Strips quotes and
# trailing comments. redir-port/tproxy-port/routing-mark all live at this level.
yaml_top() {
	[ -f "$MIHOMO_CONF" ] || return 1
	sed -n "s/^${1}:[[:space:]]*\([^#]*\).*/\1/p" "$MIHOMO_CONF" \
		| head -n1 | tr -d "\"' \t\r"
}

# Read one key from inside a top-level block, e.g. `device` under `tun:`.
# Good enough for the flat, two-level blocks mihomo uses; a config that nests
# deeper simply yields nothing, and the caller treats that as "unknown".
yaml_in() {
	[ -f "$MIHOMO_CONF" ] || return 1
	awk -v sect="$1:" -v key="$2:" '
		$1 == sect { inside = 1; next }
		inside && /^[^[:space:]#]/ { inside = 0 }
		inside && $1 == key { sub(/#.*/, "", $2); print $2; exit }
	' "$MIHOMO_CONF" | tr -d "\"' \t\r"
}

# mihomo's config.yaml is the source of truth for which ports it listens on,
# so the firewall can never drift from the daemon. UCI may override, for the
# unusual case of a config the parser cannot read (templates, includes).
resolve_ports() {
	[ -n "$tproxy_port" ] || tproxy_port="$(yaml_top tproxy-port)"
	[ -n "$redir_port" ]  || redir_port="$(yaml_top redir-port)"
	: "${tproxy_port:=}"
	: "${redir_port:=}"
}

# Every mode needs mihomo's own listeners excluded from interception, or the
# marking chain redirects mihomo's traffic into mihomo.
mihomo_ports() {
	local p="$dns_port $api_port"
	[ -n "$tproxy_port" ] && p="$p $tproxy_port"
	[ -n "$redir_port" ]  && p="$p $redir_port"
	[ -n "$extra_ports" ] && p="$p $extra_ports"
	echo "$p" | tr ' ' '\n' | grep -v '^$' | sort -un | tr '\n' ',' | sed 's/,$//'
}

nft_set() { echo "$*" | tr ' ' '\n' | grep -v '^$' | tr '\n' ',' | sed 's/,$//'; }

# ---------------------------------------------------------------------------
# preconditions
# ---------------------------------------------------------------------------

mode_needs_tun() {
	case "$mode" in
		tproxy_tun|tun|redirect_tun) return 0 ;;
		*) return 1 ;;
	esac
}

mode_needs_tproxy_port() {
	case "$mode" in
		tproxy|tproxy_tun) return 0 ;;
		*) return 1 ;;
	esac
}

mode_needs_redir_port() {
	[ "$mode" = redirect_tun ]
}

check_prereq() {
	case "$mode" in
		tproxy|tproxy_tun|tun|redirect_tun) ;;
		*) die "unknown mode '$mode' (expected: tproxy, tproxy_tun, tun, redirect_tun)" ;;
	esac

	[ -f "$MIHOMO_CONF" ] || die "mihomo config not found at $MIHOMO_CONF"

	if mode_needs_tproxy_port && [ -z "$tproxy_port" ]; then
		die "mode '$mode' needs 'tproxy-port' in $MIHOMO_CONF (or tproxy_port in UCI)"
	fi
	if mode_needs_redir_port && [ -z "$redir_port" ]; then
		die "mode '$mode' needs 'redir-port' in $MIHOMO_CONF (or redir_port in UCI)"
	fi
	if mode_needs_tun && ! grep -qE '^[[:space:]]*enable:[[:space:]]*true' "$MIHOMO_CONF"; then
		# Only a hint: the key lives under tun: and a flat grep cannot prove
		# which block it belongs to. Wrong-looking configs still get to try.
		log "warning: mode '$mode' needs a tun inbound; no 'enable: true' found in $MIHOMO_CONF"
	fi

	check_config_agrees
	return 0
}

# A config written for another package usually *looks* fine and then does
# nothing, because the two settings that have to agree with the firewall are
# invisible in the symptom. Say so precisely instead of leaving it to guesswork.
check_config_agrees() {
	local conf_mark conf_tun

	# routing-mark is the one that fails silently and total: mihomo tags its
	# own outbound sockets with it, and the marking chain returns early on
	# that mark. Get it wrong and mihomo's connection to the proxy server is
	# itself intercepted and fed back into mihomo, so nothing works at all.
	conf_mark="$(yaml_top routing-mark)"
	if [ -z "$conf_mark" ]; then
		die "$MIHOMO_CONF has no 'routing-mark'. Add 'routing-mark: $self_mark' — without it mihomo's own outbound traffic is intercepted and looped back into mihomo, and nothing works. (OpenClash and ssclash set this for you; here it lives in your config.)"
	fi
	if [ "$conf_mark" != "$self_mark" ]; then
		die "routing-mark in $MIHOMO_CONF is '$conf_mark' but the firewall excludes mark '$self_mark'. Make them match: either set 'routing-mark: $self_mark' in the config, or set self_mark='$conf_mark' in /etc/config/clashwrt."
	fi

	if mode_needs_tun; then
		conf_tun="$(yaml_in tun device)"
		if [ -n "$conf_tun" ] && [ "$conf_tun" != "$tun_device" ]; then
			die "tun.device in $MIHOMO_CONF is '$conf_tun' but /etc/config/clashwrt expects '$tun_device'. Make them match, or UDP is routed to a device that does not exist."
		fi
	fi

	# A stray inbound is not fatal, but it explains "it worked in the other
	# package": those drive mihomo through a different port than this mode does.
	if [ "$mode" = redirect_tun ] && [ -n "$(yaml_top tproxy-port)" ]; then
		log "note: config also has a tproxy-port; mode '$mode' uses redir-port $redir_port"
	fi
	if mode_needs_tproxy_port && [ -n "$(yaml_top redir-port)" ]; then
		log "note: config also has a redir-port; mode '$mode' uses tproxy-port $tproxy_port"
	fi
	return 0
}

# The tun device only exists once mihomo has started and created it, which
# races with our own start. Wait briefly rather than failing outright.
wait_for_tun() {
	local i=0
	while [ "$i" -lt "$tun_wait" ]; do
		ip link show "$tun_device" >/dev/null 2>&1 && return 0
		i=$((i + 1))
		sleep 1
	done
	return 1
}

# ---------------------------------------------------------------------------
# fw4 integration
# ---------------------------------------------------------------------------
#
# Traffic entering or leaving the tun device is *forwarded* traffic as far as
# the kernel is concerned, so fw4's own "forward" chain judges it -- and that
# chain is policy drop with an explicit reject at the end. Note that an accept
# in some other table does NOT save the packet: nftables evaluates every base
# chain registered on a hook, in priority order, and an earlier chain's accept
# does not stop a later chain on the same hook from rejecting the same packet.
# That is exactly why "it counts on our chain but tcpdump on the tun sees
# nothing" happens, and why the fix has to live inside fw4 itself.
#
# The clean way to do that is a real fw4 zone in UCI: fw4 then generates and
# regenerates the rules itself, so they survive every firewall reload without
# us re-inserting anything. (The alternative -- nft insert into inet fw4
# forward -- works but is wiped on each fw4 reload, needing a cron babysitter.)

zone_has_tun=0
_zone_cb() {
	local cfg="$1" name devices
	config_get name "$cfg" name
	config_get devices "$cfg" device
	case " $devices " in
		*" $tun_device "*) zone_has_tun=1; ZONE_NAME="$name" ;;
	esac
}

ensure_fw4_zone() {
	[ "$manage_zone" = 1 ] || return 0
	mode_needs_tun || return 0

	zone_has_tun=0
	ZONE_NAME=""
	config_load firewall
	config_foreach _zone_cb zone
	config_load "$NAME"

	[ "$zone_has_tun" = 1 ] && return 0

	log "adding fw4 zone for $tun_device"
	local z
	z="$(uci -q add firewall zone)" || { log "could not add firewall zone"; return 1; }
	uci -q set    firewall."$z".name='mihomo'
	uci -q add_list firewall."$z".device="$tun_device"
	uci -q set    firewall."$z".input='ACCEPT'
	uci -q set    firewall."$z".output='ACCEPT'
	uci -q set    firewall."$z".forward='ACCEPT'
	uci -q set    firewall."$z".masq='0'
	uci -q set    firewall."$z".mtu_fix='1'

	local f
	f="$(uci -q add firewall forwarding)"
	uci -q set firewall."$f".src='lan'
	uci -q set firewall."$f".dest='mihomo'

	local g
	g="$(uci -q add firewall forwarding)"
	uci -q set firewall."$g".src='mihomo'
	uci -q set firewall."$g".dest='wan'

	uci -q commit firewall
	/etc/init.d/firewall reload >/dev/null 2>&1
	log "fw4 zone 'mihomo' created for $tun_device"
}

# ---------------------------------------------------------------------------
# nftables
# ---------------------------------------------------------------------------

build_bypass() {
	# Rules shared by every mode: never touch mihomo's own traffic, traffic
	# that is not from the LAN, link-local infrastructure, or destinations
	# that must stay local. Order matters -- these all "return" before any
	# marking happens.
	nft add rule $TABLE mangle meta mark "$self_mark" return
	nft add rule $TABLE mangle iifname != "$lan_device" return

	local ports
	ports="$(mihomo_ports)"
	[ -n "$ports" ] && {
		nft add rule $TABLE mangle tcp dport "{ $ports }" return
		nft add rule $TABLE mangle udp dport "{ $ports }" return
	}

	# DHCP must never be proxied or the LAN cannot get addresses.
	nft add rule $TABLE mangle udp sport 67 udp dport 68 return
	nft add rule $TABLE mangle udp sport 68 udp dport 67 return

	local nets
	nets="$(nft_set $bypass_net)"
	[ -n "$nets" ] && nft add rule $TABLE mangle ip daddr "{ $nets }" return

	local srcs
	srcs="$(nft_set $bypass_src)"
	[ -n "$srcs" ] && nft add rule $TABLE mangle ip saddr "{ $srcs }" return

	# QUIC carries HTTP/3 over UDP/443. Rejecting it makes browsers fall back
	# to TCP, which is worth doing only when UDP is not proxied well.
	[ "$block_quic" = 1 ] && nft add rule $TABLE mangle meta l4proto udp udp dport 443 reject

	# Send LAN DNS at mihomo's resolver instead of whatever the client asked
	# for. Off by default: most setups already point dnsmasq at mihomo.
	[ "$dns_hijack" = 1 ] && {
		nft add chain $TABLE dns_nat "{ type nat hook prerouting priority dstnat - 5 ; }"
		nft add rule $TABLE dns_nat iifname "$lan_device" meta l4proto { tcp, udp } th dport 53 \
			dnat ip to "127.0.0.1:$dns_port"
	}
	return 0
}

apply_nft() {
	nft delete table $TABLE 2>/dev/null
	nft add table $TABLE

	# priority mangle(-150) so we see packets before conntrack/dstnat decide
	nft add chain $TABLE mangle "{ type filter hook prerouting priority mangle ; }"
	build_bypass

	case "$mode" in
	tproxy)
		nft add rule $TABLE mangle meta l4proto tcp meta mark set "$mark_tproxy" \
			tproxy ip to "127.0.0.1:$tproxy_port" accept
		nft add rule $TABLE mangle meta l4proto udp meta mark set "$mark_tproxy" \
			tproxy ip to "127.0.0.1:$tproxy_port" accept
		;;
	tproxy_tun)
		nft add rule $TABLE mangle meta l4proto tcp meta mark set "$mark_tproxy" \
			tproxy ip to "127.0.0.1:$tproxy_port" accept
		nft add rule $TABLE mangle meta l4proto udp meta mark set "$mark_tun"
		;;
	tun)
		nft add rule $TABLE mangle meta l4proto tcp meta mark set "$mark_tun"
		nft add rule $TABLE mangle meta l4proto udp meta mark set "$mark_tun"
		;;
	redirect_tun)
		nft add rule $TABLE mangle meta l4proto tcp meta mark set "$mark_tproxy"
		nft add rule $TABLE mangle meta l4proto udp meta mark set "$mark_tun"

		# DNAT explicitly to 127.0.0.1 rather than "redirect to :port":
		# redirect targets the *inbound interface's own address*, but with
		# allow-lan:false mihomo only listens on loopback, so redirect lands
		# on a closed port. Loopback DNAT needs route_localnet=1 (set below).
		# Ahead of fw4's own dstnat chain (priority dstnat, -100): whichever
		# nat chain acts first owns the translation, so interception has to
		# win the race against any port forwards fw4 may install.
		nft add chain $TABLE nat_pre "{ type nat hook prerouting priority dstnat - 40 ; }"
		nft add rule $TABLE nat_pre meta mark "$mark_tproxy" meta l4proto tcp \
			dnat ip to "127.0.0.1:$redir_port"
		;;
	esac
	return 0
}

# ---------------------------------------------------------------------------
# policy routing
# ---------------------------------------------------------------------------

flush_rules() {
	local mark
	for mark in "$mark_tproxy" "$mark_tun"; do
		while ip rule del fwmark "$mark" 2>/dev/null; do :; done
	done
	ip route flush table "$table_tproxy" 2>/dev/null
	ip route flush table "$table_tun" 2>/dev/null
	return 0
}

apply_routing() {
	flush_rules

	case "$mode" in
	tproxy|tproxy_tun)
		# TPROXY needs the marked packet delivered *locally* even though its
		# destination is remote; a "local" route in a dedicated table is what
		# makes the stack hand it to the transparent socket.
		ip rule add fwmark "$mark_tproxy" table "$table_tproxy" pref "$rule_pref"
		ip route replace local default dev lo table "$table_tproxy"
		;;
	esac

	if mode_needs_tun; then
		if ! wait_for_tun; then
			log "warning: $tun_device did not appear within ${tun_wait}s; UDP will stay unproxied until it does"
			log "hotplug will re-apply automatically once mihomo creates it"
			return 0
		fi
		ip rule add fwmark "$mark_tun" table "$table_tun" pref "$((rule_pref + 1))"
		ip route replace default dev "$tun_device" table "$table_tun"
	fi

	# DNAT to a loopback address is dropped by the martian filter unless this
	# is on. Needed by redirect_tun; harmless elsewhere.
	sysctl -q -w net.ipv4.conf.all.route_localnet=1
	sysctl -q -w "net.ipv4.conf.${lan_device}.route_localnet=1" 2>/dev/null
	return 0
}

# ---------------------------------------------------------------------------
# actions
# ---------------------------------------------------------------------------

do_apply() {
	load_cfg
	[ "$enabled" = 1 ] || { log "disabled in UCI, nothing to do"; do_flush_quiet; exit 0; }
	resolve_ports
	check_prereq
	ensure_fw4_zone
	apply_nft
	apply_routing
	log "applied mode=$mode lan=$lan_device tun=$tun_device tproxy_port=${tproxy_port:-none} redir_port=${redir_port:-none}"
}

do_flush_quiet() {
	nft delete table $TABLE 2>/dev/null
	flush_rules
}

do_flush() {
	load_cfg
	do_flush_quiet
	log "flushed"
}

do_status() {
	load_cfg
	resolve_ports
	echo "enabled:      $enabled"
	echo "mode:         $mode"
	echo "lan_device:   $lan_device"
	echo "wan_device:   ${wan_device:-unknown}"
	echo "tun_device:   $tun_device"
	echo "tproxy_port:  ${tproxy_port:-none}"
	echo "redir_port:   ${redir_port:-none}"
	echo -n "nft_table:    "
	nft list table $TABLE >/dev/null 2>&1 && echo present || echo absent
	echo -n "tun_link:     "
	ip link show "$tun_device" >/dev/null 2>&1 && echo up || echo absent
	echo -n "tun_route:    "
	ip route show table "$table_tun" 2>/dev/null | grep -q "dev $tun_device" && echo ok || echo missing
	echo -n "mihomo:       "
	pidof mihomo >/dev/null 2>&1 && echo running || echo stopped
}

# Re-apply only the pieces that go stale on their own, without tearing the
# ruleset down. The tun route is interface-scoped, so the kernel silently
# drops it whenever the tun device is destroyed and recreated -- which is
# every mihomo restart. An empty table does not error: marked packets simply
# fall through to the main table and leave unproxied, with mihomo never
# seeing them. That failure looks exactly like success from the client side,
# so it is worth repairing eagerly.
do_check() {
	load_cfg
	[ "$enabled" = 1 ] || exit 0
	resolve_ports

	nft list table $TABLE >/dev/null 2>&1 || { log "nft table missing, re-applying"; do_apply; exit 0; }

	if mode_needs_tun && ip link show "$tun_device" >/dev/null 2>&1; then
		ip route show table "$table_tun" 2>/dev/null | grep -q "dev $tun_device" || {
			ip route replace default dev "$tun_device" table "$table_tun"
			ip rule show | grep -q "fwmark $(printf '0x%x' "$mark_tun") " || \
				ip rule add fwmark "$mark_tun" table "$table_tun" pref "$((rule_pref + 1))"
			log "restored table $table_tun route after $tun_device was recreated"
		}
	fi
}

# What netifd currently reports, so the UI can show what "auto" resolved to.
do_detect() {
	load_cfg
	echo "lan_device: $lan_device"
	echo "wan_device: ${wan_device:-unknown}"
}

case "${1:-}" in
	apply)    do_apply ;;
	flush)    do_flush ;;
	status)   do_status ;;
	check)    do_check ;;
	detect)   do_detect ;;
	selftest) exec /usr/libexec/clashwrt/selftest.sh ;;
	*) echo "usage: $0 apply|flush|status|check|detect|selftest" >&2; exit 1 ;;
esac
