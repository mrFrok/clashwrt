#!/bin/sh
# Runs every test and the static checks. Needs node and a POSIX sh; shellcheck
# and eslint are used when installed (npm i -g eslint@8, pip install shellcheck-py).
cd "$(dirname "$0")" || exit 1
rc=0

for t in *.test.js; do
	echo "== $t"
	node "$t" || rc=1
done
for t in *.test.sh; do
	echo "== $t"
	sh "$t" || rc=1
done
echo "== lint.sh"
sh ./lint.sh || rc=1

[ "$rc" -eq 0 ] && echo "ALL OK" || echo "FAILED"
exit "$rc"
