#!/bin/sh
# watchdog.sh: urlenc, and the flip logic of tick() against a stub fw.sh.
T="$(cd "$(dirname "$0")" && pwd)"
. "$T/lib.sh"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
mkdir -p "$TMP/run" "$TMP/bin" "$TMP/db"

cp "$T"/shim/uci "$T"/shim/logger "$TMP/bin/"
cat > "$TMP/fw" <<'X'
#!/bin/sh
echo "$*" >> "$FW_LOG"
case "$*" in
	"autobypass on")  mkdir -p "$CLASHWRT_RUNDIR"; : > "$CLASHWRT_RUNDIR/autobypass" ;;
	"autobypass off") rm -f "$CLASHWRT_RUNDIR/autobypass" ;;
esac
X
chmod +x "$TMP"/bin/* "$TMP/fw"

export PATH="$TMP/bin:$PATH" UCI_DB="$TMP/db" FW_LOG="$TMP/fw.log" \
	CLASHWRT_TEST=1 CLASHWRT_FUNCTIONS="$T/shim/functions.sh" CLASHWRT_RUNDIR="$TMP/run" CLASHWRT_FW="$TMP/fw"
# shellcheck source=/dev/null
. "$T/../clashwrt/files/usr/libexec/clashwrt/watchdog.sh"

# ---- urlenc ----
eq "urlenc: every byte, ascii included" "%50%72%6f%78%79" "$(urlenc Proxy)"
eq "urlenc: space" "%41%75%74%6f%20%53%65%6c%65%63%74" "$(urlenc 'Auto Select')"
eq "urlenc: cyrillic" "%d0%9f%d1%80%d0%b8" "$(urlenc 'При')"
eq "urlenc: reserved characters" "%2f%3f%26%3d%23%25" "$(urlenc '/?&=#%')"
eq "urlenc: empty" "" "$(urlenc '')"

# ---- tick ----
FLAG="$CLASHWRT_RUNDIR/autobypass"
now() { echo "$T_NOW"; }
probe_proxy() { PROBE_PX="$PX"; PROBE_WHY="why"; PROBE_DELAY=""; }
probe_wan() { [ "$WAN" = up ]; }
# a retest may heal the path: PX_AFTER, when set, is what the next probe sees
retest_groups() { RETESTS=$((RETESTS + 1)); [ -z "$PX_AFTER" ] || PX="$PX_AFTER"; }

reset() {
	rm -f "$FLAG" "$FW_LOG"
	ST=ok; ST_WHY=""; FAILS=0; OKS=0; HOLD_CUR=120; FLAPS=0; BYP_TS=0; LAST_RESTORE=0
	GRACE_UNTIL=0; T_NOW=1000; PX=fail; WAN=up; RETESTS=0; PX_AFTER=""; LAST_RETEST=-1000
	enabled=1; FAIL_N=3; OK_N=3; HOLD=120; HOLD_MAX=900; INTERVAL=20; FAST=5
}
fwcalls() { [ -e "$FW_LOG" ] && tr '\n' ',' < "$FW_LOG" || echo none; }

reset
tick; tick
eq "two failures: still failing, no bypass" "failing" "$ST"
eq "no fw call yet" "none" "$(fwcalls)"
tick
eq "third failure with WAN up: bypassed" "bypassed" "$ST"
eq "bypass went through fw.sh autobypass on" "autobypass on," "$(fwcalls)"
[ -e "$FLAG" ] && pass "flag present" || fail "flag missing"

# in bypass: oks accumulate, hold not over -> stays
PX=ok; T_NOW=1010
tick; tick; tick
eq "healthy but hold not elapsed: stays bypassed" "bypassed" "$ST"
T_NOW=1200
tick
eq "hold elapsed and OK_N passes: restored" "ok" "$ST"
eq "restore went through autobypass off" "autobypass on,autobypass off," "$(fwcalls)"
[ ! -e "$FLAG" ] && pass "flag gone" || fail "flag left"

# flap: bypass again soon after restore doubles the hold
PX=fail; T_NOW=1210
tick; tick; tick
eq "flapped back into bypass" "bypassed" "$ST"
eq "hold doubled" "240" "$HOLD_CUR"
eq "flap counted" "1" "$FLAPS"

# WAN down: never bypass
reset; WAN=down
tick; tick; tick; tick
eq "WAN down: no bypass" "wan_down" "$ST"
eq "WAN down: fw not called" "none" "$(fwcalls)"

# grace: failures during start-up are not judged
reset; GRACE_UNTIL=1100
tick; tick; tick; tick
eq "grace: not judged" "grace" "$ST"
eq "grace: fw not called" "none" "$(fwcalls)"

# skip (API unreachable by secret/group): neither fails nor oks
reset; PX=skip
tick; tick; tick; tick
eq "skip state" "skip" "$ST"
eq "skip: fw not called" "none" "$(fwcalls)"

# proxy switched off by the user: a leftover flag is lifted, nothing is bypassed
reset; : > "$FLAG"; enabled=0
tick
eq "proxy off: idle" "idle" "$ST"
eq "proxy off: leftover flag lifted" "autobypass off," "$(fwcalls)"

# a bypass switched on elsewhere is adopted, not fought
reset; : > "$FLAG"; PX=ok
tick
eq "external bypass adopted" "bypassed" "$ST"

# restored from outside (Overview's restore button)
rm -f "$FLAG"; T_NOW=1500
tick
eq "external restore noticed" "ok" "$ST"

# a dead node behind Auto: the retest moves the group, nothing is bypassed
reset; PX_AFTER=ok
tick
eq "retest healed the path: ok" "ok" "$ST"
eq "retest: one retest" "1" "$RETESTS"
eq "retest: fw not called" "none" "$(fwcalls)"

# the retest runs once per streak, not on every failing probe
reset
tick; tick; tick
eq "streak: bypassed after FAIL_N" "bypassed" "$ST"
eq "streak: retested once" "1" "$RETESTS"

# WAN down: no retest on every tick
reset; WAN=down
tick; T_NOW=1020; tick; T_NOW=1040; tick
eq "WAN down: retest rate-limited" "1" "$RETESTS"

# in bypass, after the hold, the groups are nudged at most once a minute
reset
tick; tick; tick
RETESTS=0; T_NOW=1130; tick
eq "bypass: hold elapsed, retested" "1" "$RETESTS"
T_NOW=1150; tick
eq "bypass: not again within a minute" "1" "$RETESTS"
T_NOW=1200; tick
eq "bypass: again after a minute" "2" "$RETESTS"

# the groups the retest times, with their own URLs
CONF="$TMP/conf.yaml"
cat > "$CONF" <<'Y'
proxies:
  - { name: n1, type: vless, server: a }
proxy-groups:
  - name: Proxy
    type: select
    proxies:
      - Auto
  - name: Auto
    type: url-test
    url: https://www.gstatic.com/generate_204
    interval: 300
  - name: "Auto UDP"
    type: url-test
    use: [sub1]
  - { name: 'AI', type: fallback, url: "http://cp.cloudflare.com/generate_204", interval: 300 }
  - { name: HK, type: select, proxies: [n1] }
rules:
  - MATCH,Proxy
Y
eq "retest list: url-test and fallback, block and flow" \
	"Auto|https://www.gstatic.com/generate_204,Auto UDP|https://www.gstatic.com/generate_204,AI|http://cp.cloudflare.com/generate_204," \
	"$(retest_groups_list | tr '\t' '|' | tr '\n' ',')"

finish
