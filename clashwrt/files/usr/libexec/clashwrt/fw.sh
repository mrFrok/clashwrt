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
# and a fifth, where the core does it all itself:
#
#   auto_redirect meow-openwrt's tun.auto-redirect: the core installs its own
#                 table (inet meow) and policy rules, and with
#                 route-address-dns captures only what its rules proxy.
#                 ClashWrt writes the keys and switches it (see "the core's
#                 own capture" below).
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
# Usage: fw.sh apply|reload|flush|status|check|detect|selftest
#        fw.sh dns-sync
#        fw.sh autobypass on|off
#        fw.sh core-sync [--no-reload] | hotplug

# Deliberately no `set -u`: OpenWrt's /lib/functions.sh reads IPKG_INSTROOT and
# friends unset, so nounset makes sourcing it abort.
# The CLASHWRT_* overrides exist so tests/ can run this file off the router.
# shellcheck source=/dev/null
. "${CLASHWRT_FUNCTIONS:-/lib/functions.sh}"
# shellcheck source=/dev/null
. "${CLASHWRT_NETWORK:-/lib/functions/network.sh}"

NAME="clashwrt"
TABLE="inet clashwrt"

# Written by the watchdog (through 'autobypass on') when the proxy path is
# dead but the WAN is fine. While it exists apply and check build nothing, so
# a restart or a hotplug event cannot quietly put the broken path back. It
# lives in /var/run on purpose: a reboot starts proxy-first again.
RUNDIR="${CLASHWRT_RUNDIR:-/var/run/clashwrt}"
FLAG="$RUNDIR/autobypass"
LOCKFILE="/var/lock/clashwrt-fw.lock"
SIGFILE="$RUNDIR/fw.sig"
RCD="${CLASHWRT_RCD:-/etc/rc.d}"

log() { logger -t "$NAME" "$@"; [ -t 1 ] && echo "$NAME: $*" >&2; return 0; }

# Switched off from the Overview page ('powerctl.sh svc off') means not
# started at boot, i.e. no S link; that is all /etc/rc.d acts on.
svc_enabled() { ls "$RCD"/S[0-9][0-9]"$NAME" >/dev/null 2>&1; }

wd_running() {
	local pid
	pid="$(sed -n 's/^pid:[[:space:]]*//p' "$RUNDIR/watchdog.state" 2>/dev/null | head -n1)"
	case "$pid" in ''|*[!0-9]*) return 1 ;; esac
	# the pid must still be the watchdog, not whatever reused the number
	tr '\0' ' ' < "/proc/$pid/cmdline" 2>/dev/null | grep -q 'watchdog.sh run'
}

# Failures always go to stderr, tty or not: this runs from init scripts, from
# hotplug and from LuCI, and a misconfiguration that explains itself only in
# syslog is a misconfiguration nobody reads.
die() {
	logger -t "$NAME" "ERROR: $*"
	echo "$NAME: ERROR: $*" >&2
	exit 1
}

# Every action that changes the ruleset takes one lock, so the watchdog, the
# init script, hotplug and LuCI cannot interleave a flush with an apply.
# The lock code lives in lock.sh and is shared with powerctl.sh; the lock
# files are not: powerctl holds its own while it calls this script, which
# then takes this one, so one file would be a deadlock.
# shellcheck source=lock.sh
. "${CLASHWRT_LIBEXEC:-/usr/libexec/clashwrt}/lock.sh"
fw_lock() { cw_lock "$LOCKFILE" 30 firewall; }

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
	config_get block_ipv6    config block_ipv6    1
	config_get block_dot     config block_dot     1
	config_get wd_action     config watchdog_action direct
	config_get block_doh     config block_doh     1
	config_get doh_extra     config doh_extra     ""
	config_get api_port      config api_port      9090
	config_get block_quic    config block_quic    1
	config_get dns_hijack    config dns_hijack    0
	config_get manage_zone   config manage_zone   1
	config_get tun_wait      config tun_wait      10

	config_get bypass_net    config bypass_net    ""
	config_get bypass_src    config bypass_src    ""
	config_get extra_ports   config extra_ports   ""
	config_get set_mode      config bypass_set_mode off

	MIHOMO_CONF="$mihomo_dir/config.yaml"

	# 'auto' works the direction out from mihomo's own default routing.
	# setctl.sh owns that, rather than a second copy of the same reading
	# living here and drifting from it. An answer it cannot give leaves the
	# set out of the ruleset entirely: a rule built on a guess would send the
	# wrong half of the traffic past the proxy, which is worse than no rule.
	# setctl.sh is asked for every mode, not only 'auto': it is also what
	# holds a set built from config.yaml back when the set could not cover
	# everything config.yaml proxies.
	# The core's own capture has no set of ours; setctl.sh core-routes says
	# what it narrows to instead.
	[ "$mode" = auto_redirect ] && set_mode="core"
	if [ "$set_mode" != "off" ] && [ "$set_mode" != "core" ]; then
		set_mode="$(/usr/libexec/clashwrt/setctl.sh direction 2>/dev/null)" || set_mode=""
		case "$set_mode" in
			exclude|include|off) ;;
			*)
				log "bypass set is 'auto' but the direction could not be determined; leaving it out (run 'setctl.sh detect' to see why)"
				set_mode="off"
				;;
		esac
	fi

	[ -n "$bypass_net" ] || bypass_net="0.0.0.0/8 10.0.0.0/8 100.64.0.0/10 127.0.0.0/8 169.254.0.0/16 172.16.0.0/12 192.168.0.0/16 224.0.0.0/4 240.0.0.0/4"

	resolve_devices
}

# Ask netifd which device currently backs the lan/wan interfaces rather than
# assuming br-lan/eth1. Bridges get renamed, WAN can be a PPPoE or a DSA port,
# and a hardcoded guess silently intercepts nothing (or worse, the wrong
# direction). "auto" is the default; an explicit device in UCI always wins.
resolve_devices() {
	network_flush_cache

	# lan_device is a list: devices (br-lan, br-guest) or logical networks
	# (lan, guest), 'auto' meaning the network 'lan'. Every one is
	# intercepted; the first is what single-device callers get.
	local d dev out=""
	[ -n "$lan_device" ] || lan_device=auto
	for d in $lan_device; do
		dev=""
		case "$d" in
			auto) network_get_device dev lan || dev=""; [ -n "$dev" ] || dev=br-lan ;;
			*) network_get_device dev "$d" 2>/dev/null || dev=""; [ -n "$dev" ] || dev="$d" ;;
		esac
		case " $out " in *" $dev "*) ;; *) out="${out:+$out }$dev" ;; esac
	done
	lan_devices="$out"
	lan_device="${out%% *}"
	# as nft writes a set of interface names: { "br-lan", "br-guest" }
	lan_set="{ $(echo "$out" | sed 's/[^ ][^ ]*/"&"/g; s/ /, /g') }"

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

# Which modes the installed config.yaml can actually serve.
#
# The mode in UCI decides what the firewall builds; the inbounds in config.yaml
# decide what mihomo is listening for. Edit either one by hand and they stop
# agreeing, and the failure is quiet: the rules are built, the counters move,
# and the packets arrive at a port nothing is bound to. So the config is read
# and the two are compared where somebody can see it.
#
# Not every config names one mode. tproxy-port alongside an enabled tun serves
# both 'tproxy' and 'tproxy_tun' equally well, and nothing in the file says
# which was meant -- that is a question about the kernel, not about the config.
# So this reports the whole set it can serve and lets the caller say whether
# the configured mode is in it, rather than inventing a single answer.
conf_modes() {
	local has_tproxy="" has_redir="" has_tun="" out=""

	[ -f "$MIHOMO_CONF" ] || return 1

	[ -n "$(yaml_top tproxy-port)" ] && has_tproxy=1
	[ -n "$(yaml_top redir-port)" ]  && has_redir=1
	case "$(yaml_in tun enable)" in
		true|1|yes) has_tun=1 ;;
	esac

	[ -n "$has_tproxy" ] && out="tproxy"
	[ -n "$has_tproxy" ] && [ -n "$has_tun" ] && out="$out tproxy_tun"
	[ -n "$has_redir" ]  && [ -n "$has_tun" ] && out="$out redirect_tun"
	[ -n "$has_tun" ]    && out="$out tun"
	# the keys it needs are written in by core-sync; a tun and meow suffice
	[ -n "$has_tun" ] && core_is_meow && out="$out auto_redirect"

	out="${out# }"
	[ -n "$out" ] || return 1
	echo "$out"
}

conf_serves_mode() {
	local m
	for m in $(conf_modes 2>/dev/null); do
		[ "$m" = "$1" ] && return 0
	done
	return 1
}

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

# What has to hold before config.yaml is touched for the mode at all.
check_mode() {
	case "$mode" in
		tproxy|tproxy_tun|tun|redirect_tun|auto_redirect) ;;
		*) die "unknown mode '$mode' (expected: tproxy, tproxy_tun, tun, redirect_tun, auto_redirect)" ;;
	esac

	[ -f "$MIHOMO_CONF" ] || die "mihomo config not found at $MIHOMO_CONF"

	if [ "$mode" = auto_redirect ] && ! core_is_meow; then
		die "mode 'auto_redirect' needs the meow-openwrt core, which captures by itself; this router runs mihomo. Switch the core in Settings -> Storage and memory -> Proxy core (or: updctl.sh core-use meow), or pick another interception mode."
	fi
}

check_prereq() {
	check_mode

	if mode_needs_tproxy_port && [ -z "$tproxy_port" ]; then
		die "mode '$mode' needs 'tproxy-port' in $MIHOMO_CONF (or tproxy_port in UCI), and it could not be written in (see logread)"
	fi
	if mode_needs_redir_port && [ -z "$redir_port" ]; then
		die "mode '$mode' needs 'redir-port' in $MIHOMO_CONF (or redir_port in UCI), and it could not be written in (see logread)"
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

# One line of the ruleset script apply_nft hands to nft -f in one go.
nb() { echo "$*" >> "$NFT_BATCH"; }

build_bypass() {
	# Rules shared by every mode: never touch mihomo's own traffic, traffic
	# that is not from the LAN, link-local infrastructure, or destinations
	# that must stay local. Order matters -- these all "return" before any
	# marking happens.
	nb add rule $TABLE mangle meta mark "$self_mark" return
	nb add rule $TABLE mangle iifname != $lan_set return

	local ports
	ports="$(mihomo_ports)"
	[ -n "$ports" ] && {
		nb add rule $TABLE mangle tcp dport "{ $ports }" return
		nb add rule $TABLE mangle udp dport "{ $ports }" return
	}

	# DHCP must never be proxied or the LAN cannot get addresses.
	nb add rule $TABLE mangle udp sport 67 udp dport 68 return
	nb add rule $TABLE mangle udp sport 68 udp dport 67 return

	# Encrypted DNS of the device's own choosing goes past the router's
	# resolver, so the config's domains never reach the bypass set and its
	# rules see bare addresses. DoT has a port of its own; DoH is HTTPS to
	# a known resolver address (setctl.sh keeps that list in doh4). Rejected
	# before anything can let them through, so devices fall back to the
	# router's DNS at once.
	[ "$block_dot" = 1 ] && nb add rule $TABLE mangle meta l4proto { tcp, udp } th dport 853 reject
	[ "$block_doh" = 1 ] && nb add rule $TABLE mangle ip daddr @doh4 meta l4proto { tcp, udp } th dport 443 reject

	local nets
	nets="$(nft_set $bypass_net)"
	[ -n "$nets" ] && nb add rule $TABLE mangle ip daddr "{ $nets }" return

	local srcs
	srcs="$(nft_set $bypass_src)"
	[ -n "$srcs" ] && nb add rule $TABLE mangle ip saddr "{ $srcs }" return

	# The address set, if one is configured. This is the last thing before
	# marking, so everything it matches is handled by the kernel alone and
	# never reaches mihomo -- a DIRECT rule inside mihomo would still relay
	# the connection through userspace.
	# With 'include', bypass4_dns holds what dnsmasq resolved for the domains
	# config.yaml sends to the proxy (setctl.sh); an address in either set
	# reaches mihomo. Its entries expire, since a name's addresses change.
	case "$set_mode" in
		exclude) nb add rule $TABLE mangle ip daddr @bypass4 return ;;
		include) nb add rule $TABLE mangle ip daddr != @bypass4 ip daddr != @bypass4_dns return ;;
	esac

	# QUIC carries HTTP/3 over UDP/443. Rejecting it makes browsers fall back
	# to TCP, which the proxy carries more reliably where UDP is throttled.
	[ "$block_quic" = 1 ] && nb add rule $TABLE mangle meta l4proto udp udp dport 443 reject

	# Send LAN DNS at mihomo's resolver instead of whatever the client asked
	# for. Off by default: most setups already point dnsmasq at mihomo.
	[ "$dns_hijack" = 1 ] && {
		nb add chain $TABLE dns_nat "{ type nat hook prerouting priority dstnat - 5 ; }"
		nb add rule $TABLE dns_nat iifname $lan_set meta l4proto { tcp, udp } th dport 53 \
			dnat ip to "127.0.0.1:$dns_port"
	}

	# Interception marks IPv4 only, so a device with IPv6 would reach the
	# internet past the proxy: same sites, the real address. While the
	# ruleset is up, LAN IPv6 that would leave the LAN is refused -- with a
	# reject, so apps fall back to IPv4 at once instead of timing out. The
	# router's own IPv6, and IPv6 between LAN devices, are untouched; a
	# bypass or a switched-off proxy removes the table and this with it.
	build_leak6
	return 0
}

build_leak6() {
	[ "$block_ipv6" = 1 ] || return 0
	nb add chain $TABLE leak6 "{ type filter hook forward priority filter - 5 ; }"
	nb add rule $TABLE leak6 iifname $lan_set meta nfproto ipv6 oifname != $lan_set \
		reject with icmpx type admin-prohibited
}

# The table in auto_redirect mode: meow captures in its own, so this one
# holds only what the core does not do -- the IPv6 leak (meow leaves IPv6
# alone without an inet6-address) and QUIC, rejected on its way out of the
# LAN. It exists even when empty: its presence is what the rest of ClashWrt
# reads as "the proxy rules are loaded".
apply_nft_core() {
	NFT_BATCH="$(mktemp /tmp/clashwrt-nft.XXXXXX)" || die "cannot create a temporary file"
	nb add table $TABLE
	nb delete table $TABLE
	nb add table $TABLE
	build_leak6
	[ "$block_quic" = 1 ] && {
		nb add chain $TABLE quic "{ type filter hook forward priority filter - 5 ; }"
		nb add rule $TABLE quic iifname $lan_set oifname != $lan_set udp dport 443 reject
	}
	local err
	if ! err="$(nft -f "$NFT_BATCH" 2>&1)"; then
		rm -f "$NFT_BATCH"
		die "nft refused the ruleset, the previous one is still in place: $err"
	fi
	rm -f "$NFT_BATCH"
	return 0
}

apply_nft() {
	# What dnsmasq has resolved so far for the config's domains lives only in
	# bypass4_dns, and only a new lookup puts an address back. Rebuilding the
	# table would otherwise empty it, and with 'include' every site a client
	# still has cached would go direct until its next lookup. So the
	# addresses are carried over into the new table.
	#
	# The same goes for bypass4: setctl.sh refills it right after, but in
	# between an empty set with 'include' would send every connection direct.
	# Its old contents are carried over and then replaced by the load.
	local dns_keep set_keep doh_keep
	dns_keep="$(nft list set $TABLE bypass4_dns 2>/dev/null |
		grep -oE '([0-9]{1,3}\.){3}[0-9]{1,3}' | sort -u | tr '\n' ',' | sed 's/,$//')"
	doh_keep="$(nft list set $TABLE doh4 2>/dev/null |
		sed -n '/elements = {/,/}/p' | sed 's/.*elements = {//; s/}.*//' | tr -d ' \t\n')"
	set_keep="$(nft list set $TABLE bypass4 2>/dev/null |
		sed -n '/elements = {/,/}/p' | sed 's/.*elements = {//; s/}.*//' | tr -d ' \t\n')"

	# Everything below is written to one script and applied by one nft -f,
	# which is a single transaction: the table is replaced whole or not at
	# all. Built a command at a time, a failure partway left a ruleset that
	# intercepted some traffic and not the rest, with nothing to say so.
	NFT_BATCH="$(mktemp /tmp/clashwrt-nft.XXXXXX)" || die "cannot create a temporary file"
	# 'add' first, so that 'delete' has something to delete on a first apply
	nb add table $TABLE
	nb delete table $TABLE
	nb add table $TABLE

	# Declared even when unused: the rules referencing it are added
	# conditionally, but a set that only sometimes exists makes every other
	# command here need a guard. "interval" is what allows CIDRs as elements.
	nb add set $TABLE bypass4 "{ type ipv4_addr ; flags interval ; auto-merge ; }"
	nb add set $TABLE bypass4_dns "{ type ipv4_addr ; flags timeout ; timeout 1d ; }"
	nb add set $TABLE doh4 "{ type ipv4_addr ; flags interval ; auto-merge ; }"
	[ -n "$dns_keep" ] && nb add element $TABLE bypass4_dns "{ $dns_keep }"
	[ -n "$set_keep" ] && nb add element $TABLE bypass4 "{ $set_keep }"
	[ -n "$doh_keep" ] && nb add element $TABLE doh4 "{ $doh_keep }"

	# priority mangle(-150) so we see packets before conntrack/dstnat decide
	nb add chain $TABLE mangle "{ type filter hook prerouting priority mangle ; }"
	build_bypass

	case "$mode" in
	tproxy)
		nb add rule $TABLE mangle meta l4proto tcp meta mark set "$mark_tproxy" \
			tproxy ip to "127.0.0.1:$tproxy_port" accept
		nb add rule $TABLE mangle meta l4proto udp meta mark set "$mark_tproxy" \
			tproxy ip to "127.0.0.1:$tproxy_port" accept
		;;
	tproxy_tun)
		nb add rule $TABLE mangle meta l4proto tcp meta mark set "$mark_tproxy" \
			tproxy ip to "127.0.0.1:$tproxy_port" accept
		nb add rule $TABLE mangle meta l4proto udp meta mark set "$mark_tun"
		;;
	tun)
		nb add rule $TABLE mangle meta l4proto tcp meta mark set "$mark_tun"
		nb add rule $TABLE mangle meta l4proto udp meta mark set "$mark_tun"
		;;
	redirect_tun)
		nb add rule $TABLE mangle meta l4proto tcp meta mark set "$mark_tproxy"
		nb add rule $TABLE mangle meta l4proto udp meta mark set "$mark_tun"

		# DNAT explicitly to 127.0.0.1 rather than "redirect to :port":
		# redirect targets the *inbound interface's own address*, but with
		# allow-lan:false mihomo only listens on loopback, so redirect lands
		# on a closed port. Loopback DNAT needs route_localnet=1 (set below).
		# Ahead of fw4's own dstnat chain (priority dstnat, -100): whichever
		# nat chain acts first owns the translation, so interception has to
		# win the race against any port forwards fw4 may install.
		nb add chain $TABLE nat_pre "{ type nat hook prerouting priority dstnat - 40 ; }"
		nb add rule $TABLE nat_pre meta mark "$mark_tproxy" meta l4proto tcp \
			dnat ip to "127.0.0.1:$redir_port"
		;;
	esac

	local err
	if ! err="$(nft -f "$NFT_BATCH" 2>&1)"; then
		rm -f "$NFT_BATCH"
		die "nft refused the ruleset, the previous one is still in place: $err"
	fi
	rm -f "$NFT_BATCH"
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
	local d
	for d in $lan_devices; do
		sysctl -q -w "net.ipv4.conf.${d}.route_localnet=1" 2>/dev/null
	done
	return 0
}

# ---------------------------------------------------------------------------
# DNS during an auto-bypass
# ---------------------------------------------------------------------------
#
# Lifting the traffic rules is not enough when dnsmasq forwards to mihomo's
# DNS port: the LAN would keep asking the core that just died and lose name
# resolution along with the proxy. So while the bypass flag exists, those
# forwards are taken out of dnsmasq's server list (the rest of the list, or
# its normal upstream, then answers), and the original list is put back as
# soon as the flag is gone. The original list is kept in DNS_BAK on flash, not
# in /var/run, so a power cut during a bypass is repaired by the next apply
# instead of leaving the forward missing for good.

DNSMASQ_SEC="dhcp.@dnsmasq[0]"
DNS_BAK="${CLASHWRT_DNS_BAK:-/etc/clashwrt-dns.bak}"
DNSMASQ_INIT="${CLASHWRT_DNSMASQ_INIT:-/etc/init.d/dnsmasq}"

# the entries of dnsmasq's server list that point at mihomo, one per line
dns_mihomo_entries() {
	local s
	for s in $(uci -q get "$DNSMASQ_SEC.server" 2>/dev/null); do
		case "$s" in
			*"#$dns_port"|*":$dns_port") echo "$s" ;;
		esac
	done
}

# what netifd learned from the uplink, loopback excluded
dns_uplink_resolvers() {
	local rf
	rf="$(uci -q get "$DNSMASQ_SEC.resolvfile" 2>/dev/null)"
	sed -n 's/^nameserver[[:space:]]*\([^[:space:]]*\).*/\1/p' "${rf:-/tmp/resolv.conf.d/resolv.conf.auto}" 2>/dev/null |
		grep -v -e '^127\.' -e '^::1$'
}

dns_commit() {
	uci commit dhcp && "$DNSMASQ_INIT" reload >/dev/null 2>&1
}

dns_fallback_on() {
	local mine s up have
	mine="$(dns_mihomo_entries)"
	[ -n "$mine" ] || return 0

	have="$(uci -q get "$DNSMASQ_SEC.server" 2>/dev/null)"
	up=""
	# with no general server left (one for a single domain does not count)
	# and the uplink's resolvers switched off, dnsmasq would have no upstream
	# at all: borrow the uplink's own
	if [ "$(echo "$have" | tr ' ' '\n' | grep -v -F -x "$mine" | grep -c -v -e '^/' -e '^$')" -eq 0 ] &&
		[ "$(uci -q get "$DNSMASQ_SEC.noresolv")" = 1 ]; then
		up="$(dns_uplink_resolvers)"
		if [ -z "$up" ]; then
			log "auto-bypass: dnsmasq forwards only to mihomo and no uplink resolver is known, DNS stays on mihomo"
			return 1
		fi
	fi

	if [ ! -e "$DNS_BAK" ]; then
		echo "$have" | tr ' ' '\n' > "$DNS_BAK.tmp" && mv "$DNS_BAK.tmp" "$DNS_BAK" ||
			{ rm -f "$DNS_BAK.tmp"; log "auto-bypass: cannot save the dnsmasq server list, DNS stays on mihomo"; return 1; }
	fi
	for s in $mine; do uci -q del_list "$DNSMASQ_SEC.server=$s"; done
	for s in $up; do uci add_list "$DNSMASQ_SEC.server=$s"; done
	dns_commit
	log "auto-bypass: dnsmasq no longer forwards to mihomo"
}

dns_restore() {
	local s
	[ -e "$DNS_BAK" ] || return 0
	uci -q delete "$DNSMASQ_SEC.server"
	while read -r s; do
		[ -n "$s" ] && uci add_list "$DNSMASQ_SEC.server=$s"
	done < "$DNS_BAK"
	dns_commit
	rm -f "$DNS_BAK"
	log "dnsmasq forwards to mihomo again"
}

# DNS follows the flag: forwards are out while it exists, back when it is gone
# What the watchdog did when the proxy path died: 'direct' (traffic let out
# past the proxy) or 'block' (the kill switch: LAN cut off from the internet
# until the path is back). Nothing when it did neither.
flag_action() {
	[ -e "$FLAG" ] || return 1
	[ "$(cat "$FLAG" 2>/dev/null)" = block ] && echo block || echo direct
}

# The AI services must not see the home address: with the VPN down and
# traffic let out direct, their names stop resolving (NXDOMAIN from
# dnsmasq) until the path is back. Only when config.yaml sends them to an AI
# group, i.e. the user asked for them to stay on one server. The suffixes are
# the ones the wizard's AI rule-sets name; each also covers its subdomains.
# What was added is listed on flash, so a power cut mid-bypass is undone by
# the next apply, and only those entries are ever taken out again.
AI_DNS_LIST="${CLASHWRT_AI_DNS:-/etc/clashwrt-ai-dns.list}"
AI_BLOCK_DOMAINS="openai.com chatgpt.com chat.com openai.org chatgpt.site oaistatic.com oaiusercontent.com
oaistatsig.com sora.com anthropic.com claude.ai claude.com claude.app clau.de claudeusercontent.com
anthropic.team gemini.google.com gemini.google bard.google.com aistudio.google.com ai.google.dev
makersuite.google.com generativelanguage.googleapis.com alkalimakersuite-pa.clients6.google.com
geminiweb-pa.clients6.google.com notebooklm.google.com notebooklm.google x.ai grok.com
perplexity.ai perplexity.com pplx.ai"

ai_routed() {
	[ -f "$MIHOMO_CONF" ] &&
		grep -q -E '^[[:space:]]*-[[:space:]]*(RULE-SET|DOMAIN-SUFFIX|DOMAIN),[^,]+,AI[[:space:]]*(#.*)?$' "$MIHOMO_CONF"
}

# Both return 0 when they changed dnsmasq's settings, 1 when not.
ai_dns_block_on() {
	local d
	[ ! -e "$AI_DNS_LIST" ] || return 1
	ai_routed || return 1
	for d in $AI_BLOCK_DOMAINS; do echo "/$d/"; done > "$AI_DNS_LIST.tmp" &&
		mv "$AI_DNS_LIST.tmp" "$AI_DNS_LIST" ||
		{ rm -f "$AI_DNS_LIST.tmp"; log "auto-bypass: cannot record the AI block, AI services are not blocked"; return 1; }
	while read -r d; do uci add_list "$DNSMASQ_SEC.address=$d"; done < "$AI_DNS_LIST"
	return 0
}

ai_dns_block_off() {
	local d
	[ -e "$AI_DNS_LIST" ] || return 1
	while read -r d; do
		[ -n "$d" ] && uci -q del_list "$DNSMASQ_SEC.address=$d"
	done < "$AI_DNS_LIST"
	rm -f "$AI_DNS_LIST"
	return 0
}

# DNS follows the flag: forwards are out while traffic goes direct, back when
# it is gone. A kill switch leaves DNS alone -- nothing is meant to get out.
dns_sync() {
	if [ "$(flag_action)" = direct ]; then
		dns_fallback_on
		if ai_dns_block_on; then
			dns_commit
			log "auto-bypass: AI services blocked while traffic goes direct"
		fi
	else
		dns_restore
		if ai_dns_block_off; then
			dns_commit
			log "AI services resolve again"
		fi
	fi
}

# The kill switch's whole ruleset: LAN traffic to anywhere but the LAN is
# refused, IPv4 and IPv6 alike, as one transaction like apply_nft's.
apply_block() {
	NFT_BATCH="$(mktemp /tmp/clashwrt-nft.XXXXXX)" || die "cannot create a temporary file"
	nb add table $TABLE
	nb delete table $TABLE
	nb add table $TABLE
	nb add chain $TABLE killswitch "{ type filter hook forward priority filter - 5 ; }"
	nb add rule $TABLE killswitch iifname $lan_set oifname != $lan_set reject with icmpx type admin-prohibited
	local err
	if ! err="$(nft -f "$NFT_BATCH" 2>&1)"; then
		rm -f "$NFT_BATCH"
		die "nft refused the kill switch: $err"
	fi
	rm -f "$NFT_BATCH"
	flush_rules
	# the core would otherwise go on carrying the LAN out through the proxy
	core_marked && core_capture off
	return 0
}

# ---------------------------------------------------------------------------
# the core's own capture (mode auto_redirect, meow-openwrt)
# ---------------------------------------------------------------------------
#
# meow-openwrt's tun.auto-redirect does what the other four modes build here:
# it puts its own table (inet meow) and policy rules in place, redirects TCP
# to a listener of its own and routes UDP into the tun, leaves its own
# sockets (routing-mark) and the router's subnets alone, and accepts the tun
# in fw4 itself. With route-address-dns it also judges every DNS answer by
# its rules and captures only the addresses of names that go to a proxy, so
# the rest is forwarded by the kernel (flowtable and hardware offload
# included) and never reaches the core.
#
# What stays with ClashWrt:
#
#   the keys     written into config.yaml's tun: block (core-sync), from UCI
#                and from the config's own rules (setctl.sh core-routes). A
#                comment line marks them; everything after it in tun: is ours.
#                The core reads them at start and at a reload, and that is the
#                only way: its DNS hook is set up from the file, not by PATCH.
#   the switch   PATCH /configs {"tun":{"enable":...}} turns the capture off
#                and on at runtime without touching the file, for the proxy
#                switch, the watchdog and the kill switch. The file keeps
#                asking for capture, so a core that restarts while ClashWrt
#                is off captures again -- the hotplug event of its new tun is
#                what turns that off again (do_hotplug).
#   DNS          route-address-dns sees only the lookups the core answers, so
#                dnsmasq is pointed at the core (dns_core_on) for as long as
#                the mode is on, and put back as it was afterwards.

CORE_BIN="${CLASHWRT_CORE_BIN:-/usr/bin/mihomo}"
MEOW_BIN="${CLASHWRT_MEOW_BIN:-/usr/bin/meow}"
CONFCTL="${CLASHWRT_CONFCTL:-/usr/libexec/clashwrt/confctl.sh}"
SETCTL="${CLASHWRT_SETCTL:-/usr/libexec/clashwrt/setctl.sh}"
CORE_INIT="${CLASHWRT_CORE_INIT:-/etc/init.d/mihomo}"
TUN_MARK_LINE="# ClashWrt: from here to the end of tun: follows Settings -> Interception mode (auto_redirect)"
TUN_MANAGED="enable auto-route auto-redirect dns-hijack route-address route-address-set route-exclude-address route-exclude-address-set route-address-dns block-encrypted-dns block-encrypted-dns-address"

core_is_meow() { [ -L "$CORE_BIN" ] && [ "$(readlink "$CORE_BIN")" = "$MEOW_BIN" ]; }
core_running() { pidof mihomo >/dev/null 2>&1 || pidof meow >/dev/null 2>&1; }
core_table() { nft list table inet meow >/dev/null 2>&1; }
# config.yaml asks the core to capture (core-sync wrote the keys)
core_marked() { [ -f "$MIHOMO_CONF" ] && grep -qF "$TUN_MARK_LINE" "$MIHOMO_CONF"; }

# The core's REST API, at the controller config.yaml names (as confctl.sh
# reaches it), with its secret.
core_api() {
	local ctl host port secret
	ctl="$(yaml_top external-controller)"
	port="${ctl##*:}"
	host="${ctl%:*}"
	case "$port" in ''|*[!0-9]*) port="$api_port"; host="" ;; esac
	case "$host" in ''|0.0.0.0|'[::]'|::|'*') host=127.0.0.1 ;; esac
	secret="$(yaml_top secret)"
	curl -s -o /dev/null -f -m 20 -X "$1" ${secret:+-H "Authorization: Bearer $secret"} \
		"http://$host:$port$2" ${3:+-d "$3"} 2>/dev/null
}

# Capture on or off at runtime. Off stops the core's tun, which takes its
# table and policy rules with it; on starts it again from the committed
# config. Nothing to do when the core is not running: it reads the file.
core_capture() {
	local want=true
	[ "$1" = off ] && want=false
	core_running || return 0
	core_api PATCH /configs "{\"tun\":{\"enable\":$want}}" || {
		log "the core's API refused to switch its capture $1"
		return 1
	}
}

# The table appears a moment after the tun starts.
core_wait_table() {
	local i=0
	while [ "$i" -lt "$tun_wait" ]; do
		core_table && return 0
		i=$((i + 1))
		sleep 1
	done
	return 1
}

# items on stdin as a YAML flow list: ['a', 'b']
yaml_flow() {
	awk 'NF { printf "%s\047%s\047", (n++ ? ", " : "["), $0 } END { print (n ? "]" : "[]") }'
}

cr_get() { echo "$CORE_ROUTES" | sed -n "s/^$1: //p"; }

# The tun keys for capture, one per line without indent.
core_tun_lines() {
	local v
	echo "enable: true"
	echo "auto-route: true"
	echo "auto-redirect: true"
	# LAN lookups go to dnsmasq, and from there to the core when it needs
	# them (dns_core_on); hijacking port 53 is the separate dns_hijack choice
	if [ "$dns_hijack" = 1 ]; then
		echo "dns-hijack: ['any:53']"
	else
		echo "dns-hijack: []"
	fi
	v="$( { for v in $bypass_net; do echo "$v"; done; cr_get exclude_net; } | awk '!s[$0]++')"
	[ -n "$v" ] && echo "route-exclude-address: $(echo "$v" | yaml_flow)"
	v="$(cr_get exclude_set)"; [ -n "$v" ] && echo "route-exclude-address-set: $(echo "$v" | yaml_flow)"
	v="$(cr_get route_net)"; [ -n "$v" ] && echo "route-address: $(echo "$v" | yaml_flow)"
	v="$(cr_get route_set)"; [ -n "$v" ] && echo "route-address-set: $(echo "$v" | yaml_flow)"
	[ "$(cr_get route_dns)" = 1 ] && echo "route-address-dns: true"
	# DoT and DoH to the well-known resolvers, refused by the core itself
	# (its own list; dibdot's is not used in this mode), plus doh_extra
	if [ "$block_dot" = 1 ] || [ "$block_doh" = 1 ]; then
		echo "block-encrypted-dns: true"
		v="$(for v in $doh_extra; do echo "$v"; done)"
		[ -n "$v" ] && echo "block-encrypted-dns-address: $(echo "$v" | yaml_flow)"
	fi
	return 0
}

# What the other modes want back: a tun for UDP that routes nothing itself,
# switched on only where the mode uses it.
core_tun_off_lines() {
	if mode_needs_tun; then echo "enable: true"; else echo "enable: false"; fi
	echo "auto-route: false"
	echo "auto-redirect: false"
}

# config.yaml ($1) with the managed keys of tun: replaced by the lines in $2,
# after the marker line when $3 is "mark". Indented like the block's own
# keys; a key's list items (deeper, or "- " at its level) go with it.
tun_rewrite() {
	awk -v lf="$2" -v mark="$3" -v markline="$TUN_MARK_LINE" -v keys="$TUN_MANAGED" '
	BEGIN {
		n = split(keys, k, " "); for (i = 1; i <= n; i++) managed[k[i]] = 1
		while ((getline l < lf) > 0) add[++na] = l
	}
	function emit(   i, ind) {
		ind = sprintf("%" (cind ? cind : 2) "s", "")
		if (mark == "mark") print ind markline
		for (i = 1; i <= na; i++) print ind add[i]
		for (i = 1; i <= nb; i++) print blank[i]
		nb = 0; done = 1
	}
	{ sub(/\r$/, "") }
	/^[A-Za-z0-9_-]+:/ {
		if (intun) emit()
		intun = ($0 ~ /^tun:[ \t]*(#.*)?$/)
		if (intun) seen = 1
		print; next
	}
	intun {
		if ($0 ~ /^[ \t]*$/) { blank[++nb] = $0; next }
		match($0, /^[ \t]*/); ind = RLENGTH
		line = substr($0, ind + 1)
		if (index($0, markline)) { skip = 0; next }
		if (cind == 0 && line !~ /^#/) cind = ind
		if (skip && (ind > cind || (ind == cind && line ~ /^-/))) next
		skip = 0
		if (ind == cind) {
			key = line; sub(/[ \t]*:.*/, "", key)
			if (key in managed) { skip = 1; next }
		}
		for (i = 1; i <= nb; i++) print blank[i]
		nb = 0
		print; next
	}
	{ print }
	END {
		if (intun) emit()
		else if (!seen && mark == "mark") {
			print "tun:"
			print "  device: " ENVIRON["CW_TUN_DEVICE"]
			print "  stack: system"
			emit()
		}
	}
	' "$1"
}

# Writes the managed keys into config.yaml: 'on' for capture, 'off' to give
# them back to the other modes (only if they were ours). Nothing is written
# when the file already says it; a change is checked with the core's own
# test first (confctl.sh) and then reloaded through the API, or by a restart.
# --no-reload leaves that to the caller (confctl.sh, which reloads anyway).
core_conf_sync() {
	local want="$1" reload="${2:-}" lines tmp mark=""
	[ -f "$MIHOMO_CONF" ] || return 1
	if [ "$want" = on ]; then
		mark=mark
	else
		core_marked || return 0
	fi
	lines="$(mktemp /tmp/clashwrt-tun.XXXXXX)" || return 1
	if [ "$want" = on ]; then core_tun_lines > "$lines"; else core_tun_off_lines > "$lines"; fi
	tmp="$(mktemp /tmp/clashwrt-conf.XXXXXX)" || { rm -f "$lines"; return 1; }
	CW_TUN_DEVICE="$tun_device" tun_rewrite "$MIHOMO_CONF" "$lines" "$mark" > "$tmp"
	rm -f "$lines"
	if cmp -s "$tmp" "$MIHOMO_CONF"; then
		rm -f "$tmp"
		return 0
	fi
	if ! "$CONFCTL" check-file "$tmp" >/dev/null 2>&1; then
		rm -f "$tmp"
		log "the core rejected config.yaml with the auto_redirect tun keys; it is left as it was"
		return 1
	fi
	cat "$tmp" > "$MIHOMO_CONF"
	rm -f "$tmp"
	log "config.yaml: the core's capture keys $([ "$want" = on ] && echo written || echo taken out)"
	[ "$reload" = --no-reload ] && return 0
	core_running || return 0
	core_api PUT '/configs?force=true' '{"path":"","payload":""}' || "$CORE_INIT" restart >/dev/null 2>&1
	return 0
}

# --- inbounds: only what the mode uses --------------------------------------
#
# config.yaml keeps the listeners of the current mode and no others: an idle
# tun and two idle ports cost the core memory for nothing. A port the mode
# does not use is commented out with its number kept ("# ClashWrt-off: "),
# and comes back as it was when a mode needs it again; tun: stays with
# enable: false. A UCI port override means the config is not ours to read,
# so then nothing is touched.
INBOUND_OFF="# ClashWrt-off: "

# "tproxy redir tun" for the current mode: on, off, or keep (auto_redirect's
# tun belongs to core_conf_sync)
inbound_wants() {
	case "$mode" in
		tproxy)       echo "on off off" ;;
		tproxy_tun)   echo "on off on" ;;
		tun)          echo "off off on" ;;
		redirect_tun) echo "off on on" ;;
		auto_redirect) echo "off off keep" ;;
	esac
}

# config.yaml ($1) with the inbounds of $2 ("tproxy redir tun")
inbound_rewrite() {
	awk -v w="$2" -v off="$INBOUND_OFF" -v dev="$tun_device" '
	BEGIN { split(w, a, " "); want["tproxy-port"] = a[1]; want["redir-port"] = a[2]; tunw = a[3]
		def["tproxy-port"] = 7894; def["redir-port"] = 7893 }
	function port_line(key, val) {
		seen[key] = 1
		if (want[key] == "on") print key ": " val
		else print off key ": " val
	}
	function tun_end() {
		if (intun && !tunen && tunw != "keep") print sprintf("%" (cind ? cind : 2) "s", "") "enable: " (tunw == "on" ? "true" : "false")
		intun = 0
	}
	{ sub(/\r$/, "") }
	/^(tproxy|redir)-port:/ || index($0, off "tproxy-port:") == 1 || index($0, off "redir-port:") == 1 {
		l = $0; if (index(l, off) == 1) l = substr(l, length(off) + 1)
		key = l; sub(/:.*/, "", key)
		val = l; sub(/^[^:]*:[ \t]*/, "", val)
		if (intun) tun_end()
		port_line(key, val); next
	}
	/^[A-Za-z0-9_-]+:/ {
		if (intun) tun_end()
		if ($0 ~ /^tun:[ \t]*(#.*)?$/) { intun = 1; tunseen = 1; tunen = 0; cind = 0 }
		print; next
	}
	intun && $0 !~ /^[ \t]*(#.*)?$/ {
		match($0, /^[ \t]*/); ind = RLENGTH
		if (cind == 0) cind = ind
		if (ind == cind && $0 ~ /^[ \t]*enable:/ && tunw != "keep") {
			tunen = 1
			print substr($0, 1, ind) "enable: " (tunw == "on" ? "true" : "false"); next
		}
		if (ind == cind && $0 ~ /^[ \t]*enable:/) tunen = 1
	}
	{ print }
	END {
		if (intun) tun_end()
		for (k in want) if (want[k] == "on" && !seen[k]) print k ": " def[k]
		if (tunw == "on" && !tunseen) {
			print "tun:"; print "  enable: true"; print "  device: " dev
			print "  stack: system"; print "  auto-route: false"; print "  auto-redirect: false"
		}
	}
	' "$1"
}

# Writes the current mode's inbounds into config.yaml. The core is told
# unless --no-reload (confctl.sh, which reloads anyway): mihomo re-creates
# its listeners on a reload, meow only on a restart.
inbound_sync() {
	local reload="${1:-}" tmp
	[ -f "$MIHOMO_CONF" ] || return 1
	[ -z "$tproxy_port$redir_port" ] || return 0
	[ -n "$(inbound_wants)" ] || return 0
	tmp="$(mktemp /tmp/clashwrt-conf.XXXXXX)" || return 1
	inbound_rewrite "$MIHOMO_CONF" "$(inbound_wants)" > "$tmp"
	if cmp -s "$tmp" "$MIHOMO_CONF"; then
		rm -f "$tmp"
		return 0
	fi
	if ! "$CONFCTL" check-file "$tmp" >/dev/null 2>&1; then
		rm -f "$tmp"
		log "the core rejected config.yaml with only the inbounds of mode '$mode'; it is left as it was"
		return 1
	fi
	cat "$tmp" > "$MIHOMO_CONF"
	rm -f "$tmp"
	log "config.yaml: inbounds for mode '$mode' ($(grep -E '^(tproxy|redir)-port:' "$MIHOMO_CONF" | tr '\n' ' ')tun $(echo "$(inbound_wants)" | cut -d' ' -f3))"
	[ "$reload" = --no-reload ] && return 0
	core_running || return 0
	if core_is_meow; then
		"$CORE_INIT" restart >/dev/null 2>&1
	else
		core_api PUT '/configs?force=true' '{"path":"","payload":""}' || "$CORE_INIT" restart >/dev/null 2>&1
	fi
	return 0
}

# --- dns.nftset: meow fills the include set itself --------------------------
#
# With 'include' (only what needs a proxy is intercepted) meow-openwrt adds
# the address of every DNS answer its rules send to a proxy to bypass4_dns,
# before the answer leaves it: GEOSITE, keyword and rule-set domains too,
# with no domain list in dnsmasq. Only the nftset key of dns: is ours; one
# naming another set is the user's and stays.
NFTSET_REF="inet#clashwrt#bypass4_dns"

# config.yaml ($1) with dns.nftset set ($2 = on) or taken out (off)
nftset_rewrite() {
	awk -v want="$2" -v ref="$NFTSET_REF" '
	function flush_buf(   i) {
		if (!(want == "on" || ours)) for (i = 1; i <= nb; i++) print buf[i]
		nb = 0; ours = 0; skip = 0
	}
	function emit(   ind) {
		if (skip) flush_buf()
		if (want == "on" && !done) {
			ind = sprintf("%" (cind ? cind : 2) "s", "")
			print ind "nftset:"
			print ind "  ipv4: " ref
			print ind "  timeout: 86400"
		}
		done = 1
	}
	{ sub(/\r$/, "") }
	/^[A-Za-z0-9_-]+:/ {
		if (indns) emit()
		indns = ($0 ~ /^dns:[ \t]*(#.*)?$/)
		print; next
	}
	indns {
		if ($0 ~ /^[ \t]*(#.*)?$/) { if (skip) buf[++nb] = $0; else print; next }
		match($0, /^[ \t]*/); ind = RLENGTH
		if (cind == 0) cind = ind
		if (skip && ind > cind) { buf[++nb] = $0; if (index($0, ref)) ours = 1; next }
		if (skip) flush_buf()
		if (ind == cind && $0 ~ /^[ \t]*nftset:/) { skip = 1; buf[++nb] = $0; next }
		print; next
	}
	{ print }
	END { if (indns) emit() }
	' "$1"
}

# Writes or takes out the key, checked by the core and reloaded like
# core_conf_sync. A config without a dns: block has nothing to fill the set.
nftset_sync() {
	local want="$1" reload="${2:-}" tmp
	[ -f "$MIHOMO_CONF" ] || return 1
	grep -q '^dns:' "$MIHOMO_CONF" || return 0
	[ "$want" = off ] && ! grep -qF "$NFTSET_REF" "$MIHOMO_CONF" && return 0
	tmp="$(mktemp /tmp/clashwrt-conf.XXXXXX)" || return 1
	nftset_rewrite "$MIHOMO_CONF" "$want" > "$tmp"
	if cmp -s "$tmp" "$MIHOMO_CONF"; then
		rm -f "$tmp"
		return 0
	fi
	if ! "$CONFCTL" check-file "$tmp" >/dev/null 2>&1; then
		rm -f "$tmp"
		log "the core rejected config.yaml with dns.nftset; it is left as it was"
		return 1
	fi
	cat "$tmp" > "$MIHOMO_CONF"
	rm -f "$tmp"
	log "config.yaml: dns.nftset $([ "$want" = on ] && echo "written: meow fills $NFTSET_REF" || echo "taken out")"
	[ "$reload" = --no-reload ] && return 0
	core_running || return 0
	core_api PUT '/configs?force=true' '{"path":"","payload":""}' || "$CORE_INIT" restart >/dev/null 2>&1
	return 0
}

# --- dnsmasq to the core, for route-address-dns -----------------------------
#
# The core adds an address to its capture set when it answers the lookup, so
# the LAN's lookups have to reach it: dnsmasq forwards to it, and only to it
# (noresolv, and any other general server= -- an AdGuard Home, a stubby --
# taken out meanwhile; dnsmasq would send some lookups there), or those
# answers would bypass the set and the sites behind them would go direct.
# Servers for one domain (/lan.example/...) stay. What was changed is listed on flash
# and is all that is ever undone. While the watchdog has DNS on the uplink
# (DNS_BAK), that arrangement owns the list and this keeps out of it.
DNS_CORE_STATE="${CLASHWRT_DNS_CORE:-/etc/clashwrt-dns-core.state}"

dns_core_on() {
	local e s changed="" nr
	[ -e "$DNS_BAK" ] && return 0
	e="127.0.0.1#$dns_port"
	if [ -z "$(dns_mihomo_entries)" ]; then
		uci add_list "$DNSMASQ_SEC.server=$e"
		echo "server $e" >> "$DNS_CORE_STATE"
		changed=1
	fi
	for s in $(uci -q get "$DNSMASQ_SEC.server" 2>/dev/null); do
		case "$s" in
			/*|*"#$dns_port"|*":$dns_port") continue ;;
		esac
		uci -q del_list "$DNSMASQ_SEC.server=$s"
		echo "upstream $s" >> "$DNS_CORE_STATE"
		log "dnsmasq: $s left out while the core has to see every lookup"
		# a local resolver (AdGuard Home) stays in the chain only if the
		# core asks it: dnsmasq -> core -> it
		case "$s" in
			127.*|::1*)
				grep -qF "${s%%#*}:${s##*#}" "$MIHOMO_CONF" 2>/dev/null ||
					log "warning: the core does not ask $s, so it is out of the DNS chain now; make it the core's DNS (wizard -> DNS -> Local resolver)" ;;
		esac
		changed=1
	done
	nr="$(uci -q get "$DNSMASQ_SEC.noresolv")"
	if [ "$nr" != 1 ]; then
		echo "noresolv ${nr:--}" >> "$DNS_CORE_STATE"
		uci set "$DNSMASQ_SEC.noresolv=1"
		changed=1
	fi
	[ -n "$changed" ] || return 0
	dns_commit
	log "dnsmasq forwards to the core, which needs to see the LAN's lookups"
}

dns_core_off() {
	local k v
	[ -e "$DNS_CORE_STATE" ] || return 0
	while read -r k v; do
		case "$k" in
		server)
			uci -q del_list "$DNSMASQ_SEC.server=$v"
			# taken out by the watchdog meanwhile: not to come back
			if [ -e "$DNS_BAK" ]; then
				grep -v -x -F -- "$v" "$DNS_BAK" > "$DNS_BAK.tmp"
				mv -f "$DNS_BAK.tmp" "$DNS_BAK"
			fi
			;;
		upstream)
			# while the watchdog owns the list, it comes back with the list
			if [ -e "$DNS_BAK" ]; then echo "$v" >> "$DNS_BAK"
			else uci add_list "$DNSMASQ_SEC.server=$v"; fi
			;;
		noresolv)
			if [ "$v" = - ]; then uci -q delete "$DNSMASQ_SEC.noresolv"
			else uci set "$DNSMASQ_SEC.noresolv=$v"; fi
			;;
		esac
	done < "$DNS_CORE_STATE"
	rm -f "$DNS_CORE_STATE"
	dns_commit
	log "dnsmasq no longer forwards to the core for its capture"
}

# do_apply for auto_redirect
apply_core() {
	CORE_ROUTES="$("$SETCTL" core-routes 2>/dev/null)"
	core_conf_sync on || die "could not write the auto_redirect keys into $MIHOMO_CONF (see logread); nothing was changed"
	apply_nft_core
	flush_rules
	if [ "$(cr_get route_dns)" = 1 ] && [ "$dns_hijack" != 1 ]; then
		dns_core_on
	else
		dns_core_off
	fi
	if core_running && ! core_table; then
		# switched off by PATCH earlier (proxy off, a bypass): on again; a
		# tun that died needs off and on, since "on" is what it already says
		core_capture on
		core_wait_table || { core_capture off; core_capture on; core_wait_table; } ||
			log "warning: meow has not installed its capture (table inet meow); see 'logread -e mihomo'"
	fi
	[ -n "$(cr_get held)" ] && log "the core captures everything: $(cr_get held)"
	return 0
}

# ---------------------------------------------------------------------------
# actions
# ---------------------------------------------------------------------------

do_apply() {
	load_cfg
	dns_sync
	[ "$enabled" = 1 ] || { log "disabled in UCI, nothing to do"; do_flush_quiet; dns_core_off; exit 0; }
	case "$(flag_action)" in
		direct) log "auto-bypass is active, leaving traffic direct (the watchdog restores it)"; do_flush_quiet; exit 0 ;;
		block)  log "the kill switch is on, the LAN stays cut off (the watchdog restores it)"; apply_block; exit 0 ;;
	esac
	# Whoever asks -- a late watchdog restore, a hand-run start or restart --
	# a service switched off stays off.
	svc_enabled || { log "ClashWrt is switched off, nothing to do"; do_flush_quiet; dns_core_off; exit 0; }
	check_mode
	# back from auto_redirect: the core stops capturing (its tun goes back to
	# what the mode wants), then only the mode's own inbounds are left
	if [ "$mode" != auto_redirect ]; then
		core_conf_sync off || die "could not take the auto_redirect keys out of $MIHOMO_CONF (see logread)"
	fi
	inbound_sync || log "warning: config.yaml keeps the inbounds it had (see above)"
	resolve_ports
	check_prereq
	if [ "$mode" = auto_redirect ]; then
		apply_core
		fw_sig > "$SIGFILE"
		mkdir -p "$RUNDIR" && echo core > "$RUNDIR/bypass.applied"
		log "applied mode=$mode (the core captures) $(echo "$CORE_ROUTES" | sed -n 's/^direction: /direction=/p')"
		return 0
	fi
	# meow fills the include set from its own DNS answers, so the LAN's
	# lookups go to it (dnsmasq forwards there unless DNS hijack does it)
	if [ "$set_mode" = include ] && core_is_meow; then
		nftset_sync on || log "warning: dns.nftset not written; config.yaml domains reach meow only through dnsmasq lists"
		if [ "$dns_hijack" = 1 ]; then dns_core_off; else dns_core_on; fi
	else
		nftset_sync off
		dns_core_off
	fi
	ensure_fw4_zone
	apply_nft
	apply_routing

	# The ruleset was just rebuilt, so the set is empty again; refill it from
	# the cached list without going to the network.
	[ "$set_mode" != "off" ] && /usr/libexec/clashwrt/setctl.sh load >/dev/null 2>&1
	# a list never fetched yet (block_doh just turned on) is fetched in the
	# background: this runs under the firewall lock and a download is slow
	if [ "$block_doh" = 1 ]; then
		if [ -s /etc/clashwrt/doh4.list ]; then
			/usr/libexec/clashwrt/setctl.sh doh-load >/dev/null 2>&1
		else
			/usr/libexec/clashwrt/setctl.sh doh-update >/dev/null 2>&1 &
		fi
	fi

	fw_sig > "$SIGFILE"
	mkdir -p "$RUNDIR" && echo "$set_mode" > "$RUNDIR/bypass.applied"
	log "applied mode=$mode lan=$lan_devices tun=$tun_device tproxy_port=${tproxy_port:-none} redir_port=${redir_port:-none} bypass_set=$set_mode"
}

# The settings the ruleset is built from: everything in the config section
# except the watchdog's own, which never reach the firewall.
fw_sig() {
	uci -q show "$NAME.config" | grep -v "^$NAME\\.config\\.watchdog" | md5sum
}

# A settings change does not tear a working ruleset down. If the table is
# there and what it was built from has not changed, there is nothing to do; a
# watchdog toggle, a wizard save or a LuCI "Save & Apply" of other settings
# therefore costs the LAN no traffic at all. Anything else is a normal apply.
do_reload() {
	load_cfg
	if [ "$enabled" = 1 ] && [ ! -e "$FLAG" ] && svc_enabled &&
		nft list table $TABLE >/dev/null 2>&1 &&
		[ "$(cat "$SIGFILE" 2>/dev/null)" = "$(fw_sig)" ]; then
		return 0
	fi
	do_apply
}

do_flush_quiet() {
	rm -f "$SIGFILE"
	nft delete table $TABLE 2>/dev/null
	flush_rules
	# whatever the mode is now: the file asks the core to capture
	core_marked && core_capture off
	return 0
}

do_flush() {
	load_cfg
	do_flush_quiet
	dns_sync
	dns_core_off
	log "flushed"
}

do_status() {
	local wd eg
	load_cfg
	resolve_ports
	echo "enabled:      $enabled"
	echo -n "autobypass:   "
	[ -e "$FLAG" ] && echo yes || echo no
	echo -n "service:      "
	svc_enabled && echo on || echo off
	config_get wd config watchdog 0
	echo -n "watchdog:     "
	[ "$wd" = "1" ] && echo on || echo off
	echo -n "wd_running:   "
	wd_running && echo yes || echo no
	echo "autobypass_action: $(flag_action || echo none)"
	echo -n "egress:       "
	if [ "$(flag_action)" = block ]; then
		echo blocked
	elif [ -e "$FLAG" ]; then
		echo bypassed
	else
		eg="$(sed -n 's/^state:[[:space:]]*//p' "$RUNDIR/watchdog.state" 2>/dev/null | head -n1)"
		echo "${eg:-unknown}"
	fi
	echo "mode:         $mode"
	echo "lan_device:   $lan_devices"
	echo "ipv6_blocked: $([ "$block_ipv6" = 1 ] && nft list chain $TABLE leak6 >/dev/null 2>&1 && echo yes || echo no)"
	echo "wan_device:   ${wan_device:-unknown}"
	echo "tun_device:   $tun_device"
	echo "tproxy_port:  ${tproxy_port:-none}"
	echo "redir_port:   ${redir_port:-none}"
	echo -n "nft_table:    "
	nft list table $TABLE >/dev/null 2>&1 && echo present || echo absent
	echo -n "tun_link:     "
	ip link show "$tun_device" >/dev/null 2>&1 && echo up || echo absent
	echo -n "tun_route:    "
	if [ "$mode" = auto_redirect ]; then
		echo "n/a"
	else
		ip route show table "$table_tun" 2>/dev/null | grep -q "dev $tun_device" && echo ok || echo missing
	fi
	echo -n "core_capture: "
	if core_table; then echo on
	elif core_marked; then echo off
	else echo none; fi
	echo -n "mihomo:       "
	pidof mihomo >/dev/null 2>&1 && echo running || echo stopped

	# What the config can serve, next to what the firewall was told to build.
	local serves
	serves="$(conf_modes 2>/dev/null)" || serves=""
	echo "conf_modes:   ${serves:-unknown}"
	if [ -n "$serves" ] && ! conf_serves_mode "$mode"; then
		echo "conf_agrees:  no"
	elif [ -n "$serves" ]; then
		echo "conf_agrees:  yes"
	else
		echo "conf_agrees:  unknown"
	fi
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
	[ ! -e "$FLAG" ] || exit 0
	# switched off from the Overview page: do not rebuild what it stopped
	svc_enabled || exit 0
	resolve_ports

	nft list table $TABLE >/dev/null 2>&1 || { log "nft table missing, re-applying"; do_apply; exit 0; }

	if [ "$mode" = auto_redirect ]; then
		core_running || exit 0
		core_table && exit 0
		# Its tun died, or something deleted the table. Once a minute at
		# most: a tun that cannot start would otherwise be bounced by every
		# hotplug event it causes.
		local stamp="$RUNDIR/core-capture.try" now
		now="$(cut -d. -f1 /proc/uptime)"
		[ $((now - $(cat "$stamp" 2>/dev/null || echo -999))) -ge 60 ] || exit 0
		mkdir -p "$RUNDIR" && echo "$now" > "$stamp"
		log "meow's capture (table inet meow) is gone, switching its tun off and on"
		core_capture off
		core_capture on
		exit 0
	fi

	if mode_needs_tun && ip link show "$tun_device" >/dev/null 2>&1; then
		ip route show table "$table_tun" 2>/dev/null | grep -q "dev $tun_device" || {
			ip route replace default dev "$tun_device" table "$table_tun"
			ip rule show | grep -q "fwmark $(printf '0x%x' "$mark_tun") " || \
				ip rule add fwmark "$mark_tun" table "$table_tun" pref "$((rule_pref + 1))"
			log "restored table $table_tun route after $tun_device was recreated"
		}
	fi
}

# The watchdog's two moves, as one atomic step each. Both refuse to act while
# the user has the proxy off: that decision always wins, so a watchdog that
# wakes up late can never turn the proxy back on.
do_autobypass() {
	load_cfg
	case "${1:-}" in
	on)
		[ "$enabled" = 1 ] || { echo "proxy is off, nothing to bypass"; exit 0; }
		# switched off from the Overview: a watchdog caught mid-tick must not
		# start changing dnsmasq behind it
		svc_enabled || { echo "ClashWrt is switched off, nothing to bypass"; exit 0; }
		mkdir -p "$RUNDIR"
		if [ "$wd_action" = block ]; then
			echo block > "$FLAG"
			do_flush_quiet
			apply_block
			log "kill switch ON: proxy path is down, the LAN is cut off from the internet"
		else
			echo direct > "$FLAG"
			do_flush_quiet
			dns_sync
			log "auto-bypass ON: proxy path is down, traffic goes direct"
		fi
		;;
	off)
		rm -f "$FLAG"
		if [ "$enabled" = 1 ]; then
			do_apply
			log "auto-bypass OFF: proxy path is back"
		else
			dns_sync
		fi
		;;
	*) echo "usage: $0 autobypass on|off" >&2; exit 1 ;;
	esac
}

# The tun device appeared: the core (re)started it. With capture wanted,
# the usual repairs; with the proxy off, switched off or bypassed while the
# file still asks the core to capture (a core restarted meanwhile), the
# capture goes off again at once.
do_hotplug() {
	load_cfg
	if [ "$enabled" = 1 ] && [ ! -e "$FLAG" ] && svc_enabled; then
		if [ "$mode" != auto_redirect ] && core_marked; then
			do_apply
			return 0
		fi
		do_check
		return 0
	fi
	if core_marked && core_table; then
		core_capture off && log "the core started capturing while ClashWrt is not; switched that off"
	fi
	return 0
}

# The keys again from the current config.yaml and UCI, for setctl.sh (rules
# reloaded) and confctl.sh (a new config.yaml installed). Only in
# auto_redirect mode with the proxy on; the rest is do_apply's.
do_core_sync() {
	load_cfg
	# a new config.yaml (confctl.sh) gets the mode's inbounds before the core
	# reads it, whatever the mode
	case "$(inbound_wants)" in "") ;; *) inbound_sync "${1:-}" ;; esac
	# and the dns.nftset key the last apply decided on
	if [ "$mode" != auto_redirect ] && core_is_meow; then
		if [ "$set_mode" = include ]; then nftset_sync on "${1:-}"; else nftset_sync off "${1:-}"; fi
	fi
	[ "$mode" = auto_redirect ] && [ "$enabled" = 1 ] && [ ! -e "$FLAG" ] && svc_enabled || return 0
	CORE_ROUTES="$("$SETCTL" core-routes 2>/dev/null)"
	core_conf_sync on "${1:-}" || return 1
	if [ "$(cr_get route_dns)" = 1 ] && [ "$dns_hijack" != 1 ]; then dns_core_on; else dns_core_off; fi
	return 0
}

# What netifd currently reports, so the UI can show what "auto" resolved to.
do_detect() {
	load_cfg
	echo "lan_device: $lan_devices"
	echo "wan_device: ${wan_device:-unknown}"
}

main() {
	case "${1:-}" in
		apply)      fw_lock; do_apply ;;
		reload)     fw_lock; do_reload ;;
		flush)      fw_lock; do_flush ;;
		status)     do_status ;;
		check)      fw_lock; do_check ;;
		autobypass) fw_lock; do_autobypass "${2:-}" ;;
		dns-sync)   fw_lock; load_cfg; dns_sync ;;
		core-sync)  fw_lock; do_core_sync "${2:-}" ;;
		hotplug)    fw_lock; do_hotplug ;;
		detect)     do_detect ;;
		selftest)   exec /usr/libexec/clashwrt/selftest.sh ;;
		*) echo "usage: $0 apply|reload|flush|status|check|detect|selftest|dns-sync|autobypass on|off|core-sync [--no-reload]|hotplug" >&2; exit 1 ;;
	esac
}

[ -n "${CLASHWRT_TEST:-}" ] || main "$@"
