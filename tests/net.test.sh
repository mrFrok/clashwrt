#!/bin/sh
# net.sh: downloads go through mihomo's fetch listener first, the config's
# own proxy port second, and directly when there is no proxy or it fails.
T="$(cd "$(dirname "$0")" && pwd)"
. "$T/lib.sh"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

mkdir -p "$TMP/bin" "$TMP/db" "$TMP/mihomo"
cp "$T"/shim/uci "$TMP/bin/"
# curl: records its proxy, fails through it when PROXY_FAILS is set, and
# prints a partial answer first so a leak into the output would show
cat > "$TMP/bin/curl" <<'X'
#!/bin/sh
p=direct
[ "$1" = --proxy ] && { p="$2"; shift 2; }
echo "$p" >> "$CURL_LOG"
if [ "$p" != direct ] && [ -n "$PROXY_FAILS" ]; then echo partial; exit 7; fi
echo "answer via $p"
X
printf '#!/bin/sh\n[ -e "$MIHOMO_UP" ]\n' > "$TMP/bin/pidof"
chmod +x "$TMP/bin/"*
export PATH="$TMP/bin:$PATH" UCI_DB="$TMP/db" CURL_LOG="$TMP/curl.log" MIHOMO_UP="$TMP/up"
uci set "clashwrt.config.mihomo_dir=$TMP/mihomo"
: > "$TMP/up"

# shellcheck source=../clashwrt/files/usr/libexec/clashwrt/net.sh
. "$T/../clashwrt/files/usr/libexec/clashwrt/net.sh"
logger() { :; }

cat > "$TMP/mihomo/config.yaml" <<'Y'
mixed-port: 7890
listeners:
  - name: other
    type: socks
    port: 1080
  - name: clashwrt-fetch
    type: mixed
    port: 7899
    listen: 127.0.0.1
    proxy: Proxy
rules:
  - MATCH,DIRECT
Y
eq "the fetch listener comes first" "socks5h://127.0.0.1:7899" "$(cw_proxy_url)"
eq "and the answer comes through it" "answer via socks5h://127.0.0.1:7899" "$(cw_curl -sS https://x)"

: > "$CURL_LOG"
eq "a failed proxy falls back, with nothing of it in the output" "answer via direct" "$(PROXY_FAILS=1 cw_curl -sS https://x)"
eq "proxy tried, then direct" "socks5h://127.0.0.1:7899|direct" "$(tr '\n' '|' < "$CURL_LOG" | sed 's/|$//')"

printf 'mixed-port: 7890\nrules:\n  - MATCH,DIRECT\n' > "$TMP/mihomo/config.yaml"
eq "without the listener, mixed-port" "socks5h://127.0.0.1:7890" "$(cw_proxy_url)"
printf 'socks-port: 7891\n' > "$TMP/mihomo/config.yaml"
eq "or socks-port" "socks5h://127.0.0.1:7891" "$(cw_proxy_url)"
printf 'rules:\n  - MATCH,DIRECT\n' > "$TMP/mihomo/config.yaml"
eq "no proxy port: direct" "answer via direct" "$(cw_curl -sS https://x)"

printf 'mixed-port: 7890\n' > "$TMP/mihomo/config.yaml"
rm -f "$TMP/up"
eq "mihomo not running: direct" "answer via direct" "$(cw_curl -sS https://x)"
: > "$TMP/up"
uci set clashwrt.config.fetch_via_proxy=0
eq "fetch_via_proxy off: direct" "answer via direct" "$(cw_curl -sS https://x)"

finish
