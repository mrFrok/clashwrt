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
# Usage: confctl.sh read|validate|apply|backups|restore <name>|delete-backup <name>|rename-backup <old> <new>

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
	local candidate="$1" probe

	[ -s "$candidate" ] || { echo "candidate is empty" >&2; return 1; }

	# a fresh directory of its own: a name in /tmp that is merely likely to
	# be unused is one somebody else can create first
	probe="$(mktemp -d /tmp/clashwrt-probe.XXXXXX)" || return 1

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
		echo "$out" | clean_validation_error >&2
		return 1
	fi
	return 0
}

# mihomo reports a rejected config as a logfmt line -- a timestamp, a level and
# the real message buried in msg="..." -- followed by a line naming the file it
# tested. Neither shape is worth showing.
#
# The timestamp and level are noise on a one-shot syntax check. The filename is
# worse than noise: it names the probe directory, a temporary copy that this
# function has already deleted by the time anyone reads the message, so it
# sends the reader looking for a file that never existed and was never theirs.
# What locates the mistake is the line number inside msg, and that is what is
# left.
#
# Anything that does not match the expected shape is passed through untouched
# rather than dropped -- a message nobody anticipated is exactly the one worth
# seeing in full.
clean_validation_error() {
	awk '
		/level=(error|fatal)/ {
			if (match($0, /msg="/)) {
				m = substr($0, RSTART + RLENGTH)
				sub(/"[[:space:]]*$/, "", m)
				print m
				seen = 1
				next
			}
		}
		# names the probe copy, which is gone by now
		/test failed$/ { next }
		/^time=.*level=info/ { next }
		{ rest = rest $0 "\n" }
		END { if (!seen) printf "%s", rest }
	' | head -20
}

# Backups made by hand before this package existed, and by earlier versions of
# it, sit next to config.yaml rather than in the rotated directory, so nothing
# ever removes them. Once a new configuration has been installed and accepted,
# they are strictly older than a verified backup and can go. The pattern is
# deliberately narrow -- our own naming, in the mihomo directory, never
# config.yaml itself.
prune_legacy_backups() {
	local f n=0 bytes=0
	for f in "$MIHOMO_DIR"/config.yaml.bak-*; do
		[ -f "$f" ] || continue
		bytes=$((bytes + $(wc -c < "$f" 2>/dev/null || echo 0)))
		rm -f "$f" && n=$((n + 1))
	done
	[ "$n" -gt 0 ] && echo "removed $n stray backup(s), $bytes bytes"
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

# The staged file is moved out of /tmp before anything looks at it: what is
# validated is then exactly what gets installed, and nobody can swap or
# relink the file in between. A symlink or anything but a plain file is not
# a staged config.
take_staged() {
	local f
	[ -f "$STAGING" ] && [ ! -L "$STAGING" ] || { echo "nothing staged at $STAGING" >&2; return 1; }
	f="$(mktemp /tmp/clashwrt-staged.XXXXXX)" || return 1
	mv -f "$STAGING" "$f" || { rm -f "$f"; return 1; }
	echo "$f"
}

do_validate() {
	[ -f "$STAGING" ] && [ ! -L "$STAGING" ] || die "nothing staged at $STAGING"
	if validate_file "$STAGING"; then
		echo "OK: configuration is valid"
		return 0
	fi
	die "configuration is not valid"
}

do_apply() {
	# global, not local: the EXIT trap runs after this function has returned
	STAGED="$(take_staged)" || exit 1
	trap 'rm -f "$STAGED"' EXIT
	validate_file "$STAGED" || die "refusing to install an invalid configuration"

	mkdir -p "$BACKUP_DIR"
	if [ -f "$CONF" ]; then
		# uptime, not wall clock: busybox date is fine but uptime keeps the
		# ordering monotonic even if NTP steps the clock backwards
		local stamp
		stamp="$(cut -d. -f1 /proc/uptime)"
		cp "$CONF" "$BACKUP_DIR/config-$stamp.yaml"
		rotate_backups
	fi

	cat "$STAGED" > "$CONF"
	echo "installed $CONF"

	# only now, with a good config in place and a fresh backup beside it
	prune_legacy_backups

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
	# the same rule as rename and delete, rather than a looser one of its own
	valid_backup_name "$which" || die "invalid backup name"
	local src="$BACKUP_DIR/$which"
	[ -f "$src" ] && [ ! -L "$src" ] || die "no such backup: $which"
	# staged through a new file of its own rather than the shared name in /tmp
	rm -f "$STAGING"
	cp "$src" "$STAGING.$$" && mv -f "$STAGING.$$" "$STAGING" || die "could not stage $which"
	do_apply
}

# Names that rename/delete will touch. A bare file name of the shape the
# backup rotation itself produces (config-*.yaml), from a closed character set:
# no slash, so no path can be smuggled in, and nothing that could be read as an
# option or a hidden file. Anything else is refused before the filesystem is
# looked at.
valid_backup_name() {
	case "$1" in
		*[!A-Za-z0-9._-]*) return 1 ;;
		config-?*.yaml) ;;
		*) return 1 ;;
	esac
	[ "${#1}" -le 100 ]
}

do_delete_backup() {
	local name="$1"
	valid_backup_name "$name" || die "invalid backup name"
	local src="$BACKUP_DIR/$name"
	[ -f "$src" ] && [ ! -L "$src" ] || die "no such backup: $name"
	rm -f "$src" || die "could not delete $name"
	echo "deleted $name"
}

do_rename_backup() {
	local old="$1" new="$2"
	valid_backup_name "$old" || die "invalid backup name"
	valid_backup_name "$new" || die "invalid new name (use config-<anything>.yaml, letters, digits, . _ -)"
	[ "$old" != "$new" ] || die "the new name is the same as the old one"
	local src="$BACKUP_DIR/$old" dst="$BACKUP_DIR/$new"
	[ -f "$src" ] && [ ! -L "$src" ] || die "no such backup: $old"
	[ ! -e "$dst" ] && [ ! -L "$dst" ] || die "a backup named $new already exists"
	mv "$src" "$dst" || die "could not rename $old"
	echo "renamed $old -> $new"
}

case "${1:-}" in
	read)     do_read ;;
	validate) do_validate ;;
	apply)    do_apply ;;
	backups)  do_backups ;;
	restore)  do_restore "${2:-}" ;;
	delete-backup) do_delete_backup "${2:-}" ;;
	rename-backup) do_rename_backup "${2:-}" "${3:-}" ;;
	*) echo "usage: $0 read|validate|apply|backups|restore <name>|delete-backup <name>|rename-backup <old> <new>" >&2; exit 1 ;;
esac
