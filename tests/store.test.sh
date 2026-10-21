#!/bin/sh
# updctl.sh core_store: the core kept on flash, packed on flash and unpacked
# into RAM at boot, or only in RAM -- and moved between them without a moment
# with no core.
T="$(cd "$(dirname "$0")" && pwd)"
. "$T/lib.sh"
L="$T/../clashwrt/files/usr/libexec/clashwrt"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

mkdir -p "$TMP/bin" "$TMP/db" "$TMP/usrbin" "$TMP/srv" "$TMP/ram"
cp "$T"/shim/uci "$T"/shim/logger "$TMP/bin/"
printf '#!/bin/sh\necho "Mihomo Meta v1.19.99 linux amd64"\n' > "$TMP/srv/mihomo"
gzip -c "$TMP/srv/mihomo" > "$TMP/srv/core.gz"
GOOD="$(sha256sum "$TMP/srv/core.gz" | awk '{ print $1 }')"

cat > "$TMP/bin/curl" <<'X'
#!/bin/sh
for a; do u="$a"; done
[ -e "$NET_DOWN" ] && exit 7
case "$u" in
https://api.github.com/*)
	printf '{\n  "assets": [\n    {\n      "name": "mihomo-linux-amd64-v1.19.99.gz",\n      "digest": "sha256:%s"\n    }\n  ]\n}\n' "$GOOD" ;;
*) case " $* " in *" -I"*) exit 0 ;; esac; cat "$SRV/core.gz" ;;
esac
X
printf '#!/bin/sh\nexit 1\n' > "$TMP/bin/pidof"
printf '#!/bin/sh\necho "$1" >> "%s/init.log"\n' "$TMP" > "$TMP/init"
chmod +x "$TMP/bin/"* "$TMP/init"
mem() { printf 'MemTotal: %s kB\nMemAvailable: %s kB\n' "$1" "$2" > "$TMP/meminfo"; }
mem 524288 400000
export PATH="$TMP/bin:$PATH" UCI_DB="$TMP/db" SRV="$TMP/srv" GOOD NET_DOWN="$TMP/down" \
	CLASHWRT_BIN_DIR="$TMP/usrbin" CLASHWRT_CORE_INIT="$TMP/init" \
	CLASHWRT_STORE_DIR="$TMP/store" CLASHWRT_RAM_DIR="$TMP/ram/core" \
	CLASHWRT_MEMINFO="$TMP/meminfo" CLASHWRT_TMPDIR="$TMP/ram" MIHOMO_ARCH=amd64 \
	CORE_RETRIES=0
U() { sh "$L/updctl.sh" "$@" 2>&1; }
BIN="$TMP/usrbin/mihomo"; RAMC="$TMP/ram/core/mihomo"; GZ="$TMP/store/mihomo.gz"; NOTE="$TMP/store/mihomo.note"
linked() { [ -L "$BIN" ] && [ "$(readlink "$BIN")" = "$RAMC" ] && cmp -s "$RAMC" "$TMP/srv/mihomo"; }
reboot() { rm -rf "$TMP/ram/core"; }

# gz: installed packed on flash, run from RAM
uci set clashwrt.config.core_store=gz
out="$(U core-install v1.19.99)"
linked && pass "gz: the core runs from RAM through the link" || fail "gz: the core runs from RAM through the link ($out)"
cmp -s "$GZ" "$TMP/srv/core.gz" && pass "gz: the release's .gz is kept on flash" || fail "gz: the release's .gz is kept on flash"
eq "gz: the note" "v1.19.99 mihomo-linux-amd64-v1.19.99.gz $GOOD $GOOD" "$(cat "$NOTE")"
case "$(U core-status)" in *"store:     gz"*"location:  ram"*"packed on flash"*) pass "status says where the core is" ;; *) fail "status says where the core is" ;; esac

reboot
out="$(U core-prepare)"
linked && pass "gz: after a reboot it is unpacked again" || fail "gz: after a reboot it is unpacked again ($out)"
out="$(U core-prepare)"
eq "prepare is quiet when the core is there" "" "$out"

cp "$GZ" "$TMP/gz.bak"; printf 'x' >> "$GZ"; reboot
out="$(U core-prepare)"
case "$out" in *"does not match its recorded SHA-256"*) pass "a damaged .gz is not unpacked" ;; *) fail "a damaged .gz is not unpacked ($out)" ;; esac
[ -e "$RAMC" ] && fail "and nothing is in RAM" || pass "and nothing is in RAM"
cp "$TMP/gz.bak" "$GZ"; U core-prepare >/dev/null

# gz -> ram: the .gz goes, the note stays for the download at boot
out="$(U core-store ram)"
[ ! -e "$GZ" ] && linked && pass "ram: nothing but the note on flash" || fail "ram: nothing but the note on flash ($out)"
reboot
out="$(U core-prepare)"
linked && pass "ram: downloaded again at boot" || fail "ram: downloaded again at boot ($out)"
reboot; : > "$TMP/down"
out="$(U core-prepare)"
case "$out" in *"will keep trying in the background"*) pass "ram: a failed download is retried" ;; *) fail "ram: a failed download is retried ($out)" ;; esac
rm -f "$TMP/down"; U core-prepare >/dev/null

# ram -> flash: a real file again, nothing left in RAM or the store
out="$(U core-store flash)"
[ -f "$BIN" ] && [ ! -L "$BIN" ] && cmp -s "$BIN" "$TMP/srv/mihomo" && pass "flash: a plain file again" || fail "flash: a plain file again ($out)"
[ ! -e "$RAMC" ] && [ ! -e "$NOTE" ] && pass "flash: RAM and store emptied" || fail "flash: RAM and store emptied"
eq "flash: recorded" "flash" "$(uci get clashwrt.config.core_store)"

# flash -> gz packs the core on the router, no download
: > "$TMP/down"
out="$(U core-store gz)"
linked && [ -s "$GZ" ] && pass "flash -> gz packs it locally" || fail "flash -> gz packs it locally ($out)"
gzip -dc "$GZ" | cmp -s - "$TMP/srv/mihomo" && pass "and the pack holds the same core" || fail "and the pack holds the same core"
reboot; U core-prepare >/dev/null
linked && pass "and unpacks at boot" || fail "and unpacks at boot"
rm -f "$TMP/down"
U core-store flash >/dev/null

# a small router never moves the core into RAM
mem 131072 90000
out="$(U core-store gz)"
case "$out" in *"under 256 MB"*) pass "under 256 MB of RAM: refused" ;; *) fail "under 256 MB of RAM: refused ($out)" ;; esac
[ -f "$BIN" ] && [ ! -L "$BIN" ] && pass "and the core stays on flash" || fail "and the core stays on flash"
eq "and the setting too" "flash" "$(uci get clashwrt.config.core_store)"

# the Go memory ceiling for mihomo follows the RAM, or the setting
mem 200000 100000; eq "under 256 MB: 48 MiB" "GOMEMLIMIT=48MiB GOGC=50" "$(U core-env)"
mem 400000 200000; eq "under 512 MB: 96 MiB" "GOMEMLIMIT=96MiB GOGC=75" "$(U core-env)"
mem 4000000 3000000; eq "more: no ceiling" "" "$(U core-env)"
uci set clashwrt.config.core_mem_limit=64; eq "a number of MiB" "GOMEMLIMIT=64MiB" "$(U core-env)"
uci set clashwrt.config.core_mem_limit=off; mem 200000 100000; eq "off" "" "$(U core-env)"
uci set clashwrt.config.core_mem_limit='1;x'; eq "garbage: nothing" "" "$(U core-env)"

finish
