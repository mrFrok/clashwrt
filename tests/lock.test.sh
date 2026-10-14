#!/bin/sh
# lock.sh: mutual exclusion, bounded wait, stale-owner takeover, and no lost
# update when many callers race for the same stale lock.
T="$(cd "$(dirname "$0")" && pwd)"
. "$T/lib.sh"
LIB="$T/../clashwrt/files/usr/libexec/clashwrt"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

# a pid that is certainly dead
sh -c 'exit 0' & DEAD=$!
wait "$DEAD"

# runs one locked section in a fresh shell: $1 = lock path, $2 = wait, $3 = body
locked() {
	CLASHWRT_LOCK_WAIT="$2" sh -c '
		die() { echo "DIE: $*"; exit 1; }
		. "$1/lock.sh"
		cw_lock "$2" 30 test
		eval "$3"
	' sh "$LIB" "$1" "$3"
}

L="$TMP/a.lock"

out="$(locked "$L" 2 'echo got')"
eq "acquires and runs" "got" "$out"
[ ! -e "$L.d" ] && pass "released on exit" || fail "lock dir left behind"

# released when the owner is killed by a signal
sh -c '. "$1/lock.sh"; die() { exit 1; }; cw_lock "$2" 30 test; sleep 30' sh "$LIB" "$L" &
HOLDER=$!
sleep 1
[ -d "$L.d" ] && pass "held while the owner lives" || fail "not held"
out="$(locked "$L" 1 'echo got')"
case "$out" in "DIE: busy:"*) pass "bounded wait fails with a message" ;; *) fail "wait: '$out'" ;; esac
kill "$HOLDER"; wait "$HOLDER" 2>/dev/null
sleep 1
out="$(locked "$L" 2 'echo got')"
eq "free after the owner was killed" "got" "$out"

# stale owner left by a dead process
rm -rf "$L.d"; mkdir "$L.d"; : > "$L.d/own.$DEAD"
out="$(locked "$L" 2 'echo got')"
eq "takes over a dead owner's lock" "got" "$out"

# empty lock dir (owner died before naming itself) is cleared after a few seconds
rm -rf "$L.d"; mkdir "$L.d"
out="$(locked "$L" 20 'echo got')"
eq "clears a nameless lock" "got" "$out"

# a live owner's lock must survive any number of stale-looking observers
rm -rf "$L.d"; mkdir "$L.d"; : > "$L.d/own.$DEAD"
echo 0 > "$TMP/counter"
for n in 1 2 3 4 5 6 7 8 9 10 11 12; do
	locked "$L" 30 '
		v="$(cat '"$TMP"'/counter)"
		sleep 0.05
		echo $((v + 1)) > '"$TMP"'/counter
	' >/dev/null &
done
wait
eq "12 racers over a stale lock lose no update" "12" "$(cat "$TMP/counter")"
[ ! -e "$L.d" ] && pass "no lock left after the race" || fail "lock left after the race"

finish
