#!/bin/sh
# SPDX-License-Identifier: GPL-3.0-or-later
#
# System-log access for the Logs page.
#
# mihomo's own traffic log is read straight from its API by the browser (the
# controller sends Access-Control-Allow-Origin: *, so a cross-origin stream
# works and no server-side collector is needed). What the API cannot show is
# everything *around* mihomo -- the firewall engine, hotplug, procd restarting
# the daemon -- which is exactly what you need when traffic is not being
# proxied at all. That comes from here.
#
# Two things about reading the system log on OpenWrt are not obvious:
#
#   * `logread` only reads logd's circular buffer. If rsyslog or syslog-ng is
#     installed it takes over /dev/log, and from then on `logger` output never
#     reaches that buffer at all -- so `logread` looks empty while the log is
#     perfectly healthy in /var/log/messages. Observed on a real router: our
#     own entries were invisible to logread and present in the file.
#
#   * `logread -e` does not understand alternation. `-e 'a|b'` matches nothing
#     even when both `a` and `b` match on their own, so filtering has to go
#     through grep -E instead.
#
# Usage: logctl.sh syslog [lines] | all [lines] | kernel [lines] | where

DEFAULT_LINES=200
MAX_LINES=2000

# Anything with a hand in proxying: our own tag, the daemon, the firewall that
# steers traffic into it, and netifd/hotplug bringing the tun up.
PATTERN='clashwrt|mihomo|fw4|firewall|nftables|hotplug|netifd|kernel: .*clash'

clamp_lines() {
	case "$1" in
		''|*[!0-9]*) echo "$DEFAULT_LINES" ;;
		*) [ "$1" -gt "$MAX_LINES" ] && echo "$MAX_LINES" || echo "$1" ;;
	esac
}

# A file written by a full syslog daemon wins over logd's buffer, because when
# both exist the daemon is the one actually receiving messages.
log_source() {
	for f in /var/log/messages /var/log/syslog; do
		[ -s "$f" ] && { echo "file:$f"; return 0; }
	done
	echo "logread"
}

emit() {
	src="$(log_source)"
	case "$src" in
		file:*) cat "${src#file:}" 2>/dev/null ;;
		*)      logread 2>/dev/null ;;
	esac
}

case "${1:-syslog}" in
	syslog)
		n="$(clamp_lines "${2:-}")"
		emit | grep -E "$PATTERN" | tail -n "$n"
		;;
	all)
		n="$(clamp_lines "${2:-}")"
		emit | tail -n "$n"
		;;
	kernel)
		n="$(clamp_lines "${2:-}")"
		dmesg 2>/dev/null | tail -n "$n"
		;;
	where)
		log_source
		;;
	*)
		echo "usage: $0 syslog [lines] | all [lines] | kernel [lines] | where" >&2
		exit 1
		;;
esac
