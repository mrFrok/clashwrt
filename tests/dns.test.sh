#!/bin/sh
# fw.sh: dnsmasq's forward to mihomo is taken out while the bypass flag
# exists and restored afterwards; reload leaves a matching ruleset alone.
T="$(cd "$(dirname "$0")" && pwd)"
. "$T/lib.sh"
FWSH="$T/../clashwrt/files/usr/libexec/clashwrt/fw.sh"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

mkdir -p "$TMP/db" "$TMP/run" "$TMP/bin" "$TMP/rcd"
cp "$T"/shim/uci "$T"/shim/logger "$TMP/bin/"
cat > "$TMP/bin/nft" <<'X'
#!/bin/sh
echo "nft $*" >> "$NFT_LOG"
case "$1 $2" in "list table") [ -e "$NFT_TABLE" ] ;; esac
X
cat > "$TMP/bin/dnsmasq-init" <<'X'
#!/bin/sh
echo "$*" >> "$DNSMASQ_LOG"
X
chmod +x "$TMP"/bin/*

export PATH="$TMP/bin:$PATH" UCI_DB="$TMP/db" NFT_LOG="$TMP/nft.log" NFT_TABLE="$TMP/table" \
	DNSMASQ_LOG="$TMP/dnsmasq.log" LOGGER_OUT="$TMP/logger.log" \
	CLASHWRT_TEST=1 CLASHWRT_FUNCTIONS="$T/shim/functions.sh" CLASHWRT_NETWORK="$T/shim/network.sh" \
	CLASHWRT_RUNDIR="$TMP/run" CLASHWRT_RCD="$TMP/rcd" CLASHWRT_LIBEXEC="$T/../clashwrt/files/usr/libexec/clashwrt" \
	CLASHWRT_DNS_BAK="$TMP/dns.bak" CLASHWRT_DNSMASQ_INIT="$TMP/bin/dnsmasq-init"

# shellcheck source=/dev/null
. "$FWSH"

dns_port=1053
SRV="dhcp.@dnsmasq[0].server"
servers() { uci -q get "$SRV"; }
reloads() { [ -e "$DNSMASQ_LOG" ] && wc -l < "$DNSMASQ_LOG" || echo 0; }

uci add_list "$SRV=127.0.0.1#1053"
uci add_list "$SRV=/lan.example/192.168.1.2"

dns_sync    # no flag, no backup: nothing to do
eq "no flag, nothing changes" "127.0.0.1#1053 /lan.example/192.168.1.2" "$(servers)"
eq "no reload without a change" "0" "$(reloads)"

: > "$FLAG"
dns_sync
eq "flag: the mihomo forward is gone, the rest stays" "/lan.example/192.168.1.2" "$(servers)"
eq "flag: dnsmasq was reloaded once" "1" "$(reloads)"
[ -e "$DNS_BAK" ] && pass "original list saved" || fail "no backup"

dns_sync
eq "flag: a second sync changes nothing" "1" "$(reloads)"

rm -f "$FLAG"
dns_sync
eq "no flag: the original list is back, in order" "127.0.0.1#1053 /lan.example/192.168.1.2" "$(servers)"
[ ! -e "$DNS_BAK" ] && pass "backup removed" || fail "backup left"
eq "restore reloaded dnsmasq" "2" "$(reloads)"

# only forward is mihomo, uplink resolvers are switched off: borrow the uplink's
rm -f "$UCI_DB"/*; rm -f "$DNSMASQ_LOG"
uci add_list "$SRV=127.0.0.1#1053"
uci set "dhcp.@dnsmasq[0].noresolv=1"
printf 'nameserver 127.0.0.1\nnameserver 9.9.9.9\n' > "$TMP/resolv.auto"
uci set "dhcp.@dnsmasq[0].resolvfile=$TMP/resolv.auto"
: > "$FLAG"
dns_sync
eq "noresolv: borrows the uplink resolver" "9.9.9.9" "$(servers)"
rm -f "$FLAG"
dns_sync
eq "noresolv: restored exactly" "127.0.0.1#1053" "$(servers)"

# nothing to fall back to: leave DNS alone and say so
: > "$TMP/resolv.auto"
: > "$FLAG"
dns_sync
eq "no uplink resolver: forward untouched" "127.0.0.1#1053" "$(servers)"
[ ! -e "$DNS_BAK" ] && pass "no backup for an untouched list" || fail "backup written"
rm -f "$FLAG"

# a forward that is not mihomo's is never touched
rm -f "$UCI_DB"/*
uci add_list "$SRV=1.1.1.1"
: > "$FLAG"; dns_sync; rm -f "$FLAG"; dns_sync
eq "foreign forward untouched" "1.1.1.1" "$(servers)"

# power cut during a bypass: the flag is gone (/var/run), the backup is not
rm -f "$UCI_DB"/*
uci add_list "$SRV=127.0.0.1#1053"
: > "$FLAG"; dns_sync
rm -f "$FLAG"
dns_sync
eq "restored on the next sync after a reboot" "127.0.0.1#1053" "$(servers)"

# reload: skipped when the table is there and the settings match
rm -f "$UCI_DB"/*
uci set clashwrt.config.enabled=1
uci set clashwrt.config.mode=tun
: > "$TMP/rcd/S98clashwrt"
: > "$NFT_TABLE"
applied=0
do_apply() { applied=$((applied + 1)); fw_sig > "$SIGFILE"; }
do_reload
eq "no saved signature: applies" "1" "$applied"
do_reload
eq "same settings: reload does nothing" "1" "$applied"
uci set clashwrt.config.watchdog=1
do_reload
eq "watchdog option change: still nothing" "1" "$applied"
uci set clashwrt.config.mode=tproxy
do_reload
eq "firewall setting change: applies" "2" "$applied"
rm -f "$NFT_TABLE"
do_reload
eq "table gone: applies" "3" "$applied"
: > "$NFT_TABLE"
: > "$FLAG"
do_reload
eq "bypass active: goes through apply's own gate" "4" "$applied"

finish
