#!/bin/sh
# SPDX-License-Identifier: GPL-3.0-or-later
#
# The kill switches behind the Overview page, as one scriptable thing.
#
#   svc    the whole ClashWrt service: its init script, which owns the proxy
#          rules and the watchdog. Off means disabled at boot AND stopped, so
#          it stays off across a reboot, the watchdog sleeps and hotplug
#          leaves the ruleset alone. The UCI settings are not touched, so
#          switching it on again brings back exactly what was there before.
#          The status reports both halves: 'service' is whether it starts at
#          boot, 'svc_live' whether any of it (rules, watchdog) runs right
#          now. They can disagree -- LuCI's Startup page, a hand-run
#          'disable', an interrupted stop -- and the page shows what runs.
#   proxy  the firewall side: the rules that send LAN traffic into mihomo.
#          Off means the router forwards everything directly, as if ClashWrt
#          were not installed. It owns the UCI 'enabled' flag.
#   core   the mihomo daemon itself: running now and started at boot. Switching
#          it off is refused while the proxy rules are loaded, as switching
#          the proxy on is refused while the core is down.
#   all    both, in the only safe order: switching off takes the proxy rules
#          away first (so nothing is steered into a dying core), switching on
#          starts the core first (so nothing is steered into a core that is
#          not there yet).
#
# Every action is idempotent and runs under a lock, so a double click, two
# browser tabs and a cron job cannot interleave. A mutating action ends by
# printing the status, so one round trip updates the page.
#
# Short of 'svc off', the clashwrt init script stays enabled at boot on
# purpose: with 'enabled' at 0 it does nothing, and with it at 1 it is exactly
# what restores the proxy after a reboot.
#
# Usage: powerctl.sh status
#        powerctl.sh svc   on|off
#        powerctl.sh proxy on|off
#        powerctl.sh core  on|off
#        powerctl.sh all   on|off

NAME="clashwrt"
# The CLASHWRT_* overrides exist so tests/ can run this file off the router.
LOCKFILE="${CLASHWRT_LOCKFILE:-/var/lock/clashwrt-power.lock}"
CORE_INIT="${CLASHWRT_CORE_INIT:-/etc/init.d/mihomo}"
SELF_INIT="${CLASHWRT_SELF_INIT:-/etc/init.d/clashwrt}"
WATCHDOG="${CLASHWRT_WATCHDOG:-/usr/libexec/clashwrt/watchdog.sh}"
FW="${CLASHWRT_FW:-/usr/libexec/clashwrt/fw.sh}"
FLAG="${CLASHWRT_RUNDIR:-/var/run/clashwrt}/autobypass"
RCD="${CLASHWRT_RCD:-/etc/rc.d}"

log() { logger -t "$NAME" "$@"; return 0; }
die() {
	logger -t "$NAME" "ERROR: $*"
	echo "$NAME: ERROR: $*" >&2
	exit 1
}

# One switch at a time, under a lock of its own (the code is lock.sh's; the
# file is not fw.sh's, which this script takes again through fw.sh). The
# wait is bounded (CLASHWRT_LOCK_WAIT seconds, default 10) so a stuck holder
# shows up as an error in LuCI rather than a request that never returns.
# shellcheck source=lock.sh
. "${CLASHWRT_LIBEXEC:-/usr/libexec/clashwrt}/lock.sh"
take_lock() { cw_lock "$LOCKFILE" 10 switch; }

proxy_enabled() { [ "$(uci -q get "$NAME.config.enabled")" = "1" ]; }
rules_present() { nft list table inet clashwrt >/dev/null 2>&1; }
core_running()  { pidof mihomo >/dev/null 2>&1; }
core_installed() { [ -x "$CORE_INIT" ] && { command -v mihomo >/dev/null 2>&1 || [ -x /usr/bin/mihomo ]; }; }
core_boot()     { [ -x "$CORE_INIT" ] && "$CORE_INIT" enabled >/dev/null 2>&1; }
# Starts at boot = any S link, which is all /etc/rc.d acts on. rc.common's
# 'enabled' also wants the K link under today's exact numbers, so a router
# with only an S link boots the service yet reads as disabled.
svc_enabled()   { ls "$RCD"/S[0-9][0-9]"$NAME" >/dev/null 2>&1; }
wd_running()    { [ -x "$WATCHDOG" ] && "$WATCHDOG" status 2>/dev/null | grep -q '^wd_running:[[:space:]]*yes'; }
wd_wanted()     { proxy_enabled && [ "$(uci -q get "$NAME.config.watchdog")" = "1" ]; }
# whether anything of the service is at work right now, whatever boot says
svc_live()      { rules_present || wd_running; }

set_enabled() {
	uci -q set "$NAME.config.enabled=$1" || return 1
	uci -q commit "$NAME"
}

wait_core() {
	local i=0
	while [ "$i" -lt "${1:-10}" ]; do
		core_running && return 0
		sleep 1
		i=$((i + 1))
	done
	return 1
}

do_status() {
	echo -n "service:         "
	svc_enabled && echo on || echo off
	echo -n "svc_live:        "
	svc_live && echo yes || echo no
	echo -n "proxy:           "
	proxy_enabled && echo on || echo off
	echo -n "rules:           "
	rules_present && echo present || echo absent
	echo -n "core:            "
	if ! core_installed; then
		echo missing
	elif core_running; then
		echo running
	else
		echo stopped
	fi
	echo -n "core_boot:       "
	core_boot && echo enabled || echo disabled
	echo -n "autobypass:      "
	[ -e "$FLAG" ] && echo yes || echo no
	[ -x "$WATCHDOG" ] && "$WATCHDOG" status 2>/dev/null
	return 0
}

proxy_off() {
	if ! proxy_enabled && ! rules_present && [ ! -e "$FLAG" ]; then
		echo "proxy was already off"
		return 0
	fi
	set_enabled 0 || die "could not write /etc/config/$NAME"
	# stop_service flushes the ruleset and drops any auto-bypass flag
	"$SELF_INIT" stop >/dev/null 2>&1
	rm -f "$FLAG"
	rules_present && die "the proxy rules are still loaded; run '$SELF_INIT stop' and look at 'logread -e $NAME'"
	log "proxy switched off"
	echo "proxy switched off"
}

svc_off() {
	[ -x "$SELF_INIT" ] || die "$SELF_INIT is missing; ClashWrt is not installed properly"
	if ! svc_enabled && ! rules_present && [ ! -e "$FLAG" ] && ! wd_running; then
		echo "ClashWrt was already off"
		return 0
	fi
	# disable first: if the stop below is interrupted, the next boot still
	# honours the choice
	"$SELF_INIT" disable >/dev/null 2>&1
	svc_enabled && die "could not disable $SELF_INIT, so it would come back after a reboot"
	"$SELF_INIT" stop >/dev/null 2>&1

	# The init script's stop is the normal way down, but it only reaches what
	# procd still owns, and it says nothing when part of it fails. Whatever
	# is left gets taken down directly: procd's record of the service (so a
	# respawn cannot bring the watchdog back), then the watchdog by its pid,
	# then the rules. fw.sh no longer builds rules for a disabled service, so
	# a watchdog caught mid-restore cannot put them back behind this.
	if wd_running; then
		command -v ubus >/dev/null 2>&1 && ubus call service delete "{\"name\":\"$NAME\"}" >/dev/null 2>&1
		"$WATCHDOG" stop >/dev/null 2>&1
	fi
	rm -f "$FLAG"
	"$FW" dns-sync >/dev/null 2>&1
	rules_present && "$FW" flush >/dev/null 2>&1

	rules_present && die "ClashWrt is disabled, but the proxy rules are still loaded; run '$FW flush' and look at 'logread -e $NAME'"
	local i=0
	while wd_running && [ "$i" -lt 5 ]; do
		sleep 1
		i=$((i + 1))
	done
	wd_running && die "ClashWrt is disabled, but the watchdog is still running; run '$WATCHDOG stop'"
	log "ClashWrt switched off"
	echo "ClashWrt switched off"
}

svc_on() {
	[ -x "$SELF_INIT" ] || die "$SELF_INIT is missing; ClashWrt is not installed properly"
	# on means: starts at boot, and runs now what the settings ask for
	if svc_enabled && { ! proxy_enabled || rules_present || [ -e "$FLAG" ]; } &&
		{ ! wd_wanted || wd_running; }; then
		echo "ClashWrt was already on"
		return 0
	fi
	# same rule as switching the proxy on: never steer traffic into a core
	# that is not there
	if proxy_enabled && ! core_running; then
		die "the proxy is set to on but the mihomo core is not running; start the core first ('core on'), then switch ClashWrt on"
	fi
	"$SELF_INIT" enable >/dev/null 2>&1
	svc_enabled || die "could not enable $SELF_INIT"
	"$SELF_INIT" start >/dev/null 2>&1
	if proxy_enabled && [ ! -e "$FLAG" ] && ! rules_present; then
		die "ClashWrt is enabled but the proxy rules did not load (see 'logread -e $NAME')"
	fi
	# procd spawns the watchdog on its own time
	local i=0
	while wd_wanted && ! wd_running && [ "$i" -lt 5 ]; do
		sleep 1
		i=$((i + 1))
	done
	if wd_wanted && ! wd_running; then
		echo "warning: the watchdog did not start (see 'logread -e $NAME')" >&2
	fi
	log "ClashWrt switched on"
	echo "ClashWrt switched on"
}

proxy_on() {
	svc_enabled || die "ClashWrt is switched off; switch it on first"
	if proxy_enabled && rules_present && [ ! -e "$FLAG" ]; then
		echo "proxy was already on"
		return 0
	fi

	# The rules steer every LAN connection into mihomo. With no mihomo behind
	# them that is an outage, and the one situation this page exists to
	# prevent, so it is refused rather than allowed and cleaned up later.
	core_running || die "the mihomo core is not running; start it first (or use 'all on')"

	local prev
	prev="$(uci -q get "$NAME.config.enabled")"
	[ -n "$prev" ] || prev=0

	set_enabled 1 || die "could not write /etc/config/$NAME"
	rm -f "$FLAG"
	"$SELF_INIT" restart >/dev/null 2>&1

	if ! rules_present; then
		set_enabled "$prev"
		"$SELF_INIT" stop >/dev/null 2>&1
		die "could not load the proxy rules, switched back to '$prev' (see 'logread -e $NAME')"
	fi
	log "proxy switched on"
	echo "proxy switched on"
}

core_off() {
	if ! core_installed; then
		echo "core is not installed"
		return 0
	fi
	# the mirror of proxy_on's refusal: rules steering into a stopped core are
	# the outage this page exists to prevent
	if proxy_enabled && rules_present; then
		die "the proxy is still on; switch it off first (or use 'all off')"
	fi
	if core_running || core_boot; then
		"$CORE_INIT" stop >/dev/null 2>&1
		"$CORE_INIT" disable >/dev/null 2>&1
	else
		echo "core was already off"
		return 0
	fi
	core_running && die "the mihomo core did not stop"
	log "mihomo core switched off"
	echo "core switched off"
}

core_on() {
	core_installed || die "the mihomo core is not installed (install it from Settings -> Maintenance)"
	if core_running && core_boot; then
		echo "core was already on"
		return 0
	fi
	"$CORE_INIT" enable >/dev/null 2>&1
	core_running || "$CORE_INIT" start >/dev/null 2>&1
	wait_core 10 || die "the mihomo core did not start (check the config and 'logread -e mihomo')"
	# a fresh core recreates its tun device, which takes the policy route with it
	if proxy_enabled; then
		sleep 2
		"$FW" check >/dev/null 2>&1
	fi
	log "mihomo core switched on"
	echo "core switched on"
}

case "${1:-}:${2:-}" in
	status:*)
		do_status
		exit 0
		;;
	svc:on|svc:off|proxy:on|proxy:off|core:on|core:off|all:on|all:off) ;;
	*)
		echo "usage: $0 status | svc on|off | proxy on|off | core on|off | all on|off" >&2
		exit 1
		;;
esac

take_lock

case "$1:$2" in
	svc:off)   svc_off ;;
	svc:on)    svc_on ;;
	proxy:off) proxy_off ;;
	proxy:on)  proxy_on ;;
	core:off)  core_off ;;
	core:on)   core_on ;;
	all:off)   proxy_off && core_off ;;
	all:on)    core_on && proxy_on ;;
esac
rc=$?

do_status
exit "$rc"
