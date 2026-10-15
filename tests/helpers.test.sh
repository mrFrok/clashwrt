#!/bin/sh
# Root helpers: release tags, staged configs and list sizes are checked
# before anything is downloaded, installed or loaded.
T="$(cd "$(dirname "$0")" && pwd)"
. "$T/lib.sh"
L="$T/../clashwrt/files/usr/libexec/clashwrt"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

# updctl.sh: valid_tag, taken out of the script without running it
sed -n '/^valid_tag() {/,/^}/p' "$L/updctl.sh" > "$TMP/vt.sh"
. "$TMP/vt.sh"
for tag in v1.19.2 v1.19.2-alpha.1 Prerelease-Alpha; do
	valid_tag "$tag" && pass "tag accepted: $tag" || fail "tag accepted: $tag"
done
for tag in "" "v1/../../x" "v1#" "v1?a=b" "../v1" "-v1" "v1 x"; do
	valid_tag "$tag" && fail "tag refused: '$tag'" || pass "tag refused: '$tag'"
done

# updctl.sh core-install refuses a bad version before any download
mkdir -p "$TMP/bin"
printf '#!/bin/sh\necho "curl $*" >> "%s/curl.log"\nexit 1\n' "$TMP" > "$TMP/bin/curl"
chmod +x "$TMP/bin/curl"
out="$(PATH="$TMP/bin:$PATH" MIHOMO_ARCH=amd64 sh "$L/updctl.sh" core-install 'v1/../../x/y#' 2>&1)"
case "$out" in *"not a release tag"*) pass "core-install refuses a path as a version" ;; *) fail "core-install refuses a path as a version ($out)" ;; esac
[ -e "$TMP/curl.log" ] && fail "nothing was downloaded" || pass "nothing was downloaded"

# setctl.sh: a list over the entry cap is refused and the old one kept
S="$TMP/set"; mkdir -p "$S/db" "$S/state" "$S/bin"
cp "$T"/shim/uci "$T"/shim/logger "$S/bin/"
cat > "$S/bin/curl" <<'X'
#!/bin/sh
while [ $# -gt 0 ]; do [ "$1" = -o ] && { shift; out="$1"; }; shift; done
awk 'BEGIN { for (i = 0; i < 30; i++) printf "10.%d.%d.0/24\n", int(i / 250), i % 250 }' > "$out"
X
printf '#!/bin/sh\nexit 0\n' > "$S/bin/nft"
chmod +x "$S/bin/"*
uci() { UCI_DB="$S/db" "$S/bin/uci" "$@"; }
uci set clashwrt.config.bypass_set_mode=include
uci set clashwrt.config.bypass_set_source=custom
uci set clashwrt.config.bypass_set_url=https://lists.example/x
uci set clashwrt.config.bypass_set_from_config=0
uci set "clashwrt.config.mihomo_dir=$S"
printf '1.2.3.0/24\n' > "$S/state/bypass4.list"
sed 's/^MAX_LIST_ENTRIES=.*/MAX_LIST_ENTRIES=20/' "$L/setctl.sh" > "$S/setctl.sh"
PATH="$S/bin:$PATH" UCI_DB="$S/db" LOGGER_OUT="$S/log" CLASHWRT_FUNCTIONS="$T/shim/functions.sh" \
	CLASHWRT_STATE_DIR="$S/state" sh "$S/setctl.sh" update force >/dev/null 2>&1
eq "an oversized list leaves the previous one in place" "1.2.3.0/24" "$(cat "$S/state/bypass4.list")"
grep -q "more than 20 networks" "$S/log" && pass "and says why" || fail "and says why"
grep -q -- "--max-filesize" "$L/setctl.sh" && pass "the download itself is capped" || fail "the download itself is capped"

finish
