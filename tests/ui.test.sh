#!/bin/sh
# uictl.sh ui_store: the dashboard on flash, packed on flash and unpacked into
# RAM at boot, or fetched again into RAM -- and moved between them.
T="$(cd "$(dirname "$0")" && pwd)"
. "$T/lib.sh"
L="$T/../clashwrt/files/usr/libexec/clashwrt"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

mkdir -p "$TMP/bin" "$TMP/db" "$TMP/mihomo" "$TMP/srv/yacd-gh-pages"
cp "$T"/shim/uci "$T"/shim/logger "$TMP/bin/"
echo '<html>yacd</html>' > "$TMP/srv/yacd-gh-pages/index.html"
echo 'self.addEventListener("fetch", function () {});' > "$TMP/srv/yacd-gh-pages/sw.js"
tar czf "$TMP/srv/ui.tar.gz" -C "$TMP/srv" yacd-gh-pages

cat > "$TMP/bin/curl" <<'X'
#!/bin/sh
[ -e "$NET_DOWN" ] && exit 7
o=""; prev=""
for a; do [ "$prev" = -o ] && o="$a"; prev="$a"; done
cp "$SRV/ui.tar.gz" "$o"
X
printf '#!/bin/sh\nexit 1\n' > "$TMP/bin/pidof"
chmod +x "$TMP/bin/"*
mem() { printf 'MemTotal: %s kB\nMemAvailable: %s kB\n' "$1" "$2" > "$TMP/meminfo"; }
mem 524288 400000
export PATH="$TMP/bin:$PATH" UCI_DB="$TMP/db" SRV="$TMP/srv" NET_DOWN="$TMP/down" \
	CLASHWRT_FUNCTIONS="$T/shim/functions.sh" CLASHWRT_STORE_DIR="$TMP/store" \
	CLASHWRT_UI_RAM="$TMP/ram/ui" CLASHWRT_MEMINFO="$TMP/meminfo" UI_RETRIES=1
uci set "clashwrt.config.mihomo_dir=$TMP/mihomo"
U() { sh "$L/uictl.sh" "$@" 2>&1; }
UI="$TMP/mihomo/ui"; RAM="$TMP/ram/ui"
served() { [ "$(cat "$UI/index.html" 2>/dev/null)" = '<html>yacd</html>' ]; }
linked() { [ -L "$UI" ] && [ "$(readlink "$UI")" = "$RAM" ] && served; }
reboot() { rm -rf "$TMP/ram"; }

out="$(U install yacd)"
[ -d "$UI" ] && [ ! -L "$UI" ] && served && pass "flash: installed as a directory" || fail "flash: installed as a directory ($out)"
grep -q unregister "$UI/sw.js" && pass "the service worker is replaced" || fail "the service worker is replaced"
eq "and labelled" "yacd" "$(U current)"

out="$(U store gz)"
linked && [ -s "$TMP/store/ui.tar.gz" ] && pass "gz: packed on flash, served from RAM" || fail "gz: packed on flash, served from RAM ($out)"
reboot; out="$(U prepare)"
linked && pass "gz: unpacked again after a reboot" || fail "gz: unpacked again after a reboot ($out)"
eq "and still labelled" "yacd" "$(U current)"

out="$(U store ram)"
[ ! -e "$TMP/store/ui.tar.gz" ] && linked && pass "ram: nothing packed on flash" || fail "ram: nothing packed on flash ($out)"
reboot; out="$(U prepare)"
linked && pass "ram: fetched again after a reboot" || fail "ram: fetched again after a reboot ($out)"
reboot; : > "$TMP/down"; out="$(U prepare)"
case "$out" in *"could not download"*) pass "ram: a failed fetch says so" ;; *) fail "ram: a failed fetch says so ($out)" ;; esac
rm -f "$TMP/down"; U prepare >/dev/null

out="$(U store flash)"
[ -d "$UI" ] && [ ! -L "$UI" ] && served && [ ! -e "$RAM" ] && pass "flash: a directory again, RAM emptied" || fail "flash: a directory again, RAM emptied ($out)"

uci set clashwrt.config.ui_store=gz
out="$(U install yacd)"
linked && [ -s "$TMP/store/ui.tar.gz" ] && pass "install straight into gz" || fail "install straight into gz ($out)"
case "$(U status)" in *"store:     gz"*"location:  ram"*) pass "status" ;; *) fail "status" ;; esac
U store flash >/dev/null

mem 131072 90000
out="$(U store ram)"
case "$out" in *"under 256 MB"*) pass "under 256 MB of RAM: refused" ;; *) fail "under 256 MB of RAM: refused ($out)" ;; esac
[ -d "$UI" ] && [ ! -L "$UI" ] && served && pass "and the dashboard stays on flash" || fail "and the dashboard stays on flash"

finish
