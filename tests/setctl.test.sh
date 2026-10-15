#!/bin/sh
# setctl.sh: the bypass set takes what config.yaml's own rules name, the way
# round its MATCH rule says, and hands domains to dnsmasq only when it can.
T="$(cd "$(dirname "$0")" && pwd)"
. "$T/lib.sh"
SETCTL="$T/../clashwrt/files/usr/libexec/clashwrt/setctl.sh"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

mkdir -p "$TMP/db" "$TMP/bin" "$TMP/state" "$TMP/mihomo/providers" "$TMP/dnsmasq.d"
cp "$T"/shim/uci "$T"/shim/logger "$TMP/bin/"
cat > "$TMP/bin/nft" <<'X'
#!/bin/sh
case "$1" in
	list) exit 0 ;;
	-f) cp "$2" "$NFT_LOADED" ;;
esac
X
cat > "$TMP/bin/dnsmasq" <<'X'
#!/bin/sh
echo "Compile time options: IPv6 GNU-getopt no-DBus UBus no-ipset ${NFTSET:-no-nftset} auth"
X
chmod +x "$TMP"/bin/*

export PATH="$TMP/bin:$PATH" UCI_DB="$TMP/db" LOGGER_OUT="$TMP/logger.log" NFT_LOADED="$TMP/loaded" \
	CLASHWRT_FUNCTIONS="$T/shim/functions.sh" CLASHWRT_STATE_DIR="$TMP/state"

uci set "dhcp.@dnsmasq[0].confdir=$TMP/dnsmasq.d"
uci set "clashwrt.config.mihomo_dir=$TMP/mihomo"
uci set clashwrt.config.bypass_set_mode=auto
uci set clashwrt.config.bypass_set_source=config

cat > "$TMP/mihomo/config.yaml" <<'Y'
rule-providers:
  blocked:
    type: http
    behavior: ipcidr
    path: ./providers/blocked.txt
  ai: { type: http, behavior: domain, path: ./providers/ai.yaml }
  bin:
    behavior: domain
    format: mrs
    path: ./providers/b.mrs
rules:
  - DOMAIN-SUFFIX,lan,DIRECT
  - IP-CIDR,192.168.0.0/16,DIRECT,no-resolve
  - DOMAIN-SUFFIX,chatgpt.com,Proxy
  - DOMAIN,Gemini.Google.com,"Auto Select"
  - IP-CIDR,91.108.4.0/22,Proxy,no-resolve   # a comment
  - IP-CIDR,999.1.1.1/8,Proxy
  - RULE-SET,blocked,Proxy
  - RULE-SET,ai,Proxy
  - RULE-SET,bin,Proxy
  - MATCH,DIRECT
Y
printf '1.2.3.0/24\n0.0.0.0/0\n1.2.3.4/33\n' > "$TMP/mihomo/providers/blocked.txt"
printf 'payload:\n  - "+.claude.ai"\n  - "*.bad*wild.com"\n' > "$TMP/mihomo/providers/ai.yaml"

loaded() { sed -n 's/^  \([0-9./]*\),*$/\1/p' "$NFT_LOADED" | tr '\n' ' ' | sed 's/ $//'; }
nftset() { [ -e "$TMP/dnsmasq.d/clashwrt-nftset.conf" ] && sed 's/^nftset=\/\([^/]*\)\/.*/\1/' "$TMP/dnsmasq.d/clashwrt-nftset.conf" | tr '\n' ' ' | sed 's/ $//'; }

sh "$SETCTL" load
eq "include takes proxied addresses, providers included, bad CIDRs dropped" \
	"91.108.4.0/22 1.2.3.0/24" "$(loaded)"
eq "no dnsmasq-full, no domain rules" "" "$(nftset)"
case "$(sh "$SETCTL" status)" in
	*"install dnsmasq-full"*) pass "status says what is missing for domains" ;;
	*) fail "status says what is missing for domains" ;;
esac
case "$(sh "$SETCTL" from-config)" in
	*"rule-set bin is in the binary mrs format"*) pass "mrs providers are reported, not guessed" ;;
	*) fail "mrs providers are reported, not guessed" ;;
esac

NFTSET=nftset sh "$SETCTL" load
eq "dnsmasq-full gets the proxied domains, lower-cased" \
	"chatgpt.com gemini.google.com claude.ai" "$(nftset)"

uci set clashwrt.config.dns_hijack=1
NFTSET=nftset sh "$SETCTL" load
eq "with DNS hijack dnsmasq never sees the lookups, so no domain rules" "" "$(nftset)"
uci set clashwrt.config.dns_hijack=0

sed -i 's/MATCH,DIRECT/MATCH,Proxy/' "$TMP/mihomo/config.yaml"
uci set clashwrt.config.bypass_set_source=ru
printf '77.88.0.0/18\n' > "$TMP/state/bypass4.list"
NFTSET=nftset sh "$SETCTL" load
eq "exclude: the list plus DIRECT addresses before the first proxied rule" \
	"77.88.0.0/18 192.168.0.0/16" "$(loaded)"
eq "exclude never hands domains to dnsmasq" "" "$(nftset)"

uci set clashwrt.config.bypass_set_from_config=0
sh "$SETCTL" load
eq "from_config off: the list alone" "77.88.0.0/18" "$(loaded)"
uci set clashwrt.config.bypass_set_from_config=1

# a compound rule that proxies part of 10/8 must stop the later DIRECT rule
# from taking all of 10/8 out of mihomo
cat > "$TMP/mihomo/config.yaml" <<'Y'
rules:
  - AND,((IP-CIDR,10.0.0.0/8),(DST-PORT,443)),Proxy
  - IP-CIDR,10.0.0.0/8,DIRECT
  - MATCH,Proxy
Y
sh "$SETCTL" load
eq "exclude: a proxied compound rule closes the DIRECT run" "77.88.0.0/18" "$(loaded)"

# providers outside mihomo's directory are not read
cat > "$TMP/mihomo/config.yaml" <<'Y'
rule-providers:
  out: { behavior: ipcidr, path: /etc/passwd }
  up: { behavior: ipcidr, path: ../../x }
rules:
  - RULE-SET,out,Proxy
  - RULE-SET,up,Proxy
  - IP-CIDR,010.1.2.0/24,Proxy
  - MATCH,DIRECT
Y
uci set clashwrt.config.bypass_set_source=config
sh "$SETCTL" load
eq "include: leading zeros normalised, outside paths ignored" "10.1.2.0/24" "$(loaded)"
case "$(sh "$SETCTL" from-config)" in
	*"out is outside"*"up has no usable path"*|*"up has no usable path"*"out is outside"*) pass "outside paths are reported" ;;
	*) fail "outside paths are reported" ;;
esac

# an include set that comes out empty keeps what was loaded
printf 'rules:\n  - MATCH,DIRECT\n' > "$TMP/mihomo/config.yaml"
rm -f "$NFT_LOADED"
sh "$SETCTL" load
eq "include: an empty result is not loaded" "no" "$([ -e "$NFT_LOADED" ] && echo yes || echo no)"

# switching off takes the dnsmasq rules away
printf 'rules:\n  - DOMAIN-SUFFIX,chatgpt.com,Proxy\n  - MATCH,DIRECT\n' > "$TMP/mihomo/config.yaml"
NFTSET=nftset sh "$SETCTL" load
eq "domain rules present before off" "chatgpt.com" "$(nftset)"
uci set clashwrt.config.bypass_set_mode=off
NFTSET=nftset sh "$SETCTL" load
eq "off removes the dnsmasq rules" "" "$(nftset)"

finish
