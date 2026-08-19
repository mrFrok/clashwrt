#!/bin/sh
# SPDX-License-Identifier: GPL-3.0-or-later
#
# Removes clashwrt and, unless told otherwise, the mihomo core it installed.
#
#   wget -qO- https://raw.githubusercontent.com/mrFrok/clashwrt/main/uninstall.sh | sh
#
# Order matters here. The firewall rules and policy routes come down first,
# because removing the files that know how to tear them down would strand a
# ruleset that silently keeps intercepting traffic until the next reboot.
#
# Environment:
#   KEEP_CORE=1     leave /usr/bin/mihomo in place
#   KEEP_CONFIG=1   leave /etc/mihomo and /etc/config/clashwrt in place
#   ASSUME_YES=1    do not ask

# Deliberately no `set -e`. Aborting an uninstall partway is worse than either
# finishing or not starting: it leaves the firewall rules up with the scripts
# that remove them already gone. Every step here is independently safe to fail,
# so each one is allowed to.

MIHOMO_DIR="$(uci -q get clashwrt.config.mihomo_dir 2>/dev/null || echo /etc/mihomo)"

say()  { echo "==> $*"; }
warn() { echo "[!] $*" >&2; }

[ "$(id -u)" = "0" ] || { echo "run this as root" >&2; exit 1; }

if [ "${ASSUME_YES:-0}" != "1" ]; then
	printf 'Remove clashwrt'
	[ "${KEEP_CORE:-0}" = "1" ]   || printf ', the mihomo core'
	[ "${KEEP_CONFIG:-0}" = "1" ] || printf ", and %s" "$MIHOMO_DIR"
	printf '? [y/N] '
	read -r ans
	case "$ans" in y|Y|yes|YES) ;; *) echo "aborted"; exit 0 ;; esac
fi

# --------------------------------------------------------------------------
# stop intercepting first
# --------------------------------------------------------------------------

say "tearing down firewall rules and policy routing"
if [ -x /usr/libexec/clashwrt/fw.sh ]; then
	/usr/libexec/clashwrt/fw.sh flush >/dev/null 2>&1 || true
else
	nft delete table inet clashwrt 2>/dev/null || true
fi

/etc/init.d/clashwrt stop    >/dev/null 2>&1 || true
/etc/init.d/clashwrt disable >/dev/null 2>&1 || true

# --------------------------------------------------------------------------
# fw4 zone
# --------------------------------------------------------------------------
# Left behind, this points at a device that will never exist again, and fw4
# complains on every reload.

say "removing the fw4 zone"
TUN_DEV="$(uci -q get clashwrt.config.tun_device 2>/dev/null || echo clash-tun)"
ZONE_NAME=""
removed=0

# Deleting by index shifts every later index down, so the slot is re-examined
# rather than advanced past after a delete.
i=0
while uci -q get "firewall.@zone[$i]" >/dev/null 2>&1; do
	name="$(uci -q get "firewall.@zone[$i].name" 2>/dev/null)"
	devs="$(uci -q get "firewall.@zone[$i].device" 2>/dev/null)"

	match=0
	case " $devs " in
		*" $TUN_DEV "*) match=1 ;;
	esac
	if [ "$name" = "mihomo" ] || [ "$name" = "clashwrt" ]; then
		match=1
	fi

	if [ "$match" = "1" ]; then
		[ -n "$name" ] && ZONE_NAME="$name"
		uci -q delete "firewall.@zone[$i]"
		removed=1
	else
		i=$((i + 1))
	fi
done

# Forwardings that referenced the zone would otherwise point at a name that no
# longer resolves, which fw4 complains about on every reload.
i=0
while uci -q get "firewall.@forwarding[$i]" >/dev/null 2>&1; do
	src="$(uci -q get "firewall.@forwarding[$i].src" 2>/dev/null)"
	dst="$(uci -q get "firewall.@forwarding[$i].dest" 2>/dev/null)"

	match=0
	for n in mihomo clashwrt $ZONE_NAME; do
		if [ "$src" = "$n" ] || [ "$dst" = "$n" ]; then
			match=1
		fi
	done

	if [ "$match" = "1" ]; then
		uci -q delete "firewall.@forwarding[$i]"
		removed=1
	else
		i=$((i + 1))
	fi
done

if [ "$removed" = "1" ]; then
	uci -q commit firewall
	/etc/init.d/firewall reload >/dev/null 2>&1 || true
fi

# --------------------------------------------------------------------------
# files
# --------------------------------------------------------------------------

say "removing package files"
rm -rf /usr/libexec/clashwrt
rm -f  /etc/init.d/clashwrt
rm -f  /etc/hotplug.d/net/30-clashwrt
rm -f  /etc/sysctl.d/99-clashwrt.conf
rm -f  /etc/uci-defaults/99-clashwrt

rm -rf /www/luci-static/resources/view/clashwrt
rm -rf /www/luci-static/resources/clashwrt
rm -f  /usr/share/luci/menu.d/luci-app-clashwrt.json
rm -f  /usr/share/rpcd/acl.d/luci-app-clashwrt.json
rm -f  /usr/lib/lua/luci/i18n/clashwrt.*.lmo

rm -f /tmp/clashwrt-staging

# --------------------------------------------------------------------------
# core and configuration
# --------------------------------------------------------------------------

if [ "${KEEP_CORE:-0}" != "1" ]; then
	say "removing the mihomo core"
	/etc/init.d/mihomo stop    >/dev/null 2>&1 || true
	/etc/init.d/mihomo disable >/dev/null 2>&1 || true
	rm -f /etc/init.d/mihomo
	rm -f /usr/bin/mihomo
else
	say "keeping the mihomo core"
fi

if [ "${KEEP_CONFIG:-0}" != "1" ]; then
	say "removing $MIHOMO_DIR and /etc/config/clashwrt"
	rm -rf "$MIHOMO_DIR"
	rm -f /etc/config/clashwrt
else
	say "keeping $MIHOMO_DIR and /etc/config/clashwrt"
fi

rm -f /tmp/luci-indexcache* 2>/dev/null || true
/etc/init.d/rpcd restart >/dev/null 2>&1 || true

say "done"
echo
echo "Traffic is no longer intercepted. Verify with:  nft list ruleset | grep clashwrt"
