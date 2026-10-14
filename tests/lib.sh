# Tiny assertion helpers shared by the shell tests.
PASS=0
FAILN=0

pass() { PASS=$((PASS + 1)); echo "ok - $1"; }
fail() { FAILN=$((FAILN + 1)); echo "not ok - $1"; }

eq() {
	# eq NAME EXPECTED ACTUAL
	if [ "$2" = "$3" ]; then pass "$1"; else fail "$1 (expected '$2', got '$3')"; fi
}

finish() {
	echo "$PASS passed, $FAILN failed"
	[ "$FAILN" -eq 0 ]
}

here() { cd "$(dirname "$1")" && pwd; }
