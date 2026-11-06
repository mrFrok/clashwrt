#!/bin/sh
# config.yaml keeps only the inbounds of the interception mode: fw.sh comments
# out the ports a mode does not use (keeping their numbers) and switches the
# tun off, and puts them back when the mode changes again.
T="$(cd "$(dirname "$0")" && pwd)"
. "$T/lib.sh"
LIBEXEC="$T/../clashwrt/files/usr/libexec/clashwrt"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

# shellcheck source=/dev/null
export CLASHWRT_FUNCTIONS="$T/shim/functions.sh" CLASHWRT_NETWORK="$T/shim/network.sh" CLASHWRT_LIBEXEC="$LIBEXEC"
CLASHWRT_TEST=1 . "$LIBEXEC/fw.sh"
tun_device=clash-tun

cat > "$TMP/c.yaml" <<'Y'
mixed-port: 7890
tproxy-port: 7000
redir-port: 7001
routing-mark: 2
tun:
  enable: true
  device: clash-tun
  stack: system
  auto-route: false
dns:
  enable: true
Y

run() { mode="$1"; inbound_rewrite "$2" "$(inbound_wants)"; }
key() { grep -x "$1" "$2" >/dev/null; }
tun_en() { awk '/^tun:/{t=1;next} /^[a-z]/{t=0} t && /^  enable:/{print $2}' "$1"; }

run tproxy "$TMP/c.yaml" > "$TMP/tp.yaml"
key 'tproxy-port: 7000' "$TMP/tp.yaml" && pass "tproxy: tproxy-port kept" || fail "tproxy: tproxy-port kept"
key '# ClashWrt-off: redir-port: 7001' "$TMP/tp.yaml" && pass "tproxy: redir-port commented, number kept" || fail "tproxy: redir-port commented ($(cat "$TMP/tp.yaml"))"
eq "tproxy: tun off" false "$(tun_en "$TMP/tp.yaml")"
key 'mixed-port: 7890' "$TMP/tp.yaml" && key '  stack: system' "$TMP/tp.yaml" && key 'dns:' "$TMP/tp.yaml" && pass "the rest is kept" || fail "the rest is kept"

run redirect_tun "$TMP/tp.yaml" > "$TMP/rt.yaml"
key 'redir-port: 7001' "$TMP/rt.yaml" && pass "redirect_tun: redir-port back, same number" || fail "redirect_tun: redir-port back ($(cat "$TMP/rt.yaml"))"
key '# ClashWrt-off: tproxy-port: 7000' "$TMP/rt.yaml" && pass "redirect_tun: tproxy-port commented" || fail "redirect_tun: tproxy-port commented"
eq "redirect_tun: tun on" true "$(tun_en "$TMP/rt.yaml")"

run tun "$TMP/rt.yaml" > "$TMP/t.yaml"
eq "tun: no port left" 0 "$(grep -cE '^(tproxy|redir)-port:' "$TMP/t.yaml")"
eq "tun: tun on" true "$(tun_en "$TMP/t.yaml")"

run tproxy_tun "$TMP/t.yaml" > "$TMP/tt.yaml"
run tproxy_tun "$TMP/tt.yaml" > "$TMP/tt2.yaml"
cmp -s "$TMP/tt.yaml" "$TMP/tt2.yaml" && pass "written once" || fail "written once"

run auto_redirect "$TMP/tt.yaml" > "$TMP/ar.yaml"
eq "auto_redirect: no port, tun left to core-sync" "0 true" "$(grep -cE '^(tproxy|redir)-port:' "$TMP/ar.yaml") $(tun_en "$TMP/ar.yaml")"

# back to where it started: nothing lost on the way
run tproxy "$TMP/c.yaml" > "$TMP/a"; run redirect_tun "$TMP/a" > "$TMP/b"; run tproxy "$TMP/b" > "$TMP/c"
cmp -s "$TMP/a" "$TMP/c" && pass "a round trip changes nothing" || fail "a round trip ($(diff "$TMP/a" "$TMP/c"))"

# a hand-written config without the port or the tun the mode needs
printf 'mixed-port: 7890\nrouting-mark: 2\n' > "$TMP/h.yaml"
run tproxy "$TMP/h.yaml" > "$TMP/h1.yaml"
key 'tproxy-port: 7894' "$TMP/h1.yaml" && pass "a missing port is added (generator default)" || fail "missing port added ($(cat "$TMP/h1.yaml"))"
run redirect_tun "$TMP/h.yaml" > "$TMP/h2.yaml"
key 'redir-port: 7893' "$TMP/h2.yaml" && eq "a missing tun is added, on" true "$(tun_en "$TMP/h2.yaml")" || fail "missing tun added"
printf 'tun:\n  device: clash-tun\n  stack: system\nrules: []\n' > "$TMP/n.yaml"
run tproxy "$TMP/n.yaml" > "$TMP/n1.yaml"
eq "a tun without enable gets enable: false" false "$(tun_en "$TMP/n1.yaml")"

finish
