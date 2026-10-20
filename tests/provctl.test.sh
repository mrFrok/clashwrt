#!/bin/sh
# provctl.sh: providers move to RAM only with room to spare, come back when
# the room goes, and are never missing or lost along the way.
T="$(cd "$(dirname "$0")" && pwd)"
. "$T/lib.sh"
P="$T/../clashwrt/files/usr/libexec/clashwrt/provctl.sh"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

mkdir -p "$TMP/bin" "$TMP/db" "$TMP/m/providers" "$TMP/m/re-filter" "$TMP/ram"
cp "$T"/shim/uci "$T"/shim/logger "$TMP/bin/"
# df: the 'RAM' filesystem is DF_SIZE KB with DF_FREE KB free
cat > "$TMP/bin/df" <<'X'
#!/bin/sh
echo "Filesystem 1K-blocks Used Available Use% Mounted"
echo "tmpfs $DF_SIZE $((DF_SIZE - DF_FREE)) $DF_FREE 10% /tmp"
X
chmod +x "$TMP/bin/"*
export PATH="$TMP/bin:$PATH" UCI_DB="$TMP/db" LOGGER_OUT="$TMP/log" \
	CLASHWRT_FUNCTIONS="$T/shim/functions.sh" CLASHWRT_PROV_RAM="$TMP/ram/p" CLASHWRT_MEMINFO="$TMP/meminfo"
uci set "clashwrt.config.mihomo_dir=$TMP/m"

cat > "$TMP/m/config.yaml" <<'Y'
proxy-providers:
  sub1: { type: http, url: https://x, path: ./providers/sub1.yaml }
rule-providers:
  rf:
    type: http
    path: ./re-filter/domain-rule.mrs
  bad: { path: /etc/passwd }
  up: { path: ../../x/y }
Y
echo sub > "$TMP/m/providers/sub1.yaml"
echo rules > "$TMP/m/re-filter/domain-rule.mrs"

mem() { printf 'MemTotal: %s kB\nMemAvailable: %s kB\n' "$1" "$2" > "$TMP/meminfo"; }
export DF_SIZE=1000000 DF_FREE=900000

mem 4000000 3000000
sh "$P" place
[ -L "$TMP/m/providers" ] && [ -L "$TMP/m/re-filter" ] && pass "with room, both dirs move to RAM" || fail "with room, both dirs move to RAM"
eq "files still read through the old path" "sub|rules" "$(cat "$TMP/m/providers/sub1.yaml")|$(cat "$TMP/m/re-filter/domain-rule.mrs")"
[ -f "$TMP/m/.clashwrt-flash/providers/sub1.yaml" ] && pass "a flash copy is kept" || fail "a flash copy is kept"
[ -e "$TMP/m/etc" ] || [ -e "$TMP/ram/p/etc" ] && fail "absolute and .. paths are ignored" || pass "absolute and .. paths are ignored"
case "$(sh "$P" status)" in "providers: ram "*) pass "status says RAM" ;; *) fail "status says RAM" ;; esac

# reboot: RAM is empty, the links dangle; place refills from flash
rm -rf "$TMP/ram/p"
sh "$P" place
eq "after a reboot the files are back without a download" "sub" "$(cat "$TMP/m/providers/sub1.yaml")"

# mihomo refreshed a file in RAM; then RAM runs short: everything comes back
echo sub-new > "$TMP/m/providers/sub1.yaml"
mem 4000000 200000
sh "$P" place
[ -d "$TMP/m/providers" ] && [ ! -L "$TMP/m/providers" ] && pass "short of RAM: back to real dirs" || fail "short of RAM: back to real dirs"
eq "with the newer contents" "sub-new" "$(cat "$TMP/m/providers/sub1.yaml")"
[ -d "$TMP/ram/p/providers" ] && fail "and the RAM copy is gone" || pass "and the RAM copy is gone"
case "$(sh "$P" status)" in *"too little free RAM"*) pass "status says why" ;; *) fail "status says why" ;; esac

# a small router never moves; neither does a nearly full /tmp
mem 131072 100000; sh "$P" place
[ -L "$TMP/m/providers" ] && fail "under 256 MB: stays on flash" || pass "under 256 MB: stays on flash"
mem 4000000 3000000; DF_FREE=100000 sh "$P" place
[ -L "$TMP/m/providers" ] && fail "/tmp nearly full: stays on flash" || pass "/tmp nearly full: stays on flash"
uci set clashwrt.config.providers_in_ram=0; sh "$P" place
[ -L "$TMP/m/providers" ] && fail "turned off: stays on flash" || pass "turned off: stays on flash"

finish
