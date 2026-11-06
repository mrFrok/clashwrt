#!/bin/sh
# apictl.sh: the LuCI Proxies page's way to the core's API.
T="$(cd "$(dirname "$0")" && pwd)"
. "$T/lib.sh"
L="$T/../clashwrt/files/usr/libexec/clashwrt"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
mkdir -p "$TMP/bin" "$TMP/db"
cp "$T"/shim/uci "$TMP/bin/"

printf "external-controller: 0.0.0.0:9090\nsecret: 's3cr\"t'\n" > "$TMP/config.yaml"
# curl: logs its arguments, one per line, and answers like the core
cat > "$TMP/bin/curl" <<'X'
#!/bin/sh
for a; do printf '%s\n' "$a"; done > "$LOG"
[ -n "$DOWN" ] && exit 7
for a; do u="$a"; done
case "$u" in
*/proxies) echo '{"proxies":{}}' ;;
*/delay*) echo '{"a":120}' ;;
esac
X
chmod +x "$TMP/bin/curl"
export PATH="$TMP/bin:$PATH" UCI_DB="$TMP/db" CLASHWRT_CONF="$TMP/config.yaml" LOG="$TMP/log"

eq "proxies" '{"proxies":{}}' "$(sh "$L/apictl.sh" proxies)"
grep -qx 'http://127.0.0.1:9090/proxies' "$LOG" && pass "0.0.0.0 is asked on 127.0.0.1" || fail "0.0.0.0 is asked on 127.0.0.1"
grep -qx 'Authorization: Bearer s3cr"t' "$LOG" && pass "with the secret" || fail "with the secret ($(cat "$LOG"))"

sh "$L/apictl.sh" select 'Авто Proxy' 'node "1"' >/dev/null
grep -qx 'http://127.0.0.1:9090/proxies/%d0%90%d0%b2%d1%82%d0%be%20%50%72%6f%78%79' "$LOG" && pass "a Cyrillic group name is encoded" || fail "a Cyrillic group name is encoded ($(cat "$LOG"))"
grep -qx '{"name":"node \\"1\\""}' "$LOG" && pass "a quote in a node name is escaped" || fail "a quote in a node name is escaped ($(cat "$LOG"))"

eq "delay" '{"a":120}' "$(sh "$L/apictl.sh" delay Proxy)"

out="$(DOWN=1 sh "$L/apictl.sh" proxies 2>&1)"; rc=$?
[ "$rc" != 0 ] && case "$out" in *"did not answer"*) true ;; *) false ;; esac && pass "a core that is down says so" || fail "a core that is down says so ($out)"

finish
