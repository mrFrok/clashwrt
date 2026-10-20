#!/bin/sh
# confctl.sh export/import: a round trip, and a bad archive changes nothing.
# Runs as root in a throwaway container (it writes /etc/config and /tmp).
T="$(cd "$(dirname "$0")" && pwd)"
. "$T/lib.sh"
[ "$(id -u)" = 0 ] && [ -n "${CLASHWRT_SANDBOX:-}" ] || { echo "skipped: needs a throwaway root sandbox (CLASHWRT_SANDBOX=1)"; exit 0; }
C="$T/../clashwrt/files/usr/libexec/clashwrt/confctl.sh"

cp "$T/shim/functions.sh" /lib/functions.sh
# a uci that parses: show succeeds when the file has a 'config' line
cat > /usr/bin/uci <<'X'
#!/bin/sh
dir=/etc/config; [ "$1" = -c ] && { dir="$2"; shift 2; }; [ "$1" = -q ] && shift
case "$1" in
	show) grep -q "^config " "$dir/$2" ;;
	get) exit 1 ;;
esac
X
printf '#!/bin/sh\ngrep -q bad "$3/config.yaml" && exit 1; exit 0\n' > /usr/bin/mihomo
mkdir -p /etc/init.d && printf '#!/bin/sh\nexit 0\n' > /etc/init.d/clashwrt
chmod +x /usr/bin/uci /usr/bin/mihomo /etc/init.d/clashwrt
mkdir -p /etc/config /etc/mihomo/lst
printf "config clashwrt 'config'\n\toption mode 'tun'\n" > /etc/config/clashwrt
echo "mode: rule" > /etc/mihomo/config.yaml
echo "example.com" > /etc/mihomo/lst/my.txt

out="$(sh "$C" export)"
eq "export writes the archive" "/tmp/clashwrt-settings.tar.gz" "$out"
tar -tzf /tmp/clashwrt-settings.tar.gz | grep -q 'settings/lists/my.txt' && pass "rule files included" || fail "rule files included"

# change everything, then import: all three come back
printf "config clashwrt 'config'\n\toption mode 'tproxy'\n" > /etc/config/clashwrt
echo "mode: global" > /etc/mihomo/config.yaml; rm /etc/mihomo/lst/my.txt
cp /tmp/clashwrt-settings.tar.gz /tmp/clashwrt-settings-restore.tar.gz
sh "$C" import >/dev/null 2>&1
grep -q "'tun'" /etc/config/clashwrt && pass "settings restored" || fail "settings restored"
eq "config.yaml restored" "mode: rule" "$(cat /etc/mihomo/config.yaml)"
[ -f /etc/mihomo/lst/my.txt ] && pass "rule file restored" || fail "rule file restored"
ls /etc/mihomo/backups/config-*.yaml >/dev/null 2>&1 && pass "the replaced config.yaml was backed up" || fail "the replaced config.yaml was backed up"

# an archive whose config.yaml mihomo refuses: nothing changes
mkdir -p /tmp/b/settings && printf "config clashwrt 'config'\n\toption mode 'redirect_tun'\n" > /tmp/b/settings/clashwrt.uci
echo bad > /tmp/b/settings/config.yaml
tar -czf /tmp/clashwrt-settings-restore.tar.gz -C /tmp/b settings
sh "$C" import >/dev/null 2>&1 && fail "a refused config.yaml fails the import" || pass "a refused config.yaml fails the import"
grep -q "'tun'" /etc/config/clashwrt && pass "and leaves the settings alone" || fail "and leaves the settings alone"

echo "not a tarball" > /tmp/clashwrt-settings-restore.tar.gz
sh "$C" import >/dev/null 2>&1 && fail "garbage is refused" || pass "garbage is refused"

finish
