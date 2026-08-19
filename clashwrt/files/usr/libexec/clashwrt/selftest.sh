#!/bin/sh
# SPDX-License-Identifier: GPL-3.0-or-later
#
# Does this kernel actually deliver TPROXY'd packets to a transparent socket?
#
# Worth asking, because when it does not, nothing says so. The nft rule
# matches, the counter increments, the packet is marked and routed to the
# local table -- and then it is dropped on the floor. Conntrack sits at
# SYN_SENT [UNREPLIED], the listener sees nothing, the client hangs. Every
# individual piece of the configuration looks correct, which is what makes it
# expensive to diagnose by hand.
#
# So test it directly, against a listener that is known good: if socat with
# ip-transparent does not receive the connection, no proxy will either, and
# the answer is to pick a mode that does not rely on TPROXY.
#
# Nothing here is persistent: a temporary nft table, a temporary netns and a
# veth pair, all removed on exit.

. /lib/functions.sh

NAME="clashwrt-selftest"
NS=clashwrt_st
TABLE="inet clashwrt_st"
PORT=7799
CLIENT=192.168.1.250
MARK=0x51
RT_TABLE=155
RT_PREF=12345

config_load clashwrt
config_get LAN_IF config lan_device br-lan

GW=$(ip -o -4 addr show "$LAN_IF" 2>/dev/null | awk '{print $4}' | cut -d/ -f1)
[ -n "$GW" ] || { echo "no IPv4 address on $LAN_IF -- set lan_device correctly" >&2; exit 2; }

if ! command -v socat >/dev/null 2>&1; then
	echo "socat is required for this test but is not installed." >&2
	echo "Install it (apk add socat) and run again." >&2
	exit 2
fi

cleanup() {
	nft delete table $TABLE 2>/dev/null
	ip netns del $NS 2>/dev/null
	ip link del veth-sts 2>/dev/null
	[ -n "${SOCAT:-}" ] && kill "$SOCAT" 2>/dev/null
	ip rule del fwmark $MARK table $RT_TABLE pref $RT_PREF 2>/dev/null
	ip route flush table $RT_TABLE 2>/dev/null
	rm -f /tmp/clashwrt_st.http /tmp/clashwrt_st.out /tmp/clashwrt_st.hits
}
trap cleanup EXIT
cleanup

# marked traffic must be delivered locally for a transparent socket to see it
sysctl -qw net.ipv4.conf.all.route_localnet=1 2>/dev/null
ip route replace local default dev lo table $RT_TABLE
ip rule add fwmark $MARK table $RT_TABLE pref $RT_PREF

printf 'HTTP/1.0 200 OK\r\nContent-Length: 4\r\nConnection: close\r\n\r\nYES\n' > /tmp/clashwrt_st.http
: > /tmp/clashwrt_st.hits

# Each accepted connection appends one marker line. Counting socat's own
# output instead would count its warnings as if they were connections.
socat "TCP4-LISTEN:$PORT,bind=127.0.0.1,ip-transparent,reuseaddr,fork" \
	SYSTEM:'cat /tmp/clashwrt_st.http; echo hit >> /tmp/clashwrt_st.hits' \
	> /tmp/clashwrt_st.out 2>&1 &
SOCAT=$!
sleep 1

# sanity: if the listener does not answer a direct connection, the test itself
# is broken and its verdict would be meaningless
DIRECT=$(curl -s -m4 -o /dev/null -w '%{http_code}' "http://127.0.0.1:$PORT/" 2>/dev/null)
if [ "$DIRECT" != "200" ]; then
	echo "listener does not answer directly (rc=$DIRECT) -- test inconclusive" >&2
	exit 2
fi
# that sanity connection counts as a hit; start the real measurement from zero
: > /tmp/clashwrt_st.hits

nft add table $TABLE
nft add chain $TABLE pre "{ type filter hook prerouting priority mangle ; }"
nft add rule $TABLE pre ip saddr $CLIENT tcp dport 80 \
	meta mark set $MARK counter tproxy ip to "127.0.0.1:$PORT" accept

# a fake LAN client, so the packet is genuinely forwarded through prerouting
ip netns add $NS
ip link add veth-stc type veth peer name veth-sts
ip link set veth-sts master "$LAN_IF"; ip link set veth-sts up
ip link set veth-stc netns $NS
ip netns exec $NS ip link set lo up
ip netns exec $NS ip addr add "$CLIENT/24" dev veth-stc
ip netns exec $NS ip link set veth-stc up
ip netns exec $NS ip route add default via "$GW"
sleep 1

RC=$(ip netns exec $NS curl -s -m6 -o /dev/null -w '%{http_code}' http://9.9.9.9/ 2>/dev/null)
CNT=$(nft list chain $TABLE pre | grep -o 'counter packets [0-9]*' | awk '{print $3}')
GOT=$(grep -c . /tmp/clashwrt_st.hits 2>/dev/null)

echo "tproxy rule matched : ${CNT:-0} packets"
echo "socket received     : ${GOT:-0}"
echo "client result       : rc=$RC"
echo

if [ "$RC" = "200" ] && [ "${GOT:-0}" -ge 1 ]; then
	echo "PASS -- the kernel delivers TPROXY to transparent sockets."
	echo "Recommended mode: tproxy"
	exit 0
fi

if [ "${CNT:-0}" -ge 1 ]; then
	echo "FAIL -- the rule matches but the socket never receives the connection."
	echo "This kernel cannot be used with TPROXY, no matter how it is configured."
	echo "Recommended mode: redirect_tun (or tun)"
	exit 1
fi

echo "FAIL -- the rule never matched; traffic is not reaching the test chain."
echo "Check that lan_device ($LAN_IF) is correct and that $CLIENT is free."
exit 1
