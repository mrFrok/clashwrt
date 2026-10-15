#!/bin/sh
# SPDX-License-Identifier: GPL-3.0-or-later
#
# The lock code used by fw.sh and powerctl.sh, each with its own lock file
# (powerctl holds its lock while it runs fw.sh). Sourced, not run.
#
#   cw_lock LOCKFILE DEFAULT_WAIT WHAT
#
# The lock is the directory LOCKFILE.d, taken with mkdir. Its owner is the
# empty file LOCKFILE.d/own.<pid>, so the owner is in the *name*: a caller that
# finds the owner dead removes that one file with rm, which is atomic, so of
# several callers that see the same dead owner exactly one wins. Only the
# winner may rmdir the directory, and rmdir only succeeds on an empty one. A
# caller that lost the race, or looked at an old owner after somebody else had
# already taken the lock over, can therefore never remove a live lock -- which
# is what 'rm -rf' of a directory chosen by an earlier look could do.
# (flock and lock(1) are not used: both can outlive a killed holder through a
# child process.)
#
# The wait is bounded (CLASHWRT_LOCK_WAIT seconds, else DEFAULT_WAIT) and a
# caller that cannot get the lock fails through die(), which the caller must
# define. The lock goes with its owner on exit or on HUP/INT/TERM.

cw_unlock() {
	[ -n "${CW_LOCKDIR:-}" ] || return 0
	rm -f "$CW_LOCKDIR/own.$$"
	rmdir "$CW_LOCKDIR" 2>/dev/null
	return 0
}

cw_lock() {
	local base="$1" wait_s="${CLASHWRT_LOCK_WAIT:-$2}" what="$3" i=0 f pid
	case "$wait_s" in ''|*[!0-9]*) wait_s="$2" ;; esac
	mkdir -p "${base%/*}" 2>/dev/null

	CW_LOCKDIR="$base.d"
	while ! mkdir "$CW_LOCKDIR" 2>/dev/null; do
		pid=""
		for f in "$CW_LOCKDIR"/own.*; do
			[ -e "$f" ] && pid="${f##*.}"
		done
		case "$pid" in
		*[!0-9]*) pid="" ;;
		esac

		if [ -n "$pid" ]; then
			if ! kill -0 "$pid" 2>/dev/null; then
				rm "$CW_LOCKDIR/own.$pid" 2>/dev/null && rmdir "$CW_LOCKDIR" 2>/dev/null
				continue
			fi
		elif [ "$i" -ge 5 ]; then
			# created, but the owner died before naming itself
			rmdir "$CW_LOCKDIR" 2>/dev/null
			i=0
			continue
		fi

		[ "$i" -lt "$wait_s" ] || die "busy: another clashwrt $what operation held the lock for ${wait_s}s"
		sleep 1
		i=$((i + 1))
	done
	: > "$CW_LOCKDIR/own.$$"
	trap cw_unlock EXIT
	trap 'exit 1' HUP INT TERM
}
