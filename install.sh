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
# Environment overrides:
#   REPO_URL=...      source tarball (default: this project's main branch)
#   MIHOMO_VERSION=   pin the core version instead of taking the latest
#   SKIP_CORE=1       leave an existing mihomo binary alone
#   SKIP_UI=1         do not download a dashboard

set -e

REPO_URL="${REPO_URL:-https://github.com/mrFrok/clashwrt/archive/refs/heads/main.tar.gz}"
MIHOMO_DIR="${MIHOMO_DIR:-/etc/mihomo}"
TMP="/tmp/clashwrt-install.$$"

say()  { echo "==> $*"; }
warn() { echo "[!] $*" >&2; }
die()  { echo "[x] $*" >&2; exit 1; }

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
# mihomo core
# --------------------------------------------------------------------------

map_arch() {
	case "$(uname -m)" in
		aarch64)         echo "arm64" ;;
		x86_64)          echo "amd64-compatible" ;;
		armv7l|armv7)    echo "armv7" ;;
		armv6l)          echo "armv6" ;;
		armv5*)          echo "armv5" ;;
		mips)            echo "mips-softfloat" ;;
		mipsel)          echo "mipsle-softfloat" ;;
		mips64)          echo "mips64" ;;
		mips64el)        echo "mips64le" ;;
		riscv64)         echo "riscv64" ;;
		i386|i686)       echo "386" ;;
		*) return 1 ;;
	esac
}

install_core() {
	if [ "${SKIP_CORE:-0}" = "1" ] && command -v mihomo >/dev/null 2>&1; then
		say "keeping the existing mihomo core"
		return 0
	fi

	local arch ver url
	arch="$(map_arch)" || die "unsupported CPU architecture: $(uname -m)"

	ver="${MIHOMO_VERSION:-}"
	if [ -z "$ver" ]; then
		say "looking up the latest mihomo release"
		ver="$(curl -sSL -m 30 https://api.github.com/repos/MetaCubeX/mihomo/releases/latest \
			| sed -n 's/.*"tag_name"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' | head -n1)"
	fi
	[ -n "$ver" ] || die "could not determine the mihomo version (set MIHOMO_VERSION=vX.Y.Z)"

	url="https://github.com/MetaCubeX/mihomo/releases/download/${ver}/mihomo-linux-${arch}-${ver}.gz"
	say "downloading mihomo ${ver} for ${arch}"
	curl -sSL --fail -m 300 -o "$TMP/mihomo.gz" "$url" || die "download failed: $url"

	gzip -dc "$TMP/mihomo.gz" > "$TMP/mihomo" || die "could not decompress the core"
	chmod +x "$TMP/mihomo"

	# a core that cannot run is worse than none: check before replacing
	"$TMP/mihomo" -v >/dev/null 2>&1 || die "the downloaded core does not run on this system"

	icp 0755 "$TMP/mihomo" /usr/bin/mihomo
	say "installed $(/usr/bin/mihomo -v 2>&1 | head -n1)"
}

install_core

# --------------------------------------------------------------------------
# this package
# --------------------------------------------------------------------------

say "fetching clashwrt"
curl -sSL --fail -m 120 -o "$TMP/src.tar.gz" "$REPO_URL" || die "could not download $REPO_URL"
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
idir /www/luci-static/resources/view/clashwrt /www/luci-static/resources/clashwrt
icp 0644 "$SRC"/luci-app-clashwrt/htdocs/luci-static/resources/view/clashwrt/*.js \
	/www/luci-static/resources/view/clashwrt/
icp 0644 "$SRC"/luci-app-clashwrt/htdocs/luci-static/resources/clashwrt/*.js \
	/www/luci-static/resources/clashwrt/

idir /usr/share/luci/menu.d /usr/share/rpcd/acl.d
icp 0644 "$SRC/luci-app-clashwrt/root/usr/share/luci/menu.d/luci-app-clashwrt.json" \
	/usr/share/luci/menu.d/
icp 0644 "$SRC/luci-app-clashwrt/root/usr/share/rpcd/acl.d/luci-app-clashwrt.json" \
	/usr/share/rpcd/acl.d/

# translations, if the build shipped any
if [ -d "$SRC/luci-app-clashwrt/po" ]; then
	idir /usr/lib/lua/luci/i18n
	for lmo in "$SRC"/luci-app-clashwrt/po/*/*.lmo; do
		[ -f "$lmo" ] || continue
		icp 0644 "$lmo" /usr/lib/lua/luci/i18n/
	done
fi

# --------------------------------------------------------------------------
# mihomo working directory
# --------------------------------------------------------------------------

idir "$MIHOMO_DIR"

if [ ! -f "$MIHOMO_DIR/config.yaml" ]; then
	say "writing a placeholder config (the wizard will replace it)"
	cat > "$MIHOMO_DIR/config.yaml" <<EOF
# Placeholder written by the clashwrt installer.
# Use Services -> ClashWrt -> Setup wizard to generate a real one.
mode: rule
log-level: info
ipv6: false
allow-lan: false
external-controller: 0.0.0.0:9090
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

if [ ! -f /etc/init.d/mihomo ]; then
	say "installing an init script for the mihomo core"
	cat > /etc/init.d/mihomo <<'EOF'
#!/bin/sh /etc/rc.common
START=99
STOP=10
USE_PROCD=1

MIHOMO_BIN="/usr/bin/mihomo"
MIHOMO_DIR="/etc/mihomo"

start_service() {
	[ -x "$MIHOMO_BIN" ] || { logger -t mihomo "binary not found"; return 1; }
	[ -f "$MIHOMO_DIR/config.yaml" ] || { logger -t mihomo "config not found"; return 1; }

	procd_open_instance
	procd_set_param command "$MIHOMO_BIN" -d "$MIHOMO_DIR"
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
	chmod +x /etc/init.d/mihomo
fi

# --------------------------------------------------------------------------
# dashboard
# --------------------------------------------------------------------------

if [ "${SKIP_UI:-0}" != "1" ] && [ ! -f "$MIHOMO_DIR/ui/index.html" ]; then
	say "installing the web dashboard"
	/usr/libexec/clashwrt/uictl.sh install metacubexd || warn "dashboard install failed; do it later from the Web dashboard page"
fi

# --------------------------------------------------------------------------
# enable
# --------------------------------------------------------------------------

/etc/init.d/mihomo enable  >/dev/null 2>&1 || true
/etc/init.d/clashwrt enable >/dev/null 2>&1 || true
/etc/init.d/mihomo restart >/dev/null 2>&1 || warn "mihomo did not start (expected until a real config exists)"

rm -f /tmp/luci-indexcache* 2>/dev/null || true
/etc/init.d/rpcd restart >/dev/null 2>&1 || true

cat <<EOF

Done.

  Interface : Services -> ClashWrt
  Next      : run the Setup wizard, then enable the proxy on the Settings page

The firewall side stays off until you enable it, so nothing on the network has
changed yet. If you do not know which interception mode this kernel supports,
press "Test TPROXY support" on the Settings page and it will tell you.
EOF
