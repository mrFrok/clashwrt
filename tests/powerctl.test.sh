#!/bin/sh
# powerctl.sh: core off is refused while the proxy rules are loaded, in step
# with proxy on being refused while the core is down.
T="$(cd "$(dirname "$0")" && pwd)"
. "$T/lib.sh"
POWERCTL="$T/../clashwrt/files/usr/libexec/clashwrt/powerctl.sh"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
mkdir -p "$TMP/bin" "$TMP/db" "$TMP/run" "$TMP/rcd"

cp "$T"/shim/uci "$T"/shim/logger "$TMP/bin/"
cat > "$TMP/bin/nft" <<'X'
#!/bin/sh
[ "$1 $2" = "list table" ] && [ -e "$NFT_TABLE" ]
X
cat > "$TMP/bin/pidof" <<'X'
#!/bin/sh
[ -e "$CORE_UP" ]
X
cat > "$TMP/bin/mihomo" <<'X'
#!/bin/sh
exit 0
X
cat > "$TMP/mihomo-init" <<'X'
#!/bin/sh
echo "$1" >> "$CORE_LOG"
case "$1" in stop) rm -f "$CORE_UP" ;; esac
exit 0
X
cat > "$TMP/self-init" <<'X'
#!/bin/sh
case "$1" in stop) rm -f "$NFT_TABLE" ;; esac
exit 0
X
cat > "$TMP/fw" <<'X'
#!/bin/sh
exit 0
X
chmod +x "$TMP"/bin/* "$TMP/mihomo-init" "$TMP/self-init" "$TMP/fw"

export PATH="$TMP/bin:$PATH" UCI_DB="$TMP/db" NFT_TABLE="$TMP/table" CORE_UP="$TMP/core-up" CORE_LOG="$TMP/core.log" \
	CLASHWRT_CORE_INIT="$TMP/mihomo-init" CLASHWRT_SELF_INIT="$TMP/self-init" CLASHWRT_FW="$TMP/fw" \
	CLASHWRT_WATCHDOG="$TMP/none" CLASHWRT_RUNDIR="$TMP/run" CLASHWRT_RCD="$TMP/rcd" \
	CLASHWRT_LOCKFILE="$TMP/power.lock" CLASHWRT_LIBEXEC="$T/../clashwrt/files/usr/libexec/clashwrt" CLASHWRT_LOCK_WAIT=2

: > "$CORE_UP"
uci set clashwrt.config.enabled=1
: > "$NFT_TABLE"

out="$(sh "$POWERCTL" core off 2>&1)"; rc=$?
eq "core off with the proxy on: refused" "1" "$rc"
case "$out" in *"proxy is still on"*) pass "refusal says why" ;; *) fail "message: $out" ;; esac
[ -e "$CORE_UP" ] && pass "core still running" || fail "core was stopped"
[ ! -e "$CORE_LOG" ] && pass "init script not called" || fail "init script called: $(cat "$CORE_LOG")"

uci set clashwrt.config.enabled=0
rm -f "$NFT_TABLE"
out="$(sh "$POWERCTL" core off 2>&1)"; rc=$?
eq "core off with the proxy off: allowed" "0" "$rc"
[ ! -e "$CORE_UP" ] && pass "core stopped" || fail "core still up"

: > "$CORE_UP"; uci set clashwrt.config.enabled=1; : > "$NFT_TABLE"
sh "$POWERCTL" all off >/dev/null 2>&1; rc=$?
eq "all off: proxy goes first, then the core" "0" "$rc"

finish
