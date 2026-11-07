#!/bin/sh
# Mode auto_redirect: meow-openwrt captures by itself. setctl.sh core-routes
# turns the config's rules into the core's tun keys, fw.sh writes them into
# config.yaml's tun: block (and takes them out again), points dnsmasq at the
# core for route-address-dns and switches the capture through the API.
T="$(cd "$(dirname "$0")" && pwd)"
. "$T/lib.sh"
LIBEXEC="$T/../clashwrt/files/usr/libexec/clashwrt"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

mkdir -p "$TMP/db" "$TMP/run" "$TMP/bin" "$TMP/rcd" "$TMP/state" "$TMP/mihomo"
cp "$T"/shim/uci "$T"/shim/logger "$TMP/bin/"
cat > "$TMP/bin/nft" <<'X'
#!/bin/sh
echo "nft $*" >> "$NFT_LOG"
if [ "$1 $2" = "list tables" ]; then
	[ -e "$MEOW_TABLE" ] && echo "table inet meow"
	[ -e "$NFT_TABLE" ] && echo "table inet clashwrt"
fi
exit 0
X
cat > "$TMP/bin/curl" <<'X'
#!/bin/sh
echo "curl $*" >> "$CURL_LOG"
X
cat > "$TMP/bin/pidof" <<'X'
#!/bin/sh
[ -e "$CORE_UP" ]
X
cat > "$TMP/bin/dnsmasq-init" <<'X'
#!/bin/sh
echo "$*" >> "$DNSMASQ_LOG"
X
cat > "$TMP/bin/confctl" <<'X'
#!/bin/sh
[ "$1" = check-file ] && [ ! -e "$CONF_BAD" ]
X
printf '#!/bin/sh\nexit 0\n' > "$TMP/bin/sleep"
chmod +x "$TMP"/bin/*
ln -s "$TMP/meow" "$TMP/mihomo-bin"

export PATH="$TMP/bin:$PATH" UCI_DB="$TMP/db" NFT_LOG="$TMP/nft.log" NFT_TABLE="$TMP/table" \
	MEOW_TABLE="$TMP/meowtable" CURL_LOG="$TMP/curl.log" CORE_UP="$TMP/coreup" CONF_BAD="$TMP/bad" \
	DNSMASQ_LOG="$TMP/dnsmasq.log" LOGGER_OUT="$TMP/logger.log" \
	CLASHWRT_TEST=1 CLASHWRT_FUNCTIONS="$T/shim/functions.sh" CLASHWRT_NETWORK="$T/shim/network.sh" \
	CLASHWRT_RUNDIR="$TMP/run" CLASHWRT_RCD="$TMP/rcd" CLASHWRT_LIBEXEC="$LIBEXEC" \
	CLASHWRT_STATE_DIR="$TMP/state" CLASHWRT_SETCTL="$LIBEXEC/setctl.sh" \
	CLASHWRT_DNS_BAK="$TMP/dns.bak" CLASHWRT_DNSMASQ_INIT="$TMP/bin/dnsmasq-init" \
	CLASHWRT_DNS_CORE="$TMP/dns-core.state" CLASHWRT_CONFCTL="$TMP/bin/confctl" \
	CLASHWRT_CORE_BIN="$TMP/mihomo-bin" CLASHWRT_MEOW_BIN="$TMP/meow" CLASHWRT_CORE_INIT="$TMP/bin/dnsmasq-init"

CONF="$TMP/mihomo/config.yaml"
uci set "clashwrt.config.mihomo_dir=$TMP/mihomo"
uci set clashwrt.config.bypass_set_mode=auto
uci set clashwrt.config.bypass_set_source=config
uci set clashwrt.config.mode=auto_redirect

# configs as the wizard writes them
gen() {
	node -e '
		var gen = require(process.argv[1] + "/loadjs").gen();
		process.stdout.write(gen.generate(JSON.parse(process.argv[2])));
	' "$T" "$1"
}
routes() { env -u CLASHWRT_TEST sh "$LIBEXEC/setctl.sh" core-routes 2>>"$TMP/err"; }

# --- setctl.sh core-routes ---------------------------------------------------

gen '{"proxies":[],"mode":"auto_redirect","routing":"proxy_except_ru","secret":"s3cr3t","tunDevice":"clash-tun"}' > "$CONF"
r="$(routes)"
eq "proxy except Russia: exclude" "direction: exclude" "$(echo "$r" | head -n1)"
echo "$r" | grep -qx 'exclude_set: ru_ips' && pass "Russian addresses skip the core by provider name" || fail "ru_ips excluded ($r)"
echo "$r" | grep -qx 'exclude_net: 10.0.0.0/8' && pass "private DIRECT rules excluded" || fail "private nets excluded"
echo "$r" | grep -q 'route_dns\|held' && fail "exclude never narrows by DNS" || pass "exclude never narrows by DNS"

gen '{"proxies":[],"mode":"auto_redirect","routing":"direct_except_list","ruleSets":["telegram","youtube"],"udpSplit":true}' > "$CONF"
r="$(routes)"
eq "direct except the lists: include" "direction: include" "$(echo "$r" | head -n1)"
echo "$r" | grep -qx 'route_set: geoip_telegram' && pass "ipcidr provider captured by name (bare addresses)" || fail "geoip_telegram routed ($r)"
echo "$r" | grep -qx 'route_dns: 1' && pass "domains captured from DNS answers" || fail "route_dns ($r)"
echo "$r" | grep -q 'geosite_youtube' && fail "domain sets are DNS's job" || pass "domain sets are DNS's job"
echo "$r" | grep -q '^held' && fail "AND((NETWORK,udp),(RULE-SET,...)) is narrowed by its set" || pass "AND((NETWORK,udp),(RULE-SET,...)) is narrowed by its set"

gen '{"proxies":[],"mode":"auto_redirect","routing":"direct_except_list","ruleSets":["telegram"],"fakeIp":true}' > "$CONF"
routes | grep -qx 'route_net: 198.18.0.1/16' && pass "fake-ip range is always captured" || fail "fake-ip range captured"

# a proxying rule no address or DNS answer can stand for: capture everything
sed -i 's/^  - MATCH,DIRECT$/  - DST-PORT,8443,Proxy\n  - MATCH,DIRECT/' "$CONF"
r="$(routes)"
echo "$r" | grep -q '^held: DST-PORT rules' && pass "a port rule holds the narrowing back" || fail "port rule held ($r)"
echo "$r" | grep -q 'route_' && fail "held: no route keys" || pass "held: no route keys"
sed -i 's/^  - DST-PORT,8443,Proxy$/  - NOT,((DOMAIN,example.com)),Proxy/' "$CONF"
routes | grep -q '^held: NOT rules' && pass "NOT holds it back too" || fail "NOT held"

uci set clashwrt.config.bypass_set_mode=off
eq "bypass off: no narrowing" "direction: off" "$(routes)"
uci set clashwrt.config.bypass_set_mode=auto

# --- fw.sh: the tun: block ---------------------------------------------------

# shellcheck source=/dev/null
. "$LIBEXEC/fw.sh"
cfg() { load_cfg; resolve_ports; }

gen '{"proxies":[],"mode":"auto_redirect","routing":"direct_except_list","ruleSets":["telegram"],"secret":"s3cr3t","tunDevice":"clash-tun"}' > "$CONF"
cp "$CONF" "$TMP/orig.yaml"
uci set clashwrt.config.block_dot=1
uci add_list clashwrt.config.doh_extra=203.0.113.53
cfg
CORE_ROUTES="$(routes)"
core_conf_sync on >/dev/null
tun="$(awk '/^tun:/{t=1;print;next} /^[a-z]/{t=0} t' "$CONF")"
echo "$tun" | grep -qx '  auto-route: true' && pass "auto-route on" || fail "auto-route on"
echo "$tun" | grep -qx '  auto-redirect: true' && pass "auto-redirect on" || fail "auto-redirect on"
eq "the generator's false values are gone" "0" "$(echo "$tun" | grep -c 'auto-redirect: false\|auto-route: false')"
echo "$tun" | grep -qx "  route-address-set: \['geoip_telegram'\]" && pass "route-address-set written" || fail "route-address-set ($tun)"
echo "$tun" | grep -qx '  route-address-dns: true' && pass "route-address-dns written" || fail "route-address-dns"
echo "$tun" | grep -q "^  route-exclude-address: \['0.0.0.0/8', '10.0.0.0/8'" && pass "bypass_net excluded" || fail "bypass_net excluded"
echo "$tun" | grep -qx "  dns-hijack: \[\]" && pass "LAN DNS stays with dnsmasq" || fail "dns-hijack off"
echo "$tun" | grep -qx "  block-encrypted-dns-address: \['203.0.113.53'\]" && pass "DoT/DoH blocked by the core, doh_extra too" || fail "block-encrypted-dns"
echo "$tun" | grep -qx '  device: clash-tun' && pass "the block's own keys stay" || fail "device kept"
eq "one enable" "1" "$(echo "$tun" | grep -c '^  enable:')"
grep -q '^sniffer:' "$CONF" && pass "the next section is untouched" || fail "next section"
grep -q "PUT /configs" "$CURL_LOG" 2>/dev/null && fail "core not running: no reload" || pass "core not running: no reload"

cp "$CONF" "$TMP/once.yaml"
touch "$CORE_UP"
core_conf_sync on >/dev/null
cmp -s "$CONF" "$TMP/once.yaml" && pass "idempotent" || fail "idempotent"
grep -q "PUT" "$CURL_LOG" 2>/dev/null && fail "unchanged: no reload" || pass "unchanged: no reload"

uci set clashwrt.config.dns_hijack=1; cfg
core_conf_sync on >/dev/null
grep -q -- "-X PUT .*http://127.0.0.1:9090/configs?force=true" "$CURL_LOG" && pass "a change reloads the core" || fail "reload ($(cat "$CURL_LOG"))"
grep -q "Authorization: Bearer s3cr3t" "$CURL_LOG" && pass "with the secret" || fail "secret"
grep -qx "  dns-hijack: \['any:53'\]" "$CONF" && pass "dns_hijack: the core takes port 53" || fail "dns-hijack on"
uci set clashwrt.config.dns_hijack=0; cfg

: > "$TMP/bad"; cp "$CONF" "$TMP/before.yaml"
uci set clashwrt.config.block_dot=0; cfg
core_conf_sync on >/dev/null 2>&1 && fail "a rejected rewrite fails" || pass "a rejected rewrite fails"
cmp -s "$CONF" "$TMP/before.yaml" && pass "and leaves config.yaml alone" || fail "config left alone"
rm -f "$TMP/bad"

core_conf_sync off >/dev/null
grep -q 'ClashWrt: from here' "$CONF" && fail "off: marker gone" || pass "off: marker gone"
awk '/^tun:/{t=1;next} /^[a-z]/{t=0} t' "$CONF" | grep -q 'route-\|block-encrypted\|dns-hijack' &&
	fail "off: no capture keys" || pass "off: no capture keys"
grep -qx '  auto-route: false' "$CONF" && pass "off: auto-route false again" || fail "off: auto-route false"
cp "$CONF" "$TMP/off.yaml"
core_conf_sync off >/dev/null
cmp -s "$CONF" "$TMP/off.yaml" && pass "off without the marker: untouched" || fail "off untouched"

# a hand-written block: four spaces, a list under a managed key, a comment
cat > "$CONF" <<'Y'
routing-mark: 2
tun:
    enable: true
    device: clash-tun
    route-address:
        - 1.1.1.1/32
    # mine
    stack: system

dns:
    enable: true
Y
core_conf_sync on >/dev/null
awk '/^tun:/{t=1;next} /^[a-z]/{t=0} t' "$CONF" > "$TMP/tun"
grep -q '1.1.1.1' "$TMP/tun" && fail "a managed key's list goes with it" || pass "a managed key's list goes with it"
grep -qx '    auto-redirect: true' "$TMP/tun" && pass "the block's own indent" || fail "indent ($(cat "$TMP/tun"))"
grep -qx '    # mine' "$TMP/tun" && grep -qx '    stack: system' "$TMP/tun" && pass "the rest stays" || fail "rest stays"
eq "the blank line stays ahead of dns:" "" "$(grep -B1 '^dns:' "$CONF" | head -n1)"

# --- capture switch, dnsmasq -------------------------------------------------

: > "$CURL_LOG"
core_capture off
grep -q 'PATCH http://127.0.0.1:9090/configs -d {"tun":{"enable":false}}' "$CURL_LOG" && pass "capture off by PATCH" || fail "PATCH off ($(cat "$CURL_LOG"))"
rm -f "$CORE_UP"; : > "$CURL_LOG"
core_capture on
[ -s "$CURL_LOG" ] && fail "core down: nothing to switch" || pass "core down: nothing to switch"

: > "$CURL_LOG"; touch "$CORE_UP"
do_flush_quiet
grep -q '"enable":false' "$CURL_LOG" && pass "flush switches the core's capture off" || fail "flush capture off"

S="dhcp.@dnsmasq[0]"
uci add_list "$S.server=/lan.example/192.168.1.2"
dns_core_on
eq "dnsmasq forwards to the core" "/lan.example/192.168.1.2 127.0.0.1#1053" "$(uci get "$S.server")"
eq "and only to it" "1" "$(uci get "$S.noresolv")"
dns_core_on
eq "once" "/lan.example/192.168.1.2 127.0.0.1#1053" "$(uci get "$S.server")"
dns_core_off
eq "put back" "/lan.example/192.168.1.2" "$(uci get "$S.server")"
uci -q get "$S.noresolv" >/dev/null && fail "noresolv unset again" || pass "noresolv unset again"
uci add_list "$S.server=127.0.0.1#1053"
dns_core_on
grep -q '^server' "$TMP/dns-core.state" && fail "already forwarding: the entry is not ours" || pass "already forwarding: the entry is not ours"
dns_core_off
eq "a forward that was there stays" "/lan.example/192.168.1.2 127.0.0.1#1053" "$(uci get "$S.server")"

# another general upstream (AdGuard Home) would get some of the lookups
uci -q del_list "$S.server=127.0.0.1#1053"
uci add_list "$S.server=127.0.0.1#5335"
dns_core_on
eq "the other upstream is left out meanwhile" "/lan.example/192.168.1.2 127.0.0.1#1053" "$(uci get "$S.server")"
dns_core_off
eq "and comes back" "/lan.example/192.168.1.2 127.0.0.1#5335" "$(uci get "$S.server")"
dns_core_on
touch "$TMP/dns.bak"
dns_core_off
rm -f "$TMP/dns.bak"

# forwards for single domains to the core's port are not the general one
uci -q del_list "$S.server=127.0.0.1#5335"
uci add_list "$S.server=/gemini.google.com/127.0.0.1#1053"
dns_core_on
eq "a domain forward to the core does not stand in for the general one" \
	"/lan.example/192.168.1.2 /gemini.google.com/127.0.0.1#1053 127.0.0.1#1053" "$(uci get "$S.server")"
dns_core_off
eq "and only the general one is taken back" "/lan.example/192.168.1.2 /gemini.google.com/127.0.0.1#1053" "$(uci get "$S.server")"
uci -q del_list "$S.server=/gemini.google.com/127.0.0.1#1053"
uci add_list "$S.server=127.0.0.1#5335"
dns_core_on
touch "$TMP/dns.bak"
dns_core_off
grep -qx '127.0.0.1#5335' "$TMP/dns.bak" && pass "while the watchdog owns the list, it comes back with the list" || fail "upstream back into DNS_BAK ($(cat "$TMP/dns.bak"))"
rm -f "$TMP/dns.bak"

[ -s "$TMP/err" ] && fail "setctl.sh said: $(head -n3 "$TMP/err")"
finish
