#!/bin/sh
# SPDX-License-Identifier: GPL-3.0-or-later
#
# Rule and proxy providers in RAM, when the RAM can take them.
#
# mihomo rewrites its providers on every refresh -- tens of MB a day with lists
# like Re-filter -- and on a NAND router each rewrite is wear. Kept in /tmp
# (RAM) they cost no writes at all. But RAM is the scarcer thing on most
# routers, and a full /tmp breaks far more than a worn flash, so they move
# only when there is clearly room, and move back as soon as there is not.
#
# Layout, per directory a provider path names (./providers, ./re-filter...):
#   on flash:  $MIHOMO_DIR/<d>            a real directory, as without this
#   in RAM:    $MIHOMO_DIR/<d> -> $RAM/<d> a symlink, and the files as of the
#              move in $MIHOMO_DIR/.clashwrt-flash/<d>: what comes back after
#              a reboot, so nothing has to be downloaded again
#
# Room, measured on every 'place' (service start, config apply, daily run):
# RAM is used only if, with the providers twice over (a refresh writes the new
# file beside the old), MemAvailable stays at least max(32 MB, 15 % of RAM)
# and /tmp keeps a quarter of itself free. Routers under 256 MB never move.
#
# Usage: provctl.sh place | status

# shellcheck source=/dev/null
. "${CLASHWRT_FUNCTIONS:-/lib/functions.sh}"

NAME="clashwrt"
RAM="${CLASHWRT_PROV_RAM:-/tmp/clashwrt-prov}"
MEMINFO="${CLASHWRT_MEMINFO:-/proc/meminfo}"
MIN_RAM_KB=262144

log() { logger -t "$NAME" "providers: $*"; return 0; }

load_cfg() {
	config_load "$NAME"
	config_get enabled    config providers_in_ram 1
	config_get mihomo_dir config mihomo_dir       /etc/mihomo
	CONF="$mihomo_dir/config.yaml"
	FLASH="$mihomo_dir/.clashwrt-flash"
}

meminfo() { awk -v k="$1:" '$1 == k { print $2; f = 1 } END { if (!f) print 0 }' "$MEMINFO" 2>/dev/null; }

# free and total KB of the filesystem holding $1
df_kb() {
	df -k "$1" 2>/dev/null | awk -v w="$2" 'END { for (i = 1; i <= NF; i++) if ($i ~ /%$/) { print (w == "free" ? $(i-1) : $(i-3)); exit } }'
}

# The directories the config's providers live in: the first part of every
# relative 'path:' under rule-providers or proxy-providers.
provider_dirs() {
	[ -f "$CONF" ] || return 0
	awk '
		/^[A-Za-z0-9_-]+:/ { s = ($0 ~ /^(rule|proxy)-providers:/) ; next }
		s && /path:/ {
			p = $0; sub(/.*path:[ \t]*/, "", p); sub(/[ \t,}#].*/, "", p)
			gsub(/["\047]/, "", p); sub(/^\.\//, "", p)
			if (p ~ /^\// || p ~ /\.\./ || p !~ /\//) next
			sub(/\/.*/, "", p)
			if (p ~ /^[A-Za-z0-9._-]+$/ && p !~ /^\./) print p
		}
	' "$CONF" | awk '!seen[$0]++'
}

size_kb() {
	local t=0 d s
	for d in "$@"; do
		s="$(du -skL "$mihomo_dir/$d" 2>/dev/null | cut -f1)"
		t=$((t + ${s:-0}))
	done
	echo "$t"
}

# Why RAM cannot take $1 KB more, or nothing when it can.
no_room() {
	local need=$(( $1 + 1024 )) total avail floor tfree tsize
	total="$(meminfo MemTotal)"
	avail="$(meminfo MemAvailable)"
	[ "$total" -ge "$MIN_RAM_KB" ] || { echo "the router has under 256 MB of RAM"; return 0; }
	floor=$((total * 15 / 100)); [ "$floor" -ge 32768 ] || floor=32768
	[ $((avail - need)) -ge "$floor" ] || { echo "too little free RAM (${avail} KB free, ${need} KB needed)"; return 0; }
	mkdir -p "$RAM" 2>/dev/null
	tfree="$(df_kb "$RAM" free)"; tsize="$(df_kb "$RAM" size)"
	case "$tfree$tsize" in ''|*[!0-9]*) echo "cannot measure /tmp"; return 0 ;; esac
	[ $((tfree - need)) -ge $((tsize / 4)) ] || { echo "/tmp is nearly full"; return 0; }
	return 1
}

in_ram() { [ -L "$mihomo_dir/$1" ]; }

# Copy first, switch second, delete last: at no point is a provider file
# missing, only briefly reached through the old place.
to_ram() {
	local d="$1"
	mkdir -p "$RAM/$d" "$FLASH" || return 1
	if [ -d "$mihomo_dir/$d" ] && [ ! -L "$mihomo_dir/$d" ]; then
		cp -a "$mihomo_dir/$d/." "$RAM/$d/" || { rm -rf "${RAM:?}/${d:?}"; return 1; }
		rm -rf "${FLASH:?}/${d:?}"
		mv "$mihomo_dir/$d" "$FLASH/$d" || return 1
	elif [ -d "$FLASH/$d" ]; then
		# after a reboot: the link is there, RAM is empty
		cp -a "$FLASH/$d/." "$RAM/$d/" || return 1
	fi
	ln -sfn "$RAM/$d" "$mihomo_dir/$d"
}

to_flash() {
	local d="$1"
	mkdir -p "$FLASH/$d"
	# the RAM copy is the newer one, when there is one
	[ -d "$RAM/$d" ] && cp -a "$RAM/$d/." "$FLASH/$d/"
	rm -f "$mihomo_dir/$d"
	mv "$FLASH/$d" "$mihomo_dir/$d" || return 1
	rm -rf "${RAM:?}/${d:?}"
}

do_place() {
	local dirs d why kb
	load_cfg
	dirs="$(provider_dirs)"
	[ -n "$dirs" ] || return 0

	if [ "$enabled" != 1 ]; then
		why="turned off"
	else
		# What RAM still has to find: twice what is on flash (the move, and
		# a refresh writing a new file beside the old), and once more what
		# is already in RAM (the same refresh); what sits there is already
		# out of MemAvailable and is not counted twice.
		local onflash="" inram=""
		for d in $dirs; do
			if in_ram "$d" && [ -d "$RAM/$d" ]; then inram="$inram $d"; else onflash="$onflash $d"; fi
		done
		kb=$(( $(size_kb $onflash) * 2 + $(size_kb $inram) ))
		why="$(no_room "$kb")"
	fi

	for d in $dirs; do
		if [ -z "$why" ]; then
			# a link whose RAM side is gone (reboot) is refilled too
			if ! in_ram "$d" || [ ! -d "$RAM/$d" ]; then
				to_ram "$d" && log "$d in RAM"
			fi
		elif in_ram "$d"; then
			to_flash "$d" && log "$d back on flash: $why"
		fi
	done
	echo "${why:-ok}" > "$RAM.why" 2>/dev/null
	return 0
}

do_status() {
	local dirs d ram="" flash=""
	load_cfg
	dirs="$(provider_dirs)"
	for d in $dirs; do
		if in_ram "$d"; then ram="$ram $d"; else flash="$flash $d"; fi
	done
	if [ -n "$ram" ]; then
		echo "providers: ram $(size_kb $ram) KB:$ram"
	elif [ -n "$dirs" ]; then
		echo "providers: flash: $(cat "$RAM.why" 2>/dev/null || echo "not placed yet")"
	else
		echo "providers: none"
	fi
}

case "${1:-}" in
	place)  do_place ;;
	status) do_status ;;
	*) echo "usage: $0 place | status" >&2; exit 1 ;;
esac
