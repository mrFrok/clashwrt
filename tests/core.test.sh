#!/bin/sh
# updctl.sh core-install: the downloaded .gz must hash to what GitHub says,
# and a core that does not is never installed.
T="$(cd "$(dirname "$0")" && pwd)"
. "$T/lib.sh"
L="$T/../clashwrt/files/usr/libexec/clashwrt"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

mkdir -p "$TMP/bin" "$TMP/db" "$TMP/core" "$TMP/work" "$TMP/srv"
cp "$T"/shim/uci "$T"/shim/logger "$TMP/bin/"

# the "core": a script that answers -v like mihomo does
printf '#!/bin/sh\necho "Mihomo Meta v1.19.99 linux amd64"\n' > "$TMP/srv/mihomo"
gzip -c "$TMP/srv/mihomo" > "$TMP/srv/core.gz"
GOOD="$(sha256sum "$TMP/srv/core.gz" | awk '{ print $1 }')"

# curl: the release API answers with $DIGEST, anything else gets the .gz
cat > "$TMP/bin/curl" <<'X'
#!/bin/sh
for a; do u="$a"; done
case "$u" in
https://api.github.com/*)
	[ -n "$DIGEST" ] || { echo '{ "assets": [] }'; exit 0; }
	printf '{\n  "assets": [\n    {\n      "name": "mihomo-linux-amd64-v1.19.99.gz",\n      "digest": "sha256:%s"\n    }\n  ]\n}\n' "$DIGEST" ;;
*) case " $* " in *" -I"*) exit 0 ;; esac; cat "$SRV/core.gz" ;;
esac
X
printf '#!/bin/sh\nexit 1\n' > "$TMP/bin/pidof"
chmod +x "$TMP/bin/"*
export PATH="$TMP/bin:$PATH" UCI_DB="$TMP/db" SRV="$TMP/srv" \
	CLASHWRT_BIN_DIR="$TMP/core" CLASHWRT_CORE_INIT="$TMP/no-init" \
	CLASHWRT_TMPDIR="$TMP/work" MIHOMO_ARCH=amd64

inst() { sh "$L/updctl.sh" core-install v1.19.99 2>&1; }

out="$(DIGEST=0000000000000000000000000000000000000000000000000000000000000000 inst)"
case "$out" in *"SHA-256 mismatch"*) pass "a wrong digest is refused" ;; *) fail "a wrong digest is refused ($out)" ;; esac
[ -e "$TMP/core/mihomo" ] && fail "nothing installed on a mismatch" || pass "nothing installed on a mismatch"

out="$(DIGEST='' inst)"
case "$out" in *"cannot be checked"*) pass "no digest: refused" ;; *) fail "no digest: refused ($out)" ;; esac
[ -e "$TMP/core/mihomo" ] && fail "nothing installed without a digest" || pass "nothing installed without a digest"

out="$(DIGEST="$GOOD" inst)"
case "$out" in *"SHA-256 checked: $GOOD"*) pass "the right digest is checked" ;; *) fail "the right digest is checked ($out)" ;; esac
cmp -s "$TMP/core/mihomo" "$TMP/srv/mihomo" && pass "and the core installed" || fail "and the core installed"

rm -f "$TMP/core/mihomo"
uci set clashwrt.config.core_verify=0
out="$(DIGEST='' inst)"
case "$out" in *"without a SHA-256 check"*) pass "core_verify 0 installs unchecked, and says so" ;; *) fail "core_verify 0 installs unchecked, and says so ($out)" ;; esac
[ -e "$TMP/core/mihomo" ] && pass "installed" || fail "installed"

ls "$TMP/work" | grep -q . && fail "no leftovers in the work dir" || pass "no leftovers in the work dir"

finish
