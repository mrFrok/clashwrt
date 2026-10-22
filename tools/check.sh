#!/bin/sh
# SPDX-License-Identifier: GPL-3.0-or-later
#
# Everything CI checks, runnable as is on a workstation. Needs shellcheck,
# node, python3 and msgfmt (gettext).
#
# Usage: tools/check.sh [tag]
#   tag  a release tag such as v1.0.4; when given, both packages must carry
#        that version.

cd "$(dirname "$0")/.." || exit 1

FAILED=0
fail() { echo "FAIL: $*" >&2; FAILED=1; }
step() { echo "== $*"; }

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

step "shell syntax and shellcheck"
# The hotplug script has no shebang (hotplug sources it), so the list is
# explicit rather than found by shebang.
SCRIPTS="install.sh uninstall.sh
clashwrt/files/etc/init.d/clashwrt
clashwrt/files/etc/hotplug.d/net/30-clashwrt
clashwrt/files/etc/uci-defaults/99-clashwrt
$(ls clashwrt/files/usr/libexec/clashwrt/*.sh)
tools/check.sh"
for f in $SCRIPTS; do
	sh -n "$f" || fail "syntax: $f"
done
# shellcheck disable=SC2086
shellcheck -S warning $SCRIPTS || fail "shellcheck"

step "JavaScript syntax"
# LuCI modules end in a top-level 'return', which is only legal inside a
# function, so each file is checked wrapped in one.
for f in luci-app-clashwrt/htdocs/luci-static/resources/clashwrt/*.js \
		luci-app-clashwrt/htdocs/luci-static/resources/view/clashwrt/*.js; do
	{ echo '(function () {'; cat "$f"; echo '})'; } > "$TMP/check.js"
	node --check "$TMP/check.js" 2>"$TMP/err" || { cat "$TMP/err" >&2; fail "js: $f"; }
done

step "JSON"
for f in luci-app-clashwrt/root/usr/share/*/*.d/*.json; do
	python3 -m json.tool "$f" >/dev/null || fail "json: $f"
done

step "translations"
for po in luci-app-clashwrt/po/*/clashwrt.po; do
	msgfmt --check -o /dev/null "$po" || fail "msgfmt: $po"
	lang="$(basename "$(dirname "$po")")"
	lmo="$(dirname "$po")/clashwrt.$lang.lmo"
	python3 -I tools/po2lmo.py "$po" "$TMP/out.lmo" >/dev/null || { fail "po2lmo: $po"; continue; }
	cmp -s "$TMP/out.lmo" "$lmo" ||
		fail "$lmo is stale; run: tools/po2lmo.py $po $lmo"
done

step "versions"
ver() { sed -n 's/^PKG_VERSION:=//p' "$1"; }
v1="$(ver clashwrt/Makefile)"
v2="$(ver luci-app-clashwrt/Makefile)"
[ -n "$v1" ] && [ "$v1" = "$v2" ] ||
	fail "package versions differ: clashwrt $v1, luci-app-clashwrt $v2"
# the "ui x.y.z" each page shows is the package version, so a stale page
# cached by the browser can be told apart at a glance
for f in $(grep -rl "UI_VERSION = " luci-app-clashwrt/htdocs); do
	grep -q "UI_VERSION = '$v1';" "$f" || fail "$f: UI_VERSION is not $v1"
done
if [ -n "${1:-}" ] && [ "$1" != "v$v1" ]; then
	fail "tag $1 does not match package version $v1"
fi

[ "$FAILED" = 0 ] && echo "all checks passed"
exit "$FAILED"
