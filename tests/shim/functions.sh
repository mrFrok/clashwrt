# Stand-in for OpenWrt's /lib/functions.sh, backed by the fake uci below.
config_load() { CFG_PKG="$1"; }
config_get() {
	local __v
	__v="$(uci -q get "$CFG_PKG.$2.$3" 2>/dev/null)"
	[ -n "$__v" ] || __v="$4"
	eval "$1=\$__v"
}
