#!/bin/sh
# dns.nftset: under meow-openwrt and 'include', the core fills bypass4_dns from
# its own DNS answers. fw.sh writes the key into config.yaml's dns: block and
# takes it out again; setctl.sh stops holding the set back for domains the
# core judges itself, and stops writing dnsmasq domain rules.
T="$(cd "$(dirname "$0")" && pwd)"
. "$T/lib.sh"
LIBEXEC="$T/../clashwrt/files/usr/libexec/clashwrt"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

mkdir -p "$TMP/db" "$TMP/bin" "$TMP/state" "$TMP/mihomo" "$TMP/usrbin"
cp "$T"/shim/uci "$T"/shim/logger "$TMP/bin/"
printf '#!/bin/sh\nexit 1\n' > "$TMP/bin/pidof"
printf '#!/bin/sh\necho "Dnsmasq version 2.90 no-nftset"\n' > "$TMP/bin/dnsmasq"
chmod +x "$TMP"/bin/*

export PATH="$TMP/bin:$PATH" UCI_DB="$TMP/db" LOGGER_OUT="$TMP/logger.log" \
	CLASHWRT_FUNCTIONS="$T/shim/functions.sh" CLASHWRT_NETWORK="$T/shim/network.sh" \
	CLASHWRT_LIBEXEC="$LIBEXEC" CLASHWRT_STATE_DIR="$TMP/state" CLASHWRT_BIN_DIR="$TMP/usrbin"

CONF="$TMP/mihomo/config.yaml"
uci set "clashwrt.config.mihomo_dir=$TMP/mihomo"
uci set clashwrt.config.bypass_set_mode=auto
uci set clashwrt.config.bypass_set_source=config
uci set clashwrt.config.mode=tproxy

gen() {
	node -e '
		var gen = require(process.argv[1] + "/loadjs").gen();
		process.stdout.write(gen.generate(JSON.parse(process.argv[2])));
	' "$T" "$1"
}
direction() { sh "$LIBEXEC/setctl.sh" direction 2>/dev/null; }

# --- setctl.sh: who fills the set --------------------------------------------

gen '{"proxies":[],"mode":"tproxy","routing":"direct_except_list","ruleSets":["telegram","youtube"]}' > "$CONF"

sed -i 's/^  - MATCH,DIRECT$/  - DOMAIN-SUFFIX,example.com,Proxy\n  - MATCH,DIRECT/' "$CONF"
eq "mihomo, no dnsmasq-full: domains cannot be filled, the set is held" off "$(direction)"
sh "$LIBEXEC/setctl.sh" from-config >/dev/null 2>&1
eq "mihomo: the config's domains are kept for dnsmasq" 1 "$(cat "$TMP/state/config-domains.list" 2>/dev/null | grep -c .)"
ln -s "$TMP/usrbin/meow" "$TMP/usrbin/mihomo"
eq "meow fills them itself: include" include "$(direction)"
sh "$LIBEXEC/setctl.sh" from-config >/dev/null 2>&1
[ -f "$TMP/state/config4.list" ] && pass "the config was parsed" || fail "the config was parsed"
eq "no domain list kept: the core judges them" 0 "$(cat "$TMP/state/config-domains.list" 2>/dev/null | grep -c .)"
out="$(sh "$LIBEXEC/setctl.sh" status 2>/dev/null)"
case "$out" in *"judged by meow-openwrt itself"*) pass "status says who fills it" ;; *) fail "status says who fills it ($out)" ;; esac

# a rule no DNS answer can stand for still holds it back
sed -i 's/^  - MATCH,DIRECT$/  - DST-PORT,8443,Proxy\n  - MATCH,DIRECT/' "$CONF"
eq "a port rule holds it back under meow too" off "$(direction)"

# --- fw.sh: the dns: block -----------------------------------------------------

# shellcheck source=/dev/null
CLASHWRT_TEST=1 . "$LIBEXEC/fw.sh"

printf 'mode: rule\ndns:\n  enable: true\n  listen: 0.0.0.0:1053\n  nameserver:\n    - 9.9.9.9\nrules:\n  - MATCH,DIRECT\n' > "$TMP/a.yaml"
nftset_rewrite "$TMP/a.yaml" on > "$TMP/on.yaml"
grep -qx '  nftset:' "$TMP/on.yaml" && grep -qx '    ipv4: inet#clashwrt#bypass4_dns' "$TMP/on.yaml" &&
	pass "the key goes into dns:, at its indent" || fail "the key goes into dns: ($(cat "$TMP/on.yaml"))"
awk '/^dns:/{d=1;next} /^[a-z]/{d=0} d && /nftset:/{f=1} END{exit !f}' "$TMP/on.yaml" && pass "inside the dns: block" || fail "inside the dns: block"
grep -qx '    - 9.9.9.9' "$TMP/on.yaml" && grep -qx 'rules:' "$TMP/on.yaml" && pass "the rest is kept" || fail "the rest is kept"
nftset_rewrite "$TMP/on.yaml" on > "$TMP/on2.yaml"
cmp -s "$TMP/on.yaml" "$TMP/on2.yaml" && pass "written once" || fail "written once ($(cat "$TMP/on2.yaml"))"
nftset_rewrite "$TMP/on.yaml" off > "$TMP/off.yaml"
cmp -s "$TMP/a.yaml" "$TMP/off.yaml" && pass "taken out without a trace" || fail "taken out without a trace ($(diff "$TMP/a.yaml" "$TMP/off.yaml"))"

printf 'dns:\n  enable: true\n  nftset:\n    ipv4: inet#fw4#mine\nrules: []\n' > "$TMP/u.yaml"
nftset_rewrite "$TMP/u.yaml" off > "$TMP/u2.yaml"
cmp -s "$TMP/u.yaml" "$TMP/u2.yaml" && pass "a user's own nftset stays" || fail "a user's own nftset stays ($(cat "$TMP/u2.yaml"))"

finish
