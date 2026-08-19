#!/bin/sh
# SPDX-License-Identifier: GPL-3.0-or-later
#
# Guarded access to mihomo's config.yaml for the LuCI pages.
#
# The web UI never writes config.yaml directly. It stages content at a single
# fixed path and asks this script to install it, so the only thing the ACL has
# to grant is "write one file in /tmp" plus "run this script" -- rather than
# write access to arbitrary paths on the router.
#
# A config that fails to parse takes mihomo down on the next restart, and a
# router whose proxy will not start is a router with no internet. So nothing
# is installed before `mihomo -t` has accepted it, and the previous version is
# always kept.
#
# Usage: confctl.sh read|validate|apply|backups|restore <name>|diff

. /lib/functions.sh

NAME="clashwrt"
STAGING="/tmp/clashwrt-staging"
MAX_BACKUPS=10

config_load clashwrt
config_get MIHOMO_DIR config mihomo_dir /etc/mihomo

CONF="$MIHOMO_DIR/config.yaml"
BACKUP_DIR="$MIHOMO_DIR/backups"

die() { echo "ERROR: $*" >&2; exit 1; }

# Validate a candidate without ever putting it where mihomo could load it.
# A config references its rule-set files by relative path, so the probe
# directory mirrors the real one by symlink and only config.yaml is replaced.
validate_file() {
	local candidate="$1"
	local probe="/tmp/clashwrt-probe.$$"

	[ -s "$candidate" ] || { echo "candidate is empty" >&2; return 1; }

	rm -rf "$probe"
	mkdir -p "$probe" || return 1

	local entry base
	for entry in "$MIHOMO_DIR"/* "$MIHOMO_DIR"/.[!.]*; do
		[ -e "$entry" ] || continue
		base="$(basename "$entry")"
		[ "$base" = "config.yaml" ] && continue
		ln -sf "$entry" "$probe/$base"
	done
	cp "$candidate" "$probe/config.yaml"

	# mihomo rejects absolute paths that fall outside its working directory
	# unless they are whitelisted, and a real config routinely points at one
	# (external-ui, provider paths). Since the probe directory is not the
	# real home, the real home has to be named explicitly or every valid
	# config would fail validation.
	local out rc
	out="$(SAFE_PATHS="$MIHOMO_DIR" mihomo -t -d "$probe" 2>&1)"
	rc=$?
	rm -rf "$probe"

	if [ $rc -ne 0 ]; then
		# mihomo is chatty on success; only the failure text is useful here
		echo "$out" | grep -viE '^time=.*level=info' | tail -20 >&2
		return 1
	fi
	return 0
}

rotate_backups() {
	mkdir -p "$BACKUP_DIR"
	local n
	n=$(ls -1 "$BACKUP_DIR" 2>/dev/null | grep -c '^config-')
	[ "${n:-0}" -le "$MAX_BACKUPS" ] && return 0
	ls -1 "$BACKUP_DIR" | grep '^config-' | sort | head -n "$((n - MAX_BACKUPS))" \
		| while read -r old; do rm -f "$BACKUP_DIR/$old"; done
}

do_read() {
	[ -f "$CONF" ] || die "no config at $CONF"
	cat "$CONF"
}

do_validate() {
	[ -f "$STAGING" ] || die "nothing staged at $STAGING"
	if validate_file "$STAGING"; then
		echo "OK: configuration is valid"
		return 0
	fi
	die "configuration is not valid"
}

do_apply() {
	[ -f "$STAGING" ] || die "nothing staged at $STAGING"
	validate_file "$STAGING" || die "refusing to install an invalid configuration"

	mkdir -p "$BACKUP_DIR"
	if [ -f "$CONF" ]; then
		# uptime, not wall clock: busybox date is fine but uptime keeps the
		# ordering monotonic even if NTP steps the clock backwards
		local stamp
		stamp="$(cut -d. -f1 /proc/uptime)"
		cp "$CONF" "$BACKUP_DIR/config-$stamp.yaml"
		rotate_backups
	fi

	cat "$STAGING" > "$CONF"
	rm -f "$STAGING"
	echo "installed $CONF"

	if pidof mihomo >/dev/null 2>&1; then
		/etc/init.d/mihomo restart >/dev/null 2>&1
		echo "mihomo restarted"
		# the tun device is recreated by that restart, taking its policy
		# route with it; hotplug normally repairs this, but ask explicitly
		# so the answer is already correct by the time the page refreshes
		sleep 2
		/usr/libexec/clashwrt/fw.sh check >/dev/null 2>&1
	fi
	return 0
}

do_backups() {
	[ -d "$BACKUP_DIR" ] || return 0
	ls -1 "$BACKUP_DIR" 2>/dev/null | grep '^config-' | sort -r
}

do_restore() {
	local which="$1"
	[ -n "$which" ] || die "which backup?"
	case "$which" in
		*/*|..*) die "invalid backup name" ;;
	esac
	local src="$BACKUP_DIR/$which"
	[ -f "$src" ] || die "no such backup: $which"
	cp "$src" "$STAGING"
	do_apply
}

case "${1:-}" in
	read)     do_read ;;
	validate) do_validate ;;
	apply)    do_apply ;;
	backups)  do_backups ;;
	restore)  do_restore "${2:-}" ;;
	*) echo "usage: $0 read|validate|apply|backups|restore <name>" >&2; exit 1 ;;
esac
