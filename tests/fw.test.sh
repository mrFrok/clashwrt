#!/bin/sh
# fw.sh: what apply_nft hands to nft -f, line by line.
T="$(cd "$(dirname "$0")" && pwd)"
. "$T/lib.sh"
FWSH="$T/../clashwrt/files/usr/libexec/clashwrt/fw.sh"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

mkdir -p "$TMP/bin"
# nft: lists nothing, keeps a copy of every script it is handed
cat > "$TMP/bin/nft" <<'X'
#!/bin/sh
[ "$1" = -f ] && cp "$2" "$NFT_BATCH_COPY"
exit 0
X
chmod +x "$TMP/bin/nft"
export PATH="$TMP/bin:$PATH" NFT_BATCH_COPY="$TMP/batch" CLASHWRT_TEST=1 \
	CLASHWRT_FUNCTIONS="$T/shim/functions.sh" CLASHWRT_NETWORK="$T/shim/network.sh" \
	CLASHWRT_LIBEXEC="$T/../clashwrt/files/usr/libexec/clashwrt"

# shellcheck source=/dev/null
. "$FWSH"
log() { :; }

TABLE="inet clashwrt"; self_mark=2; lan_device=br-lan; set_mode=off; mode=tun
resolve_devices
dns_port=1053; api_port=9090; mark_tproxy=1; mark_tun=3

block_ipv6=1
apply_nft
grep -q 'add chain inet clashwrt leak6 { type filter hook forward' "$TMP/batch" &&
	pass "IPv6 leak chain on the forward hook" || fail "IPv6 leak chain on the forward hook"
grep -q 'iifname { "br-lan" } meta nfproto ipv6 oifname != { "br-lan" } reject' "$TMP/batch" &&
	pass "LAN IPv6 leaving the LAN is rejected" || fail "LAN IPv6 leaving the LAN is rejected"

block_ipv6=0
apply_nft
grep -q leak6 "$TMP/batch" && fail "block_ipv6 off: no chain" || pass "block_ipv6 off: no chain"

block_ipv6=0; block_dot=1; block_doh=1
apply_nft
grep -q 'th dport 853 reject' "$TMP/batch" && pass "DoT rejected" || fail "DoT rejected"
grep -q 'ip daddr @doh4 meta l4proto { tcp, udp } th dport 443 reject' "$TMP/batch" && pass "DoH resolvers rejected" || fail "DoH resolvers rejected"
grep -q 'add set inet clashwrt doh4 ' "$TMP/batch" && pass "doh4 set declared" || fail "doh4 set declared"
block_dot=0; block_doh=0
apply_nft
grep -q 'dport 853\|@doh4 ' "$TMP/batch" && fail "both off: no rules" || pass "both off: no rules"

# several LAN interfaces, by device or by network name
network_get_device() { case "$2" in guest) eval "$1=br-guest" ;; *) return 1 ;; esac; }
lan_device="br-lan guest br-lan iot0"; resolve_devices
eq "devices resolved, deduplicated, in order" "br-lan br-guest iot0" "$lan_devices"
eq "the first stays lan_device" "br-lan" "$lan_device"
apply_nft
grep -q 'mangle iifname != { "br-lan", "br-guest", "iot0" } return' "$TMP/batch" &&
	pass "every LAN is intercepted" || fail "every LAN is intercepted"

finish
