#!/bin/sh
# SPDX-License-Identifier: GPL-3.0-or-later
#
# Fail-open watchdog: when the proxy path dies but the internet itself is
# fine, send traffic direct until the path is healthy again.
#
# The firewall rules steer every LAN connection into mihomo. If mihomo hangs,
# or every proxy server behind it is unreachable, that steering turns a dead
# VPN into a dead network for the whole house. This daemon notices and lifts
# the rules, then puts them back.
#
# How it decides, deliberately dull:
#
#   1. Ask mihomo's own API to time a request through the proxy group
#      (GET /proxies/<group>/delay). That tests the real path -- core, group,
#      server -- not just "is the process alive". Any of the URLs answering
#      204 is a pass.
#   2. Only when that fails, make one plain request out of the WAN. If the
#      WAN is down too there is nothing a bypass could fix, so nothing flips.
#   3. N consecutive proxy failures with a healthy WAN -> bypass. In bypass the
#      proxy path is still probed (mihomo's own sockets are not subject to the
#      ruleset), and N consecutive passes after a minimum hold -> restore.
#   4. A path that keeps coming back and dying again gets a longer hold each
#      time, up to a cap, so it cannot flap the network.
#
# The user's choice always wins: with the proxy switched off (UCI enabled=0)
# this does nothing, and it can never switch the proxy on.
#
# Bypass and restore are 'fw.sh autobypass on|off', which take the same lock
# as every other change to the ruleset. The flag lives in /var/run, so a
# reboot starts proxy-first.
#
# Usage: watchdog.sh run | probe | status | reset | stop

# shellcheck source=/dev/null
. "${CLASHWRT_FUNCTIONS:-/lib/functions.sh}"

NAME="clashwrt"
RUNDIR="${CLASHWRT_RUNDIR:-/var/run/clashwrt}"
FLAG="$RUNDIR/autobypass"
STATE="$RUNDIR/watchdog.state"
FW="${CLASHWRT_FW:-/usr/libexec/clashwrt/fw.sh}"

FLAP_WINDOW=600
RESET_GRACE=30

DEFAULT_URLS="http://www.gstatic.com/generate_204 http://cp.cloudflare.com/generate_204 http://www.google.com/generate_204"

log() { logger -t "$NAME" "watchdog: $*"; return 0; }

# Uptime, not wall time: monotonic, and immune to NTP stepping the clock in
# the middle of a hold.
now() { cut -d. -f1 /proc/uptime; }

num() {
	case "$1" in
		''|*[!0-9]*) echo "$2" ;;
		*) echo "$1" ;;
	esac
}

load_cfg() {
	config_load "$NAME"
	config_get enabled     config enabled          0
	config_get wd          config watchdog         0
	config_get group_cfg   config watchdog_group   ""
	config_get f_fail      config watchdog_fail    3
	config_get f_ok        config watchdog_ok      3
	config_get f_interval  config watchdog_interval 20
	config_get f_fast      config watchdog_fast    5
	config_get f_hold      config watchdog_hold    120
	config_get f_hold_max  config watchdog_hold_max 900
	config_get f_grace     config watchdog_grace   90
	config_get f_timeout   config watchdog_timeout 5
	config_get urls        config watchdog_url     ""
	config_get ctl_urls    config watchdog_ctl_url ""
	config_get api_port    config api_port         9090
	config_get dns_port    config dns_port         1053
	config_get mihomo_dir  config mihomo_dir       /etc/mihomo

	FAIL_N="$(num "$f_fail" 3)";          [ "$FAIL_N" -ge 1 ] || FAIL_N=3
	OK_N="$(num "$f_ok" 3)";              [ "$OK_N" -ge 1 ] || OK_N=3
	INTERVAL="$(num "$f_interval" 20)";   [ "$INTERVAL" -ge 5 ] || INTERVAL=5
	FAST="$(num "$f_fast" 5)";            [ "$FAST" -ge 1 ] || FAST=1
	HOLD="$(num "$f_hold" 120)"
	HOLD_MAX="$(num "$f_hold_max" 900)";  [ "$HOLD_MAX" -ge "$HOLD" ] || HOLD_MAX="$HOLD"
	GRACE="$(num "$f_grace" 90)"
	TIMEOUT="$(num "$f_timeout" 5)";      [ "$TIMEOUT" -ge 1 ] || TIMEOUT=5
	[ -n "$urls" ] || urls="$DEFAULT_URLS"
	[ -n "$ctl_urls" ] || ctl_urls="$DEFAULT_URLS"
	CONF="$mihomo_dir/config.yaml"
}

# Every byte as %XX: group names and URLs go into a query string, and a group
# called "Auto Select" or one in Cyrillic must survive that. Pure shell: the
# router's busybox has no od. Printable ASCII costs no process; only a byte
# outside it takes one, because printf then reports it sign-extended and the
# low two digits are the byte.
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

# The group to time. An explicit UCI value wins; otherwise the terminal MATCH
# rule names what everything unmatched goes through, which is the thing whose
# health matters. DIRECT or REJECT name no group, and "Proxy" is what the
# wizard calls its own.
detect_group() {
	local g
	if [ -n "$group_cfg" ]; then
		echo "$group_cfg"
		return 0
	fi
	# the terminal MATCH of the top-level rules, not one inside sub-rules
	g="$(awk '/^[A-Za-z0-9_-]+:/ { r = ($0 ~ /^rules:/) } r' "$CONF" 2>/dev/null |
		sed -n 's/^[[:space:]]*-[[:space:]]*MATCH,[[:space:]]*\([^ ,#]*\).*/\1/p' | tail -n1)"
	case "$g" in
		DIRECT|REJECT|"") g="Proxy" ;;
	esac
	echo "$g"
}

api_secret() {
	[ -f "$CONF" ] || return 0
	sed -n 's/^secret:[[:space:]]*\([^#]*\).*/\1/p' "$CONF" | head -n1 | tr -d "\"' \t\r"
}

# One delay request to mihomo. Prints the HTTP status (000 when nothing
# answered) and, on a separate first line, the body.
api_delay() {
	local g="$1" u="$2" secret
	secret="$(api_secret)"
	if [ -n "$secret" ]; then
		curl -s -m "$((TIMEOUT + 3))" -H "Authorization: Bearer $secret" -w '\n%{http_code}' \
			"http://127.0.0.1:${api_port}/proxies/$(urlenc "$g")/delay?url=$(urlenc "$u")&timeout=$((TIMEOUT * 1000))&expected=204" 2>/dev/null
	else
		curl -s -m "$((TIMEOUT + 3))" -w '\n%{http_code}' \
			"http://127.0.0.1:${api_port}/proxies/$(urlenc "$g")/delay?url=$(urlenc "$u")&timeout=$((TIMEOUT * 1000))&expected=204" 2>/dev/null
	fi
}

# Sets PROBE_PX (ok|fail|skip), PROBE_DELAY and PROBE_WHY.
#
# 'skip' is for the answers that say nothing about the proxy: a group that
# does not exist (404) or an API that refuses us (401). Treating those as a
# dead proxy would bypass a healthy network because of a typo in a setting.
probe_proxy() {
	local u out code body
	PROBE_PX="fail"; PROBE_DELAY=""; PROBE_WHY=""
	GROUP="$(detect_group)"
	for u in $urls; do
		out="$(api_delay "$GROUP" "$u")"
		code="$(echo "$out" | tail -n1)"
		body="$(echo "$out" | sed '$d')"
		case "$code" in
			200)
				PROBE_PX="ok"
				PROBE_DELAY="$(echo "$body" | sed -n 's/.*"delay":[[:space:]]*\([0-9]*\).*/\1/p')"
				PROBE_WHY=""
				return 0
				;;
			404)
				PROBE_PX="skip"; PROBE_WHY="group '$GROUP' not found in mihomo"
				return 0
				;;
			401|403)
				PROBE_PX="skip"; PROBE_WHY="mihomo API refused the request (secret?)"
				return 0
				;;
			000|"") PROBE_WHY="mihomo API not answering" ;;
			*)      PROBE_WHY="no 204 through '$GROUP' (HTTP $code)" ;;
		esac
	done
	return 0
}

wan_device() {
	"$FW" detect 2>/dev/null | sed -n 's/^wan_device:[[:space:]]*//p' | head -n1
}

ctl_get() {
	if [ -n "$1" ] && [ "$1" != unknown ]; then
		curl -s -m 5 --interface "$1" -o /dev/null -w '%{http_code}' "$2" 2>/dev/null
	else
		curl -s -m 5 -o /dev/null -w '%{http_code}' "$2" 2>/dev/null
	fi
}

# A plain request out of the WAN, bypassing the proxy. Failing this means the
# internet is down, not the VPN.
probe_wan() {
	local dev u
	dev="$(wan_device)"
	for u in $ctl_urls; do
		[ "$(ctl_get "$dev" "$u")" = "204" ] && return 0
	done
	return 1
}

# ---------------------------------------------------------------------------
# state
# ---------------------------------------------------------------------------

ST="ok"
ST_WHY=""
ST_SINCE=0
FAILS=0
OKS=0
HOLD_CUR=0
FLAPS=0
BYP_TS=0
LAST_RESTORE=0
GRACE_UNTIL=0
NEXT=20
DELAY=""

set_state() {
	[ "$ST" = "$1" ] || ST_SINCE="$(now)"
	ST="$1"
	ST_WHY="$2"
}

write_state() {
	local tmp="$STATE.$$"
	mkdir -p "$RUNDIR"
	{
		# a stopped daemon names no pid: once it is gone the number can be
		# reused, and 'stop' would then signal whatever got it
		[ "$ST" = stopped ] && echo "pid:" || echo "pid: $$"
		echo "state: $ST"
		echo "why: $ST_WHY"
		echo "group: ${GROUP:-}"
		echo "since: $ST_SINCE"
		echo "fails: $FAILS"
		echo "oks: $OKS"
		echo "hold: $HOLD_CUR"
		echo "bypass_at: $BYP_TS"
		echo "flaps: $FLAPS"
		echo "delay: ${DELAY:-}"
		echo "fail_limit: $FAIL_N"
		echo "ok_limit: $OK_N"
	} > "$tmp" && mv -f "$tmp" "$STATE"
}

do_bypass() {
	local t="$1"
	if [ "$LAST_RESTORE" -gt 0 ] && [ $((t - LAST_RESTORE)) -lt "$FLAP_WINDOW" ]; then
		HOLD_CUR=$((HOLD_CUR * 2))
		[ "$HOLD_CUR" -le "$HOLD_MAX" ] || HOLD_CUR="$HOLD_MAX"
		FLAPS=$((FLAPS + 1))
	else
		HOLD_CUR="$HOLD"
		FLAPS=0
	fi
	"$FW" autobypass on >/dev/null 2>&1
	if [ -e "$FLAG" ]; then
		BYP_TS="$t"
		OKS=0
		FAILS=0
		log "proxy path down for $FAIL_N probes while the WAN is up; bypassing (hold ${HOLD_CUR}s)"
		set_state bypassed "$PROBE_WHY"
	fi
}

do_restore() {
	local t="$1"
	"$FW" autobypass off >/dev/null 2>&1
	if [ ! -e "$FLAG" ]; then
		LAST_RESTORE="$t"
		OKS=0
		FAILS=0
		log "proxy path healthy for $OK_N probes; restored"
		set_state ok ""
	fi
}

# One round: probe, update the counters, maybe flip, and decide how long to
# sleep. Everything that touches the system goes through probe_proxy,
# probe_wan, do_bypass and do_restore, which is what the flip logic is tested
# against.
tick() {
	local t
	t="$(now)"
	DELAY=""

	if [ "$enabled" != "1" ]; then
		# The user switched the proxy off. Their choice stands; make sure no
		# stale flag outlives it.
		[ -e "$FLAG" ] && "$FW" autobypass off >/dev/null 2>&1
		FAILS=0; OKS=0; GRACE_UNTIL=0
		set_state idle "the proxy is switched off"
		NEXT="$INTERVAL"
		return 0
	fi

	if [ -e "$FLAG" ]; then
		if [ "$ST" != "bypassed" ]; then
			BYP_TS="$t"; OKS=0
			[ "$HOLD_CUR" -gt 0 ] || HOLD_CUR="$HOLD"
			set_state bypassed "bypass was switched on elsewhere"
		fi
	elif [ "$ST" = "bypassed" ]; then
		# restored from outside (the Overview's forced restore)
		FAILS=0; OKS=0; HOLD_CUR="$HOLD"; GRACE_UNTIL=$((t + RESET_GRACE))
		set_state ok ""
	fi

	probe_proxy
	DELAY="$PROBE_DELAY"

	if [ "$PROBE_PX" = "skip" ]; then
		FAILS=0; OKS=0
		set_state skip "$PROBE_WHY"
		NEXT="$INTERVAL"
		return 0
	fi

	if [ "$ST" = "bypassed" ]; then
		if [ "$PROBE_PX" = "ok" ]; then
			OKS=$((OKS + 1))
		else
			OKS=0
		fi
		if [ "$OKS" -ge "$OK_N" ] && [ $((t - BYP_TS)) -ge "$HOLD_CUR" ]; then
			do_restore "$t"
		fi
		NEXT="$INTERVAL"
		if [ "$OKS" -gt 0 ] && [ $((t - BYP_TS)) -ge "$HOLD_CUR" ]; then NEXT="$FAST"; fi
		return 0
	fi

	if [ "$PROBE_PX" = "ok" ]; then
		FAILS=0
		GRACE_UNTIL=0
		set_state ok ""
		NEXT="$INTERVAL"
		return 0
	fi

	# the proxy path failed
	if [ "$t" -lt "$GRACE_UNTIL" ]; then
		FAILS=0
		set_state grace "starting up: $PROBE_WHY"
		NEXT="$FAST"
		return 0
	fi

	if probe_wan; then
		FAILS=$((FAILS + 1))
		set_state failing "$PROBE_WHY"
		NEXT="$FAST"
		if [ "$FAILS" -ge "$FAIL_N" ]; then
			do_bypass "$t"
			[ "$ST" != "bypassed" ] || NEXT="$INTERVAL"
		fi
	else
		FAILS=0
		set_state wan_down "the internet is unreachable, so a bypass would not help"
		NEXT="$INTERVAL"
	fi
	return 0
}

# ---------------------------------------------------------------------------
# commands
# ---------------------------------------------------------------------------

# Sleep in the background and wait on it, so SIGTERM from procd interrupts
# the nap instead of waiting out up to 20 seconds.
nap() {
	sleep "$1" &
	wait $!
}

do_run() {
	mkdir -p "$RUNDIR"
	load_cfg
	HOLD_CUR="$HOLD"
	ST_SINCE="$(now)"
	GRACE_UNTIL=$(( $(now) + GRACE ))
	trap 'ST=stopped; ST_WHY="stopped"; write_state; exit 0' TERM INT

	set_state grace "starting up"
	write_state
	log "started (group auto-detected from the MATCH rule unless watchdog_group is set; grace ${GRACE}s)"

	while :; do
		load_cfg
		if [ "$wd" = "1" ]; then
			tick
		else
			set_state idle "the watchdog is switched off"
			NEXT="$INTERVAL"
		fi
		write_state
		nap "$NEXT"
	done
}

# One look, no side effects.
do_probe() {
	load_cfg
	probe_proxy
	echo "group:         $GROUP"
	echo "proxy:         $PROBE_PX"
	[ -z "$PROBE_DELAY" ] || echo "delay:         $PROBE_DELAY"
	[ -z "$PROBE_WHY" ] || echo "why:           $PROBE_WHY"
	if [ "$PROBE_PX" = "ok" ]; then
		echo "wan:           not checked"
	elif probe_wan; then
		echo "wan:           ok"
	else
		echo "wan:           down"
	fi
}

# Whether $1 is a live watchdog, not merely a live process: a pid from the
# state file can outlive the daemon and be handed to something else.
is_watchdog() {
	case "$1" in ''|*[!0-9]*) return 1 ;; esac
	kill -0 "$1" 2>/dev/null || return 1
	tr '\0' ' ' < "/proc/$1/cmdline" 2>/dev/null | grep -q 'watchdog.sh run'
}

state_get() {
	[ -f "$STATE" ] || return 1
	sed -n "s/^$1:[[:space:]]*//p" "$STATE" | head -n1
}

# Whether dnsmasq hands DNS to mihomo. A bypass takes that forward out of
# dnsmasq (fw.sh autobypass on), so while bypassed this is only true when it
# could not be taken out -- the LAN is then resolving through the core that
# died, which is what the UI warns about.
dns_forwarded() {
	local s
	s="$(uci -q get 'dhcp.@dnsmasq[0].server' 2>/dev/null)"
	case "$s" in
		*"#$dns_port"*|*":$dns_port"*) return 0 ;;
	esac
	return 1
}

do_status() {
	local pid running t since st byp hold left
	load_cfg
	echo -n "wd_enabled:      "
	[ "$wd" = "1" ] && echo on || echo off

	pid="$(state_get pid)"
	running=no
	if is_watchdog "$pid"; then
		running=yes
	fi
	echo "wd_running:      $running"

	st="$(state_get state)"
	if [ "$running" = "no" ]; then
		if [ "$wd" = "1" ]; then st="stopped"; else st="off"; fi
	fi
	echo "wd_state:        ${st:-off}"

	if [ "$running" = "yes" ]; then
		t="$(now)"
		since="$(state_get since)"
		echo "wd_why:          $(state_get why)"
		echo "wd_group:        $(state_get group)"
		echo "wd_fails:        $(state_get fails)"
		echo "wd_fail_limit:   $(state_get fail_limit)"
		echo "wd_oks:          $(state_get oks)"
		echo "wd_ok_limit:     $(state_get ok_limit)"
		echo "wd_flaps:        $(state_get flaps)"
		echo "wd_delay:        $(state_get delay)"
		echo "wd_age:          $(num "$((t - $(num "$since" "$t")))" 0)"
		if [ "$st" = "bypassed" ]; then
			byp="$(num "$(state_get bypass_at)" "$t")"
			hold="$(num "$(state_get hold)" "$HOLD")"
			left=$((hold - (t - byp)))
			[ "$left" -gt 0 ] || left=0
			echo "wd_hold:         $hold"
			echo "wd_hold_left:    $left"
		fi
	fi

	echo -n "wd_dns_forward:  "
	dns_forwarded && echo yes || echo no
}

# Forced restore: lift the bypass now, whatever the probes say. Works with the
# daemon stopped too, which is the point -- it is the way out when the
# automation itself is the thing in doubt. The daemon sees the flag vanish and
# gives the path a short grace before judging it again.
do_reset() {
	load_cfg
	if [ "$enabled" != "1" ]; then
		"$FW" autobypass off >/dev/null 2>&1
		echo "the proxy is switched off; nothing to restore"
		return 0
	fi
	"$FW" autobypass off || { echo "could not restore the proxy rules" >&2; return 1; }
	echo "proxy rules restored"
}

# Stop the daemon by the pid it wrote, for when procd no longer owns it (the
# init script normally does this). TERM first, so it records 'stopped'.
do_stop() {
	local pid i=0
	pid="$(state_get pid)"
	is_watchdog "$pid" || { echo "the watchdog is not running"; return 0; }
	kill -TERM "$pid" 2>/dev/null
	while kill -0 "$pid" 2>/dev/null && [ "$i" -lt 5 ]; do
		sleep 1
		i=$((i + 1))
	done
	kill -0 "$pid" 2>/dev/null && kill -KILL "$pid" 2>/dev/null
	echo "watchdog stopped"
}

main() {
	case "${1:-}" in
		run)    do_run ;;
		probe)  do_probe ;;
		status) do_status ;;
		reset)  do_reset ;;
		stop)   do_stop ;;
		*) echo "usage: $0 run|probe|status|reset|stop" >&2; exit 1 ;;
	esac
}

[ -n "${CLASHWRT_TEST:-}" ] || main "$@"
