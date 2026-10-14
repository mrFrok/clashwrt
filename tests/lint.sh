#!/bin/sh
# Static checks: sh -n, shellcheck, node --check, eslint (ES5 for shipped LuCI JS).
cd "$(dirname "$0")/.." || exit 1
rc=0

SH_FILES="$(ls clashwrt/files/usr/libexec/clashwrt/*.sh clashwrt/files/etc/init.d/clashwrt \
	clashwrt/files/etc/hotplug.d/net/30-clashwrt clashwrt/files/etc/uci-defaults/99-clashwrt \
	install.sh uninstall.sh tools/*.sh tests/*.sh 2>/dev/null)"
JS_FILES="$(find luci-app-clashwrt/htdocs tests -name '*.js')"
UI_FILES="$(find luci-app-clashwrt/htdocs -name '*.js')"

for f in $SH_FILES; do
	sh -n "$f" || { echo "sh -n failed: $f"; rc=1; }
done
echo "sh -n: done"

if command -v shellcheck >/dev/null 2>&1; then
	# local (busybox ash has it), echo -n and the unquoted table name in fw.sh are
	# deliberate on OpenWrt; SC2154 is variables set by config_get.
	# shellcheck disable=SC2086
	shellcheck -s sh -x -S warning \
		-e SC3043,SC3037,SC1091,SC2154,SC2034,SC2086,SC2010,SC1083 \
		$SH_FILES || rc=1
	echo "shellcheck: done"
else
	echo "shellcheck: not installed, skipped"
fi

# shellcheck disable=SC2086
for f in $JS_FILES; do
	node --check "$f" 2>/dev/null || {
		# LuCI modules end in a top-level 'return'; check them as function bodies
		node -e 'new Function(require("fs").readFileSync(process.argv[1], "utf8"))' "$f" || { echo "node --check failed: $f"; rc=1; }
	}
done
echo "node --check: done"

if command -v eslint >/dev/null 2>&1; then
	# shellcheck disable=SC2086
	eslint --no-eslintrc -c tests/eslintrc.json $UI_FILES || rc=1
	echo "eslint (ES5): done"
else
	echo "eslint: not installed, skipped"
fi
exit "$rc"
