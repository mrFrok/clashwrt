#!/bin/sh
# updctl.sh core-use: switching between mihomo and meow-openwrt, which comes
# as an OpenWrt package (opkg here, faked), checked against GitHub's SHA-256.
T="$(cd "$(dirname "$0")" && pwd)"
. "$T/lib.sh"
L="$T/../clashwrt/files/usr/libexec/clashwrt"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

mkdir -p "$TMP/bin" "$TMP/db" "$TMP/core" "$TMP/work" "$TMP/srv" "$TMP/pkg/usr/lib/opkg/info" "$TMP/store"
cp "$T"/shim/uci "$T"/shim/logger "$TMP/bin/"

# mihomo, as a .gz release asset
{ printf '#!/bin/sh\necho "Mihomo Meta v1.19.99 linux arm64"\nexit 0\n#'; head -c 300000 /dev/zero | tr '\0' a; echo; } > "$TMP/srv/mihomo"
gzip -c "$TMP/srv/mihomo" > "$TMP/srv/core.gz"
MSHA="$(sha256sum "$TMP/srv/core.gz" | awk '{ print $1 }')"

# meow's binary, and an .ipk around it the way meow-openwrt's package.sh makes one
{ printf '#!/bin/sh\necho "Meow Meta 0.29.0"\nexit 0\n#'; head -c 100000 /dev/zero | tr '\0' m; echo; } > "$TMP/srv/meow"
mkpkg() {
	_d="$TMP/mk.$1"; rm -rf "$_d"; mkdir -p "$_d/ctl" "$_d/data/usr/bin" "$_d/ipk"
	cp "$TMP/srv/meow" "$_d/data/usr/bin/meow"
	printf 'Package: %s\nVersion: 0.29.0-1\nArchitecture: aarch64_cortex-a53\nInstalled-Size: %s\n' "$1" "$(wc -c < "$TMP/srv/meow")" > "$_d/ctl/control"
	echo 2.0 > "$_d/ipk/debian-binary"
	(cd "$_d/ctl" && tar -czf "$_d/ipk/control.tar.gz" ./control)
	(cd "$_d/data" && tar -czf "$_d/ipk/data.tar.gz" ./usr)
	(cd "$_d/ipk" && tar -czf "$TMP/srv/${1}_0.29.0-1_aarch64_cortex-a53.ipk" ./debian-binary ./control.tar.gz ./data.tar.gz)
	sha256sum "$TMP/srv/${1}_0.29.0-1_aarch64_cortex-a53.ipk" | awk '{ print $1 }'
}
TSHA="$(mkpkg meow-tiny)"
FSHA="$(mkpkg meow-full)"

cat > "$TMP/bin/curl" <<'X'
#!/bin/sh
for a; do u="$a"; done
o=""; prev=""
for a; do [ "$prev" = -o ] && o="$a"; prev="$a"; done
echo "$u" >> "$SRV/urls"
out() { if [ -n "$o" ]; then cat "$1" > "$o"; else cat "$1"; fi; }
case "$u" in
*/mrFrok/meow-openwrt/releases/latest) printf '{\n  "tag_name": "owrt-v0.29.0-1"\n}\n' ;;
*/repos/mrFrok/meow-openwrt/releases/tags/*)
	printf '{\n  "assets": [\n    {\n      "name": "meow-tiny_0.29.0-1_aarch64_cortex-a53.ipk",\n      "digest": "sha256:%s"\n    },\n    {\n      "name": "meow-full_0.29.0-1_aarch64_cortex-a53.ipk",\n      "digest": "sha256:%s"\n    }\n  ]\n}\n' "${TDIG:-$TSHA}" "$FSHA" ;;
*/repos/MetaCubeX/mihomo/releases/*)
	printf '{\n  "tag_name": "v1.19.99",\n  "assets": [\n    {\n      "name": "mihomo-linux-arm64-v1.19.99.gz",\n      "digest": "sha256:%s"\n    }\n  ]\n}\n' "$MSHA" ;;
*/releases/download/*/*.ipk)
	case " $* " in *" -I"* | *" -sSIL "*) exit 0 ;; esac
	[ -f "$SRV/${u##*/}" ] || exit 22
	out "$SRV/${u##*/}" ;;
*/releases/download/*/*.gz)
	case " $* " in *" -I"* | *" -sSIL "*) exit 0 ;; esac
	out "$SRV/core.gz" ;;
*) exit 22 ;;
esac
X
# opkg: installs the package's binary and its control, as the real one would
cat > "$TMP/bin/opkg" <<'X'
#!/bin/sh
case "$1" in
install)
	f="$3"; n="${f##*/}"; n="${n%%_*}"
	tar -xzOf "$f" ./data.tar.gz | tar -xzOf - ./usr/bin/meow > "$CLASHWRT_BIN_DIR/meow" || exit 1
	chmod +x "$CLASHWRT_BIN_DIR/meow"
	tar -xzOf "$f" ./control.tar.gz | tar -xzOf - ./control > "$CLASHWRT_PKG_ROOT/usr/lib/opkg/info/$n.control"
	echo "$n" >> "$SRV/opkg.log" ;;
remove)
	rm -f "$CLASHWRT_PKG_ROOT/usr/lib/opkg/info/$2.control" "$CLASHWRT_BIN_DIR/meow"
	echo "-$2" >> "$SRV/opkg.log" ;;
esac
X
printf '#!/bin/sh\nexit 1\n' > "$TMP/bin/pidof"
chmod +x "$TMP/bin/"*
export PATH="$TMP/bin:$PATH" UCI_DB="$TMP/db" SRV="$TMP/srv" TSHA FSHA MSHA \
	CLASHWRT_BIN_DIR="$TMP/core" CLASHWRT_CORE_INIT="$TMP/no-init" CLASHWRT_STORE_DIR="$TMP/store" \
	CLASHWRT_TMPDIR="$TMP/work" CLASHWRT_PKG_ROOT="$TMP/pkg" CLASHWRT_PKG=ipk \
	MIHOMO_ARCH=arm64 MEOW_ARCH=aarch64_cortex-a53

upd() { sh "$L/updctl.sh" "$@" 2>&1; }
st() { upd core-status | sed -n "s/^$1:[[:space:]]*//p"; }

# start from mihomo on flash
cp "$TMP/srv/mihomo" "$TMP/core/mihomo"; chmod +x "$TMP/core/mihomo"

uci set clashwrt.config.mode=tproxy
uci set clashwrt.config.mode_auto=tproxy
out="$(TDIG=0000000000000000000000000000000000000000000000000000000000000000 upd core-use meow tiny)"
case "$out" in *"SHA-256 mismatch"*) pass "a meow package with the wrong digest is refused" ;; *) fail "a meow package with the wrong digest is refused ($out)" ;; esac
[ -L "$TMP/core/mihomo" ] && fail "and mihomo stays" || pass "and mihomo stays"
[ -e "$TMP/core/meow" ] && fail "nothing installed on a mismatch" || pass "nothing installed on a mismatch"

out="$(upd core-use meow tiny)"
case "$out" in *"SHA-256 checked: $TSHA"*) pass "the meow package is checked" ;; *) fail "the meow package is checked ($out)" ;; esac
grep -q '/owrt-v0.29.0-1/meow-tiny_0.29.0-1_aarch64_cortex-a53.ipk$' "$TMP/srv/urls" && pass "the tiny ipk of the latest release is fetched" || fail "the tiny ipk of the latest release is fetched ($(cat "$TMP/srv/urls"))"
eq "mihomo links to meow" "$TMP/core/meow" "$(readlink "$TMP/core/mihomo")"
[ -f "$TMP/pkg/usr/lib/opkg/info/meow-tiny.control" ] && pass "installed as a package" || fail "installed as a package"
eq "core_type is meow" meow "$(uci get clashwrt.config.core_type)"
eq "core_profile is tiny" tiny "$(uci get clashwrt.config.core_profile)"
eq "the mode follows: meow captures by itself" auto_redirect "$(uci get clashwrt.config.mode)"
eq "the release is noted" "owrt-v0.29.0-1 meow-tiny" "$(cat "$TMP/store/meow.note")"

eq "status: the core" meow "$(st core)"
eq "status: the profile" tiny "$(st profile)"
eq "status: installed" owrt-v0.29.0-1 "$(st installed)"
eq "status: current" current "$(st update)"
eq "no Go memory settings for meow" "" "$(upd core-env)"
out="$(upd core-store gz)"
case "$out" in *"stays on flash"*) pass "meow is not packed into RAM" ;; *) fail "meow is not packed into RAM ($out)" ;; esac

# the "Update core" button follows core_type
rm -f "$TMP/srv/urls"
out="$(upd core-install)"
grep -q 'meow-tiny_0.29.0-1' "$TMP/srv/urls" && pass "core-install updates meow" || fail "core-install updates meow ($out)"

# another profile replaces the one installed
out="$(upd core-use meow full)"
[ -f "$TMP/pkg/usr/lib/opkg/info/meow-full.control" ] && [ ! -f "$TMP/pkg/usr/lib/opkg/info/meow-tiny.control" ] &&
	pass "full replaces tiny" || fail "full replaces tiny ($out)"
eq "and the link still holds" "$TMP/core/meow" "$(readlink "$TMP/core/mihomo")"

# an .apk is named the apk way (this release lists none, so it stops there)
out="$(CLASHWRT_PKG=apk upd core-use meow tiny)"
case "$out" in *"SHA-256 of meow-tiny-0.29.0-r1_aarch64_cortex-a53.apk"*) pass "the apk file name" ;; *) fail "the apk file name ($out)" ;; esac
eq "a file the release lacks changes nothing" meow-full "$(cut -d' ' -f2 "$TMP/store/meow.note")"

# a router meow has no build for
out="$(MEOW_ARCH='' upd core-use meow)"
case "$out" in *"no build for this router"*) pass "an unsupported arch is refused" ;; *) fail "an unsupported arch is refused ($out)" ;; esac

# and back to mihomo: the package goes once mihomo is in place
out="$(upd core-use mihomo)"
[ -f "$TMP/core/mihomo" ] && [ ! -L "$TMP/core/mihomo" ] && cmp -s "$TMP/core/mihomo" "$TMP/srv/mihomo" &&
	pass "mihomo is back on flash" || fail "mihomo is back on flash ($out)"
[ -f "$TMP/pkg/usr/lib/opkg/info/meow-full.control" ] && fail "meow's package is removed" || pass "meow's package is removed"
[ -e "$TMP/store/meow.note" ] && fail "and its note" || pass "and its note"
eq "core_type is mihomo" mihomo "$(uci get clashwrt.config.core_type)"
eq "and back to what the wizard's test chose" tproxy "$(uci get clashwrt.config.mode)"
eq "status: the core" mihomo "$(st core)"

uci set clashwrt.wizard.mode_choice=tun
uci set clashwrt.config.mode=tun
upd core-use meow tiny >/dev/null 2>&1
eq "a mode picked by hand stays" tun "$(uci get clashwrt.config.mode)"
finish
