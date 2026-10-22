#!/bin/sh
# install.sh run the way the Update button runs it -- no terminal, SKIP_CORE=1,
# REPO_URL given, on a router whose UCI lacks the newer options -- must get to
# the end. 1.4.0 did not: under `set -e` a failing `uci get` ended it silently.
# Runs as root in a throwaway container (it writes /usr, /etc and /lib).
T="$(cd "$(dirname "$0")" && pwd)"
. "$T/lib.sh"
[ "$(id -u)" = 0 ] && [ -n "${CLASHWRT_SANDBOX:-}" ] || { echo "skipped: needs a throwaway root sandbox (CLASHWRT_SANDBOX=1)"; exit 0; }

mkdir -p /usr/libexec /etc/config /etc/init.d /sbin /tmp/db /lib /tmp/src
cp "$T/shim/uci" /usr/bin/uci; cp "$T/shim/functions.sh" /lib/functions.sh
export UCI_DB=/tmp/db
tar czf /tmp/src/work.tar.gz -C "$T/.." --exclude=.git .
printf '#!/bin/sh\nexit 0\n' > /sbin/fw4
SHA="$(sha256sum /tmp/src/work.tar.gz | awk '{ print $1 }')"
cat > /usr/bin/curl <<X
#!/bin/sh
o=""; prev=""; for a; do [ "\$prev" = -o ] && o="\$a"; prev="\$a"; u="\$a"; done
case "\$u" in
*/releases/latest) printf '{\n  "tag_name": "v9.9.9"\n}\n' ;;
*/releases/tags/v9.9.9) printf '{\n  "assets": [\n    {\n      "name": "clashwrt-v9.9.9.tar.gz",\n      "digest": "sha256:$SHA"\n    }\n  ]\n}\n' ;;
*/releases/download/v9.9.9/clashwrt-v9.9.9.tar.gz|*/archive/refs/*.tar.gz) cp /tmp/src/work.tar.gz "\$o" ;;
*) exit 22 ;;
esac
X
printf '#!/bin/sh\necho "Mihomo Meta v1.19.32 linux arm64"\n' > /usr/bin/mihomo
printf '#!/bin/sh\nexit 1\n' > /usr/bin/pidof
chmod +x /usr/bin/uci /sbin/fw4 /usr/bin/curl /usr/bin/mihomo /usr/bin/pidof

out="$(SKIP_CORE=1 REPO_URL='https://github.com/mrFrok/clashwrt/archive/refs/tags/v9.9.9.tar.gz' \
	sh "$T/../install.sh" </dev/null 2>&1)"
rc=$?
eq "the update runs to the end" "0" "$rc"
case "$out" in *"Done."*) pass "and says so" ;; *) fail "and says so ($(echo "$out" | tail -3))" ;; esac
case "$out" in *"/cgi-bin/luci/admin/services/clashwrt/setup-wizard"*) pass "and where to go next" ;; *) fail "and where to go next" ;; esac
[ -x /usr/libexec/clashwrt/updctl.sh ] && pass "scripts installed" || fail "scripts installed"
grep -q '^# written by clashwrt' /etc/init.d/mihomo && pass "mihomo init script is ClashWrt's" || fail "mihomo init script is ClashWrt's"
case "$out" in *"keeping the existing mihomo core"*) pass "the core is left alone" ;; *) fail "the core is left alone" ;; esac
case "$out" in *"SHA-256 checked"*) pass "the release tarball is checked" ;; *) fail "the release tarball is checked" ;; esac
eq "the tag's archive is recorded" "repo=https://github.com/mrFrok/clashwrt/archive/refs/tags/v9.9.9.tar.gz" \
	"$(grep '^repo=' /usr/libexec/clashwrt/.install-info)"
st="$(sh /usr/libexec/clashwrt/updctl.sh self-status 2>&1)"
case "$st" in *"update:    current"*) pass "the update check reads it" ;; *) fail "the update check reads it ($st)" ;; esac

# what 1.4.0 and 1.4.1 recorded must still be understood
sed -i 's#^repo=.*#repo=https://github.com/mrFrok/clashwrt/releases/download/v9.9.9/clashwrt-v9.9.9.tar.gz#' /usr/libexec/clashwrt/.install-info
st="$(sh /usr/libexec/clashwrt/updctl.sh self-status 2>&1)"
case "$st" in *"update:    current"*) pass "and the 1.4.0 form" ;; *) fail "and the 1.4.0 form ($st)" ;; esac

finish
