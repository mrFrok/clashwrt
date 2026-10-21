#!/bin/sh
# SPDX-License-Identifier: GPL-3.0-or-later
#
# One-shot installer for clashwrt on OpenWrt.
#
#   wget -qO- https://raw.githubusercontent.com/mrFrok/clashwrt/main/install.sh | sh
#
# Installs the mihomo core, this package, its LuCI pages and a web dashboard,
# then leaves everything disabled so nothing changes on the network until the
# setup wizard has been through once. Re-running it upgrades in place and
# keeps /etc/config/clashwrt and /etc/mihomo/config.yaml.
#
# It asks what it needs on the terminal -- release or development channel,
# where to keep the core (on flash, packed on flash, or only in RAM), which
# dashboard, whether to swap in dnsmasq-full -- each with a recommendation
# worked out from this router's free flash and RAM; Enter takes it. With no
# terminal (the Update button in LuCI runs it detached) nothing is asked and
# what was chosen before is kept.

set -e

SLUG="${SLUG:-mrFrok/clashwrt}"

# The updater of 1.3.x and later passes these; they are not for hand use.
# REPO_URL names the source tarball, SKIP_CORE=1 leaves the core alone.
REPO_URL="${REPO_URL:-}"
SKIP_CORE="${SKIP_CORE:-0}"
SRC_TAG=""

# An upgrade (or the Update button, which runs this) already has a mihomo to
# fetch through: the proxy first, then directly, as everything else here
# fetches (net.sh). A first install has neither, and fetches directly.
if [ -f /usr/libexec/clashwrt/net.sh ]; then
	. /usr/libexec/clashwrt/net.sh
else
	cw_curl() { curl "$@"; }
fi
# The same as net.sh's, for a first install that does not have it yet.
command -v asset_digest >/dev/null 2>&1 || asset_digest() {
	cw_curl -sSL --fail --proto '=https' -m 30 \
		"https://api.github.com/repos/$1/releases/tags/$2" 2>/dev/null |
		awk -v want="$3" '
			/^[ \t]*"name":/ { n = $0; sub(/^[^:]*:[ \t]*"/, "", n); sub(/".*/, "", n) }
			/^[ \t]*"digest":[ \t]*"sha256:[0-9a-f]{64}"/ && n == want {
				d = $0; sub(/.*"sha256:/, "", d); sub(/".*/, "", d); print d; exit
			}'
}

MIHOMO_DIR="${MIHOMO_DIR:-/etc/mihomo}"

say()  { echo "==> $*"; }
warn() { echo "[!] $*" >&2; }
die()  { echo "[x] $*" >&2; exit 1; }

# Free kilobytes on the filesystem holding $1 (see updctl.sh avail_kb: the
# Available column is found next to the "%" one, since long device names wrap).
avail_kb() {
	_a="$(df -k "$1" 2>/dev/null |
		awk 'END { for (i = 1; i <= NF; i++) if ($i ~ /%$/) { print $(i-1); exit } }')"
	case "$_a" in ''|*[!0-9]*) echo 0 ;; *) echo "$_a" ;; esac
}

# The source tarball and its unpacked tree take about 1 MB; 4 MB leaves room
# for the tree to grow. /tmp is RAM and nearly always has that, but a router
# with little RAM and a busy core may not -- then any writable mount will do,
# the overlay last since it is the scarcest thing on the box.
NEED_TMP_KB=4096
TMP=""
for _d in /tmp $(awk '$4 ~ /(^|,)rw(,|$)/ { print $2 }' /proc/mounts 2>/dev/null) /root; do
	case "$_d" in /|/rom*|/overlay*|/proc*|/sys*|/dev*|*\\*) continue ;; esac
	[ -d "$_d" ] && [ -w "$_d" ] || continue
	[ "$(avail_kb "$_d")" -ge "$NEED_TMP_KB" ] || continue
	TMP="$_d/clashwrt-install.$$"
	break
done
[ -n "$TMP" ] || die "no filesystem has ${NEED_TMP_KB}K free for the download (/tmp has $(avail_kb /tmp)K); free some space"

# busybox has no `install` applet, and busybox is what OpenWrt actually ships,
# so these do the same job with mkdir/cp/chmod.
idir() { mkdir -p "$@"; }

# icp <mode> <src>... <dst>   -- dst is a directory when it ends in / or exists
icp() {
	_mode="$1"; shift
	_n=$#
	_dst=""
	for _a in "$@"; do _dst="$_a"; done

	case "$_dst" in
		*/) mkdir -p "$_dst" ;;
	esac

	_i=0
	for _a in "$@"; do
		_i=$((_i + 1))
		[ "$_i" -lt "$_n" ] || break
		if [ -d "$_dst" ]; then
			cp -f "$_a" "${_dst%/}/" || return 1
			chmod "$_mode" "${_dst%/}/$(basename "$_a")" || return 1
		else
			mkdir -p "$(dirname "$_dst")"
			cp -f "$_a" "$_dst" || return 1
			chmod "$_mode" "$_dst" || return 1
		fi
	done
}

cleanup() { rm -rf "$TMP"; }
trap cleanup EXIT

[ "$(id -u)" = "0" ] || die "run this as root"
[ -f /etc/openwrt_release ] || warn "this does not look like OpenWrt; continuing anyway"

mkdir -p "$TMP"

# Two channels. "release" installs the newest tag, so a router does not pick
# up whatever landed on the branch an hour ago; "main" is the rolling one.
resolve_source() {
	[ -n "$REPO_URL" ] && return 0
	if [ "$CHANNEL" = "main" ]; then
		REPO_URL="https://github.com/$SLUG/archive/refs/heads/main.tar.gz"
	else
		SRC_TAG="$(cw_curl -sSL -m 25 "https://api.github.com/repos/$SLUG/releases/latest" 2>/dev/null \
			| sed -n 's/.*"tag_name"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' | head -n1)" || SRC_TAG=""
		case "$SRC_TAG" in
			"" | *[!A-Za-z0-9._-]*) SRC_TAG="" ;;
		esac
		if [ -n "$SRC_TAG" ]; then
			REPO_URL="https://github.com/$SLUG/archive/refs/tags/$SRC_TAG.tar.gz"
		else
			# no release published yet, or the API is unreachable
			REPO_URL="https://github.com/$SLUG/archive/refs/heads/main.tar.gz"
		fi
	fi
}

# --------------------------------------------------------------------------
# questions
# --------------------------------------------------------------------------
#
# Read from /dev/tty, so they work when this script itself arrives through a
# pipe. No terminal, or the updater running this: nothing is asked, what was
# chosen before stays, and a fresh router gets the recommended answers.

INTERACTIVE=0
if [ "$SKIP_CORE" != 1 ] && [ -z "$REPO_URL" ] && ( : < /dev/tty ) 2>/dev/null; then
	INTERACTIVE=1
fi

# ask <question> <default> <key|label>...  prints the key chosen: by number,
# by key, or Enter for the default
ask() {
	_q="$1"; _def="$2"; shift 2
	if [ "$INTERACTIVE" != 1 ]; then echo "$_def"; return 0; fi
	while :; do
		{
			echo
			echo "$_q"
			_i=0
			for _c in "$@"; do
				_i=$((_i + 1))
				_m=""; [ "${_c%%|*}" = "$_def" ] && _m="   (recommended)"
				printf '  %d) %s%s\n' "$_i" "${_c#*|}" "$_m"
			done
			printf 'Choice [Enter = %s]: ' "$_def"
		} > /dev/tty
		read -r _a < /dev/tty || _a=""
		[ -n "$_a" ] || { echo "$_def"; return 0; }
		_i=0
		for _c in "$@"; do
			_i=$((_i + 1))
			if [ "$_a" = "$_i" ] || [ "$_a" = "${_c%%|*}" ]; then echo "${_c%%|*}"; return 0; fi
		done
		echo "  that is not one of the choices" > /dev/tty
	done
}

mb() { echo "$(( ($1 + 512) / 1024 )) MB"; }

# What there is to work with. The core already on flash is room too, since
# it is replaced.
MEM_KB="$(awk '/^MemTotal:/ { print $2 }' /proc/meminfo 2>/dev/null)"; MEM_KB="${MEM_KB:-0}"
FLASH_KB="$(avail_kb /usr/bin)"
OLD_CORE_KB=0
[ -f /usr/bin/mihomo ] && [ ! -L /usr/bin/mihomo ] && OLD_CORE_KB="$(du -k /usr/bin/mihomo | cut -f1)"
FLASH_KB=$((FLASH_KB + OLD_CORE_KB))
# the core unpacked and packed, with room to spare; the dashboards unpacked
CORE_FLASH_KB=65536
CORE_GZ_KB=26624
RAM_OK=0; [ "$MEM_KB" -ge 262144 ] && RAM_OK=1

CUR_STORE="$(uci -q get clashwrt.config.core_store 2>/dev/null)" || CUR_STORE=""
CUR_CHANNEL=release
grep -q '^repo=.*/archive/refs/heads/' /usr/libexec/clashwrt/.install-info 2>/dev/null && CUR_CHANNEL=main
HAVE_CORE=0; command -v mihomo >/dev/null 2>&1 && HAVE_CORE=1

if [ "$INTERACTIVE" = 1 ]; then
	echo
	echo "ClashWrt installer"
	echo "  router:  $(cat /tmp/sysinfo/model 2>/dev/null || echo unknown)"
	echo "  RAM:     $(mb "$MEM_KB")"
	echo "  flash:   $(mb "$FLASH_KB") free for the core"
fi

CHANNEL="$CUR_CHANNEL"
[ "$INTERACTIVE" = 1 ] && CHANNEL="$(ask "Which version?" "$CUR_CHANNEL" \
	"release|the latest release (checked against its SHA-256)" \
	"main|the development branch (newest, unchecked)")"

# where the core goes: only what fits is offered
CORE_UPDATE=no
CORE_STORE=""
if [ "$SKIP_CORE" != 1 ]; then
	CORE_UPDATE=yes
	[ "$HAVE_CORE" = 1 ] && CORE_UPDATE="$(ask "Update the mihomo core to the latest release?" yes \
		"yes|yes" "no|no, keep the one installed")"
	_opts=""; _rec=""
	if [ "$FLASH_KB" -ge "$CORE_FLASH_KB" ]; then _opts="$_opts flash"; _rec=flash; fi
	if [ "$RAM_OK" = 1 ] && [ "$FLASH_KB" -ge "$CORE_GZ_KB" ]; then _opts="$_opts gz"; [ -n "$_rec" ] || _rec=gz; fi
	if [ "$RAM_OK" = 1 ]; then _opts="$_opts ram"; [ -n "$_rec" ] || _rec=ram; fi
	[ -n "$_opts" ] || die "the mihomo core does not fit: it needs $(mb "$CORE_FLASH_KB") of flash, or $(mb "$CORE_GZ_KB") of flash and 256 MB of RAM, or 256 MB of RAM alone; this router has $(mb "$FLASH_KB") free and $(mb "$MEM_KB") of RAM. External storage (extroot on a USB stick) gives it the flash."
	[ -n "$CUR_STORE" ] && case " $_opts " in *" $CUR_STORE "*) _rec="$CUR_STORE" ;; esac
	set --
	for _o in $_opts; do
		case "$_o" in
			flash) set -- "$@" "flash|on flash: about 60 MB of flash, no RAM taken" ;;
			gz)    set -- "$@" "gz|packed on flash, unpacked into RAM at boot: about 22 MB of flash and 60 MB of RAM" ;;
			ram)   set -- "$@" "ram|only in RAM, downloaded at every boot: no flash, 60 MB of RAM, no core while GitHub is out of reach" ;;
		esac
	done
	CORE_STORE="$(ask "Where should the mihomo core be kept?" "$_rec" "$@")"
fi

# what is left for the rest
case "$CORE_STORE" in
	flash) LEFT_KB=$((FLASH_KB - CORE_FLASH_KB)) ;;
	gz)    LEFT_KB=$((FLASH_KB - CORE_GZ_KB)) ;;
	*)     LEFT_KB="$FLASH_KB" ;;
esac

UI_NAME=none
if [ "$SKIP_CORE" != 1 ] && [ ! -f "$MIHOMO_DIR/ui/index.html" ]; then
	_rec=none
	if [ "$LEFT_KB" -ge 12288 ]; then _rec=metacubexd; elif [ "$LEFT_KB" -ge 6144 ]; then _rec=yacd; fi
	UI_NAME="$(ask "Which web dashboard? (the LuCI pages work without one)" "$_rec" \
		"metacubexd|metacubexd, about 8 MB" "zashboard|zashboard, about 12 MB" \
		"yacd|Yacd-meta, about 5 MB" "none|none")"
fi
UI_STORE=""
if [ "$UI_NAME" != none ] && [ "$RAM_OK" = 1 ]; then
	case "$UI_NAME" in zashboard) _ui=12288 ;; yacd) _ui=5120 ;; *) _ui=8192 ;; esac
	_rec=flash; [ "$LEFT_KB" -ge $((_ui + 4096)) ] || _rec=gz
	_cur="$(uci -q get clashwrt.config.ui_store 2>/dev/null)" || _cur=""; [ -n "$_cur" ] && _rec="$_cur"
	UI_STORE="$(ask "Where should the dashboard be kept?" "$_rec" \
		"flash|on flash, about $(mb "$_ui")" \
		"gz|packed on flash, unpacked into RAM at boot: about a third of that on flash" \
		"ram|only in RAM, fetched again after every boot: no flash")"
	case "$UI_STORE" in flash) LEFT_KB=$((LEFT_KB - _ui)) ;; gz) LEFT_KB=$((LEFT_KB - _ui / 3)) ;; esac
fi

DNSMASQ_FULL=no
if ! { dnsmasq --version 2>/dev/null | grep -qw nftset && ! dnsmasq --version 2>/dev/null | grep -qw no-nftset; }; then
	_rec=no; [ "$LEFT_KB" -ge 4096 ] && _rec=yes
	[ "$SKIP_CORE" = 1 ] && _rec=no
	DNSMASQ_FULL="$(ask "Replace dnsmasq with dnsmasq-full? It lets the bypass set take config.yaml's domains (about 0.5 MB)" "$_rec" \
		"yes|yes" "no|no, keep the stock dnsmasq")"
fi

if [ "$INTERACTIVE" = 1 ]; then
	{
		echo
		echo "About to install:"
		echo "  version:   $CHANNEL"
		[ -n "$CORE_STORE" ] && echo "  core:      $( [ "$CORE_UPDATE" = yes ] && echo "latest release" || echo "keep the installed one"), kept: $CORE_STORE"
		echo "  dashboard: $UI_NAME${UI_STORE:+, kept: $UI_STORE}"
		echo "  dnsmasq-full: $DNSMASQ_FULL"
		printf 'Proceed? [Y/n]: '
	} > /dev/tty
	read -r _a < /dev/tty || _a=""
	case "$_a" in [nN]*) echo "nothing was changed"; exit 0 ;; esac
fi

# --------------------------------------------------------------------------
# dependencies
# --------------------------------------------------------------------------

if command -v apk >/dev/null 2>&1; then
	PKG_UPDATE="apk update"
	PKG_ADD="apk add"
elif command -v opkg >/dev/null 2>&1; then
	PKG_UPDATE="opkg update"
	PKG_ADD="opkg install"
else
	die "neither apk nor opkg found"
fi

have_cmd() { command -v "$1" >/dev/null 2>&1; }

# Package names are not stable across releases and some are virtual: nftables
# is provided by nftables-nojson / nftables-json rather than existing under
# that name, so a single hardcoded name fails on opkg systems. Try candidates
# until one takes.
need_pkg() {
	for _cand in "$@"; do
		$PKG_ADD "$_cand" >/dev/null 2>&1 && return 0
	done
	return 1
}

# ClashWrt builds nftables rules and relies on fw4 zones to let forwarded tun
# traffic through. On fw3/iptables systems (21.02 and older) the rules would be
# installed and then silently ignored, which is a worse failure than refusing.
if ! have_cmd fw4 && [ ! -x /sbin/fw4 ]; then
	die "this needs OpenWrt's fw4 firewall (22.03 or newer); fw3/iptables is not supported"
fi

say "refreshing the package index"
$PKG_UPDATE >/dev/null 2>&1 || warn "package index refresh failed; continuing with what is installed"

# Only install what is actually missing -- on a stock image most of this is
# already there, pulled in by firewall4.
have_cmd nft   || need_pkg nftables nftables-nojson nftables-json || warn "could not install nftables"
have_cmd curl  || need_pkg curl || die "curl is required and could not be installed"
[ -f /etc/ssl/certs/ca-certificates.crt ] || need_pkg ca-bundle >/dev/null 2>&1

# `ip rule` and `ip route ... table N` need the real iproute2, not busybox ip
ip rule show >/dev/null 2>&1 || need_pkg ip-full ip || warn "could not install ip-full; policy routing may not work"

# kmod names are stable, but they live in a per-kernel feed and a mismatched
# index makes them unavailable; none of these is fatal at install time
for p in kmod-nft-nat kmod-tun; do
	need_pkg "$p" || warn "could not install $p (may already be built in)"
done

# only the two TPROXY modes need this one
need_pkg kmod-nft-tproxy || warn "kmod-nft-tproxy unavailable -- the tproxy modes may not work; the other two are unaffected"

# socat is only used by the TPROXY selftest
need_pkg socat || warn "socat not installed -- the TPROXY selftest will be unavailable"

# --------------------------------------------------------------------------
# this package
# --------------------------------------------------------------------------

resolve_source

# Ask for the branch head *before* downloading the tarball, not after: a
# commit landing in between would otherwise be recorded as installed, and the
# update check would report the router as current while it is a commit behind.
# Erring the other way merely offers an update that changes nothing.
SRC_COMMIT=""
case "$REPO_URL" in
	https://github.com/*/archive/refs/tags/*.tar.gz)
		# a tag is already an exact point; take the name from the URL so an
		# explicit REPO_URL records a version too
		_t="${REPO_URL##*/tags/}"; SRC_TAG="${_t%.tar.gz}"
		;;
	https://github.com/*/archive/refs/heads/*.tar.gz)
		_slug="${REPO_URL#https://github.com/}"; _slug="${_slug%%/archive/*}"
		_ref="${REPO_URL##*/heads/}"; _ref="${_ref%.tar.gz}"
		# `set -e` is on and an assignment carries its command's status, so
		# an unreachable API would otherwise abort the whole install.
		SRC_COMMIT="$(cw_curl -sSL -m 25 -H 'Accept: application/vnd.github.sha' \
			"https://api.github.com/repos/$_slug/commits/$_ref" 2>/dev/null)" \
			|| SRC_COMMIT=""
		# a rate-limit body or an error page is not a commit
		case "$SRC_COMMIT" in
			"" | *[!0-9a-f]*) SRC_COMMIT="" ;;
		esac
		;;
esac

# A release from 1.4.0 on carries its own tarball, with a SHA-256 GitHub
# keeps for it; that one is fetched instead of the on-the-fly archive and has
# to match. Older releases and the main branch have nothing to check against.
SRC_SHA=""
case "$REPO_URL" in
	https://github.com/"$SLUG"/archive/refs/tags/*.tar.gz)
		SRC_SHA="$(asset_digest "$SLUG" "$SRC_TAG" "clashwrt-$SRC_TAG.tar.gz")" || SRC_SHA=""
		[ -n "$SRC_SHA" ] && REPO_URL="https://github.com/$SLUG/releases/download/$SRC_TAG/clashwrt-$SRC_TAG.tar.gz"
		;;
esac

say "fetching clashwrt"
# --proto: whatever this fetches is run as root, so a redirect to plain http
# (or file://) is not followed
cw_curl -sSL --fail --proto '=https' -m 120 -o "$TMP/src.tar.gz" "$REPO_URL" || die "could not download $REPO_URL"
if [ -n "$SRC_SHA" ]; then
	_got="$(sha256sum "$TMP/src.tar.gz" | awk '{ print $1 }')"
	[ "$_got" = "$SRC_SHA" ] || die "SHA-256 mismatch for $REPO_URL: GitHub says $SRC_SHA, the download is $_got"
	say "SHA-256 checked"
else
	warn "no SHA-256 to check this download against (main branch or a release before 1.4.0)"
fi
mkdir -p "$TMP/src"
# no --strip-components: busybox tar does not have it, and busybox is what
# OpenWrt ships. Extract as-is and step into the wrapper directory instead.
tar xzf "$TMP/src.tar.gz" -C "$TMP/src" || die "could not unpack the source tarball"

SRC="$TMP/src"
if [ ! -d "$SRC/clashwrt/files" ]; then
	inner="$(find "$SRC" -mindepth 1 -maxdepth 1 -type d | head -n1)"
	[ -n "$inner" ] && [ -d "$inner/clashwrt/files" ] && SRC="$inner"
fi
[ -d "$SRC/clashwrt/files" ] || die "unexpected tarball layout (no clashwrt/files)"

# Everything below writes to the overlay, and running out halfway would leave
# new scripts beside old pages. What it writes is the unpacked tree's own
# files, so their size is the measure; 512K of slack keeps the overlay off its
# last block. Files that already exist are overwritten, so this overcounts on
# an upgrade, which is the safe direction.
_need=$(( $(du -sk "$SRC/clashwrt/files" "$SRC/luci-app-clashwrt" 2>/dev/null | awk '{ s += $1 } END { print s + 0 }') + 512 ))
_have="$(avail_kb /usr/libexec)"
[ "$_have" -ge "$_need" ] ||
	die "not enough room on the overlay: ClashWrt needs about ${_need}K and there is ${_have}K free; nothing has been changed"

# What the user last chose for the mihomo core, read before anything below can
# create or enable it. Switching the core off from the Overview page disables
# it at boot; an upgrade must not undo that.
CORE_STATE="fresh"
if [ -x /etc/init.d/mihomo ]; then
	if /etc/init.d/mihomo enabled >/dev/null 2>&1; then CORE_STATE="on"; else CORE_STATE="off"; fi
fi

# Likewise for the service itself: if it was switched off from the Overview
# page, an upgrade must not switch it back on.
SVC_STATE="fresh"
if [ -x /etc/init.d/clashwrt ]; then
	if ls /etc/rc.d/S[0-9][0-9]clashwrt >/dev/null 2>&1; then SVC_STATE="on"; else SVC_STATE="off"; fi
fi

say "installing firewall engine and service"
idir /usr/libexec/clashwrt
for f in "$SRC"/clashwrt/files/usr/libexec/clashwrt/*.sh; do
	icp 0755 "$f" /usr/libexec/clashwrt/
done

idir /etc/init.d
icp 0755 "$SRC/clashwrt/files/etc/init.d/clashwrt" /etc/init.d/clashwrt

idir /etc/hotplug.d/net
icp 0644 "$SRC/clashwrt/files/etc/hotplug.d/net/30-clashwrt" /etc/hotplug.d/net/30-clashwrt

# never clobber an existing configuration on upgrade
idir /etc/config
if [ -f /etc/config/clashwrt ]; then
	say "keeping the existing /etc/config/clashwrt"
else
	icp 0644 "$SRC/clashwrt/files/etc/config/clashwrt" /etc/config/clashwrt
fi

idir /etc/sysctl.d
sh "$SRC/clashwrt/files/etc/uci-defaults/99-clashwrt" >/dev/null 2>&1 || true

say "installing the LuCI pages"
# The canonical copies live outside the web root; uistamp publishes them under
# content-addressed names so that an update actually reaches the browser.
idir /usr/share/clashwrt/ui/view /usr/share/clashwrt/ui/mod
# pages that no longer exist (merged into other tabs) must not be republished
rm -f /usr/share/clashwrt/ui/view/*.js /usr/share/clashwrt/ui/mod/*.js
icp 0644 "$SRC"/luci-app-clashwrt/htdocs/luci-static/resources/view/clashwrt/*.js \
	/usr/share/clashwrt/ui/view/
icp 0644 "$SRC"/luci-app-clashwrt/htdocs/luci-static/resources/clashwrt/*.js \
	/usr/share/clashwrt/ui/mod/
icp 0644 "$SRC/luci-app-clashwrt/root/usr/share/luci/menu.d/luci-app-clashwrt.json" \
	/usr/share/clashwrt/ui/menu.json

idir /usr/share/rpcd/acl.d
icp 0644 "$SRC/luci-app-clashwrt/root/usr/share/rpcd/acl.d/luci-app-clashwrt.json" \
	/usr/share/rpcd/acl.d/

# anything published by an older layout, before stamping existed
rm -f /www/luci-static/resources/view/clashwrt/*.js /www/luci-static/resources/clashwrt/*.js 2>/dev/null

/usr/libexec/clashwrt/uistamp.sh apply >/dev/null 2>&1 || warn "could not publish the LuCI pages"

# translations, if the build shipped any
if [ -d "$SRC/luci-app-clashwrt/po" ]; then
	idir /usr/lib/lua/luci/i18n
	for lmo in "$SRC"/luci-app-clashwrt/po/*/*.lmo; do
		[ -f "$lmo" ] || continue
		icp 0644 "$lmo" /usr/lib/lua/luci/i18n/
	done
fi

# What the Settings page compares against to tell whether an update is
# waiting. A copy installed from the OpenWrt package feed has no such file and
# simply reports its version as unknown.
cat > /usr/libexec/clashwrt/.install-info <<EOF
repo=$REPO_URL
version=$SRC_TAG
commit=$SRC_COMMIT
date=$(date -u '+%Y-%m-%dT%H:%M:%SZ')
EOF
chmod 0644 /usr/libexec/clashwrt/.install-info

# --------------------------------------------------------------------------
# dnsmasq-full
# --------------------------------------------------------------------------

# The bypass set takes config.yaml's domains through dnsmasq's nftset=, which
# the stock dnsmasq is built without; without it the set is held back and
# everything goes through mihomo. Swapped here once, so nobody has to find
# the button. setctl.sh does the work (and the same from the Bypass tab):
# it downloads first and only then replaces, keeping /etc/config/dhcp.
if [ "$DNSMASQ_FULL" = yes ]; then
	if dnsmasq --version 2>/dev/null | grep -qw nftset && ! dnsmasq --version 2>/dev/null | grep -qw no-nftset; then
		: # already there
	else
		say "replacing dnsmasq with dnsmasq-full (DNS pauses for a few seconds)"
		/usr/libexec/clashwrt/setctl.sh install-dnsmasq-full >/dev/null 2>&1 ||
			warn "could not install dnsmasq-full; the bypass set will not use config.yaml's domains until it is (Settings -> Bypass has a button)"
	fi
fi

# --------------------------------------------------------------------------
# mihomo core
# --------------------------------------------------------------------------

# Deliberately after the scripts are in place: updctl.sh is the single place
# that knows how to pick a mihomo build for this CPU, and install.sh calls it
# rather than carrying a second copy of that table for the two to drift apart.
# It also means a core download that fails leaves a router that can retry from
# the Settings page, instead of one with nothing installed at all.
if [ "$SKIP_CORE" = 1 ] && command -v mihomo >/dev/null 2>&1; then
	say "keeping the existing mihomo core"
else
	if [ -n "$CORE_STORE" ]; then
		uci -q set "clashwrt.config.core_store=$CORE_STORE" && uci -q commit clashwrt
	fi
	if ! /usr/libexec/clashwrt/updctl.sh arch >/dev/null 2>&1; then
		[ "$INTERACTIVE" = 1 ] || die "cannot tell which mihomo build suits this CPU ($(uname -m)); run this installer on a terminal to name it"
		printf '\nWhich mihomo build suits this CPU (%s)? e.g. arm64, armv7, mipsle-softfloat: ' "$(uname -m)" > /dev/tty
		read -r MIHOMO_ARCH < /dev/tty || MIHOMO_ARCH=""
		export MIHOMO_ARCH
	fi
	if [ "$CORE_UPDATE" = yes ] || [ "$HAVE_CORE" != 1 ]; then
		say "installing the mihomo core"
		/usr/libexec/clashwrt/updctl.sh core-install || die "could not install the mihomo core"
	elif [ -n "$CORE_STORE" ] && [ "$CORE_STORE" != "${CUR_STORE:-flash}" ]; then
		say "moving the mihomo core: $CORE_STORE"
		/usr/libexec/clashwrt/updctl.sh core-store "$CORE_STORE" || warn "could not move the core; it stays where it was"
	fi
fi

# --------------------------------------------------------------------------
# mihomo working directory
# --------------------------------------------------------------------------

idir "$MIHOMO_DIR"

if [ ! -f "$MIHOMO_DIR/config.yaml" ]; then
	say "writing a placeholder config (the wizard will replace it)"
	# The controller listens on every interface so the dashboard works from
	# the LAN; without a secret anyone there could drive it.
	API_SECRET="$(tr -dc 'A-Za-z0-9' < /dev/urandom 2>/dev/null | head -c 24)"
	cat > "$MIHOMO_DIR/config.yaml" <<EOF
# Placeholder written by the clashwrt installer.
# Use Services -> ClashWrt -> Setup wizard to generate a real one.
mode: rule
log-level: warning
ipv6: false
allow-lan: false
external-controller: 0.0.0.0:9090
secret: '$API_SECRET'
external-ui: $MIHOMO_DIR/ui
routing-mark: 2
redir-port: 7893
tun:
  enable: true
  device: clash-tun
  stack: system
  auto-route: false
  auto-redirect: false
  auto-detect-interface: false
dns:
  enable: true
  ipv6: false
  listen: 0.0.0.0:1053
  enhanced-mode: redir-host
  nameserver:
    - 9.9.9.9
    - 149.112.112.112
rules:
  - MATCH,DIRECT
EOF
fi

# The init script is ClashWrt's own and is rewritten on every upgrade, as long
# as it is still ours: one carrying the marker below, or the one 1.3 and
# earlier wrote without it. Delete the marker line to keep an edited copy.
if [ ! -f /etc/init.d/mihomo ] || grep -q '^# written by clashwrt' /etc/init.d/mihomo ||
	grep -qF 'procd_set_param command "$MIHOMO_BIN" -d "$MIHOMO_DIR"' /etc/init.d/mihomo; then
	say "installing the init script for the mihomo core"
	cat > /etc/init.d/mihomo.clashwrt-new <<'EOF'
#!/bin/sh /etc/rc.common
# written by clashwrt -- replaced on every upgrade; delete this line to keep
# your own changes.
START=99
STOP=10
USE_PROCD=1

MIHOMO_BIN="/usr/bin/mihomo"
MIHOMO_DIR="/etc/mihomo"
UPDCTL="/usr/libexec/clashwrt/updctl.sh"

start_service() {
	# a core kept in RAM (Settings -> Storage) is put there first
	[ -x "$MIHOMO_BIN" ] || { [ -x "$UPDCTL" ] && "$UPDCTL" core-boot >/dev/null 2>&1; }
	[ -x "$MIHOMO_BIN" ] || { logger -t mihomo "binary not found (a core kept only in RAM may still be downloading)"; return 1; }
	[ -f "$MIHOMO_DIR/config.yaml" ] || { logger -t mihomo "config not found"; return 1; }

	local env=""
	[ -x "$UPDCTL" ] && env="$("$UPDCTL" core-env 2>/dev/null)"

	procd_open_instance
	procd_set_param command "$MIHOMO_BIN" -d "$MIHOMO_DIR"
	# shellcheck disable=SC2086
	[ -n "$env" ] && procd_set_param env $env
	procd_set_param stdout 1
	procd_set_param stderr 1
	procd_set_param respawn 3600 5 5
	procd_set_param file "$MIHOMO_DIR/config.yaml"
	procd_close_instance
}

reload_service() {
	stop
	start
}
EOF
	chmod +x /etc/init.d/mihomo.clashwrt-new
	mv -f /etc/init.d/mihomo.clashwrt-new /etc/init.d/mihomo
else
	warn "keeping your own /etc/init.d/mihomo; a core kept in RAM and the memory limit need ClashWrt's"
fi

# --------------------------------------------------------------------------
# dashboard
# --------------------------------------------------------------------------

if [ "$UI_NAME" != none ] && [ ! -f "$MIHOMO_DIR/ui/index.html" ]; then
	say "installing the web dashboard ($UI_NAME)"
	[ -n "$UI_STORE" ] && uci -q set "clashwrt.config.ui_store=$UI_STORE" && uci -q commit clashwrt
	/usr/libexec/clashwrt/uictl.sh install "$UI_NAME" || warn "dashboard install failed; do it later from the Web dashboard page"
fi

# --------------------------------------------------------------------------
# enable
# --------------------------------------------------------------------------

if [ "$SVC_STATE" = "off" ]; then
	say "ClashWrt is switched off on this router; leaving it that way"
else
	/etc/init.d/clashwrt enable >/dev/null 2>&1 || true
fi
if [ "$CORE_STATE" = "off" ]; then
	say "the mihomo core is switched off on this router; leaving it that way"
else
	/etc/init.d/mihomo enable  >/dev/null 2>&1 || true
	/etc/init.d/mihomo restart >/dev/null 2>&1 || warn "mihomo did not start (expected until a real config exists)"
fi

rm -f /tmp/luci-indexcache* 2>/dev/null || true
/etc/init.d/rpcd restart >/dev/null 2>&1 || true

cat <<EOF

Done.

  Interface : Services -> ClashWrt
  Next      : run the Setup wizard, then switch the proxy on from the Overview page

The firewall side stays off until you enable it, so nothing on the network has
changed yet. If you do not know which interception mode this kernel supports,
press "Test TPROXY support" on the Settings page and it will tell you.
EOF
