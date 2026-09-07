#!/bin/sh
# SPDX-License-Identifier: GPL-3.0-or-later
#
# Version reporting and updates, for the LuCI pages and for install.sh.
#
# Two things get updated on a running router: the mihomo core, which is a
# single binary from a GitHub release, and ClashWrt itself, which is whatever
# install.sh last laid down. They fail in different ways and are kept apart.
#
# The core-install path here is the one install.sh uses too -- it extracts the
# source tree, drops this script in place and then calls it, rather than
# carrying its own copy of the architecture table. There is exactly one place
# that knows how to pick a mihomo build, and this is it.
#
# Updating ClashWrt cannot be done in this process. install.sh overwrites the
# scripts in /usr/libexec/clashwrt in place, this file included, and a shell
# reads its script incrementally by file offset -- so a running updctl.sh
# whose file was rewritten underneath it resumes in the middle of whatever
# text now occupies that offset. install.sh also restarts rpcd, which is the
# very thing carrying the LuCI call. So self-update detaches the installer
# into its own session, points it at a log, and returns immediately; the page
# follows the log.
#
# Usage: updctl.sh core-status|core-install [version]|self-status|self-update|log

REPO_DEFAULT="https://github.com/mrFrok/clashwrt/archive/refs/heads/main.tar.gz"
INFO="/usr/libexec/clashwrt/.install-info"
LOG="/tmp/clashwrt-update.log"

die() { echo "ERROR: $*" >&2; exit 1; }

# --------------------------------------------------------------------------
# where this copy came from
# --------------------------------------------------------------------------

# install.sh records the branch head it installed. A copy installed from the
# OpenWrt package feed has no such file: report what is knowable rather than
# guessing, and leave the update button working for whoever wants it.
load_info() {
	REPO="$REPO_DEFAULT"
	INST_COMMIT=""
	INST_DATE=""

	[ -f "$INFO" ] || return 0
	while IFS='=' read -r k v; do
		case "$k" in
			repo)   [ -n "$v" ] && REPO="$v" ;;
			commit) INST_COMMIT="$v" ;;
			date)   INST_DATE="$v" ;;
		esac
	done < "$INFO"
}

# Split https://github.com/<owner>/<name>/archive/refs/heads/<ref>.tar.gz into
# the slug and ref the API needs. Anything else -- a private mirror, a local
# file, a release tarball -- is updatable but not checkable, and says so.
parse_repo() {
	SLUG=""; REF=""
	case "$REPO" in
		https://github.com/*/archive/refs/heads/*.tar.gz) ;;
		*) return 1 ;;
	esac
	SLUG="${REPO#https://github.com/}"; SLUG="${SLUG%%/archive/*}"
	REF="${REPO##*/heads/}"; REF="${REF%.tar.gz}"
	[ -n "$SLUG" ] && [ -n "$REF" ]
}

# The commits endpoint returns the bare sha as text under this Accept header,
# so no JSON parsing is needed. Anything that is not a sha -- a rate-limit
# body, an HTML error page, nothing at all -- is discarded rather than shown.
remote_commit() {
	local sha
	sha="$(curl -sSL -m 25 -H 'Accept: application/vnd.github.sha' \
		"https://api.github.com/repos/$SLUG/commits/$REF" 2>/dev/null)"
	case "$sha" in
		"" | *[!0-9a-f]*) return 1 ;;
	esac
	[ "${#sha}" -ge 7 ] || return 1
	echo "$sha"
}

# --------------------------------------------------------------------------
# mihomo core
# --------------------------------------------------------------------------

# `uname -m` reports plain "mips" on both big- and little-endian MIPS, so it
# cannot tell mips-softfloat from mipsle-softfloat -- and installing the wrong
# endianness gives a binary that will not run. OpenWrt states the endianness
# in DISTRIB_ARCH (mipsel_24kc vs mips_24kc), so that is the primary source,
# with the ELF header as the fallback for anything that lacks it.

map_openwrt_arch() {
	case "$1" in
		aarch64_*)      echo "arm64" ;;
		x86_64)         echo "amd64-compatible" ;;
		i386_*)         echo "386" ;;
		mipsel_*)       echo "mipsle-softfloat" ;;
		mips_*)         echo "mips-softfloat" ;;
		mips64el_*)     echo "mips64le" ;;
		mips64_*)       echo "mips64" ;;
		riscv64_*)      echo "riscv64" ;;
		loongarch64_*)  echo "loong64-abi2" ;;
		arm_cortex-a5*|arm_cortex-a7*|arm_cortex-a8*|arm_cortex-a9*|arm_cortex-a1*)
		                echo "armv7" ;;
		arm_arm1176*|arm_mpcore*)
		                echo "armv6" ;;
		arm_*)          echo "armv5" ;;
		*) return 1 ;;
	esac
}

# EI_DATA, the sixth byte of any ELF file: 1 = little-endian, 2 = big-endian.
#
# Read without od or hexdump, neither of which is guaranteed on OpenWrt (this
# router has hexdump but no od at all). Deleting the candidate byte and
# measuring what is left identifies it using only tr and wc, which busybox
# always provides.
elf_endian() {
	for _probe in /bin/busybox /bin/sh /sbin/init /bin/cat; do
		[ -r "$_probe" ] || continue
		[ "$(dd if="$_probe" bs=1 skip=5 count=1 2>/dev/null | tr -d '\001' | wc -c | tr -d ' ')" = "0" ] && {
			echo "le"; return 0; }
		[ "$(dd if="$_probe" bs=1 skip=5 count=1 2>/dev/null | tr -d '\002' | wc -c | tr -d ' ')" = "0" ] && {
			echo "be"; return 0; }
	done
	return 1
}

map_uname_arch() {
	_end="$(elf_endian 2>/dev/null)"
	case "$(uname -m)" in
		aarch64)         echo "arm64" ;;
		x86_64)          echo "amd64-compatible" ;;
		armv7l|armv7)    echo "armv7" ;;
		armv6l)          echo "armv6" ;;
		armv5*)          echo "armv5" ;;
		mips64)          [ "$_end" = "le" ] && echo "mips64le" || echo "mips64" ;;
		mips64el)        echo "mips64le" ;;
		mips)            [ "$_end" = "le" ] && echo "mipsle-softfloat" || echo "mips-softfloat" ;;
		mipsel)          echo "mipsle-softfloat" ;;
		riscv64)         echo "riscv64" ;;
		loongarch64)     echo "loong64-abi2" ;;
		i386|i686)       echo "386" ;;
		*) return 1 ;;
	esac
}

map_arch() {
	# an explicit override always wins, for anything guessed wrong
	if [ -n "${MIHOMO_ARCH:-}" ]; then
		echo "$MIHOMO_ARCH"
		return 0
	fi

	_oa=""
	if [ -f /etc/openwrt_release ]; then
		_oa="$(sed -n "s/^DISTRIB_ARCH='\\(.*\\)'\$/\\1/p" /etc/openwrt_release | head -n1)"
	fi
	if [ -n "$_oa" ] && map_openwrt_arch "$_oa"; then
		return 0
	fi

	map_uname_arch
}

# The version of the binary on disk, which is not necessarily the version of
# the process that is running -- an upgrade without a restart leaves the two
# apart, which is exactly why the core update restarts a running daemon.
core_installed() {
	command -v mihomo >/dev/null 2>&1 || return 1
	mihomo -v 2>&1 | head -n1 | grep -o 'v[0-9][^[:space:]]*' | head -n1
}

core_latest() {
	curl -sSL -m 30 https://api.github.com/repos/MetaCubeX/mihomo/releases/latest 2>/dev/null \
		| sed -n 's/.*"tag_name"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' | head -n1
}

do_core_status() {
	local arch installed latest
	arch="$(map_arch 2>/dev/null)" || arch=""
	installed="$(core_installed 2>/dev/null)" || installed=""
	latest="$(core_latest)"

	echo "arch:      ${arch:-unknown}"
	echo "installed: ${installed:-none}"
	echo "latest:    ${latest:-unknown}"

	if [ -z "$latest" ] || [ -z "$installed" ]; then
		echo "update:    unknown"
	elif [ "$installed" = "$latest" ]; then
		echo "update:    current"
	else
		echo "update:    available"
	fi
}

do_core_install() {
	local want="$1"
	local arch ver url tmp running

	arch="$(map_arch)" || die "unsupported CPU architecture: $(uname -m) -- set MIHOMO_ARCH to name a build"

	ver="${want:-${MIHOMO_VERSION:-}}"
	if [ -z "$ver" ]; then
		echo "looking up the latest mihomo release"
		ver="$(core_latest)"
	fi
	[ -n "$ver" ] || die "could not determine the mihomo version (pass it as an argument, or set MIHOMO_VERSION)"

	tmp="/tmp/clashwrt-core.$$"
	rm -rf "$tmp"; mkdir -p "$tmp" || die "cannot create $tmp"

	# The new binary is staged next to the one it replaces, not in /tmp, and
	# swapped in with mv.
	#
	# Copying onto it directly cannot be done as a plain write: the kernel
	# returns ETXTBSY for an open-for-write on a file that is currently being
	# executed, which /usr/bin/mihomo is whenever the proxy is up. `cp -f`
	# gets past that by unlinking the destination and recreating it -- so it
	# works, but it spends a moment with no /usr/bin/mihomo at all, and if the
	# write then fails, which on an OpenWrt overlay means running out of
	# space, the router is left with no core. rename() has no such window: it
	# swaps the directory entry in one step, and the running process keeps the
	# inode it started from until it is restarted, which is the next thing
	# that happens here. Staging on the same filesystem is what makes it a
	# rename rather than a copy, so /tmp will not do.
	local staged="/usr/bin/.mihomo.clashwrt-new"
	rm -f "$staged"

	url="https://github.com/MetaCubeX/mihomo/releases/download/${ver}/mihomo-linux-${arch}-${ver}.gz"
	echo "downloading mihomo ${ver} for ${arch}"
	if ! curl -sSL --fail -m 300 -o "$tmp/mihomo.gz" "$url"; then
		rm -rf "$tmp" "$staged"
		die "download failed: $url"
	fi

	gzip -dc "$tmp/mihomo.gz" > "$staged" 2>/dev/null || {
		rm -rf "$tmp" "$staged"
		die "could not decompress the core (out of space on the overlay?)"
	}
	chmod 0755 "$staged"

	# A core that cannot run is worse than none, and this is the one check
	# that catches a wrongly guessed architecture before it takes the proxy
	# down rather than after.
	"$staged" -v >/dev/null 2>&1 || {
		rm -rf "$tmp" "$staged"
		die "the downloaded core does not run on this system (wrong architecture? set MIHOMO_ARCH)"
	}

	# Only decide about restarting once the replacement is known good.
	running=0
	pidof mihomo >/dev/null 2>&1 && running=1

	mv -f "$staged" /usr/bin/mihomo || { rm -rf "$tmp" "$staged"; die "could not install /usr/bin/mihomo"; }
	rm -rf "$tmp"

	echo "installed $(/usr/bin/mihomo -v 2>&1 | head -n1)"

	# The old binary keeps serving until the daemon is restarted, so leaving
	# it running would report a version nothing is actually using. A core
	# that was not running is left alone: this is an update, not a start.
	if [ "$running" = 1 ]; then
		echo "restarting mihomo"
		/etc/init.d/mihomo restart >/dev/null 2>&1 \
			|| echo "WARNING: mihomo did not come back up -- check the logs" >&2
	else
		echo "mihomo is not running; start it to use the new core"
	fi
}

# --------------------------------------------------------------------------
# clashwrt itself
# --------------------------------------------------------------------------

do_self_status() {
	load_info

	echo "repo:      $REPO"
	echo "installed: ${INST_COMMIT:-unknown}"
	echo "date:      ${INST_DATE:-unknown}"

	if ! parse_repo; then
		echo "ref:       unknown"
		echo "latest:    unknown"
		echo "update:    unknown"
		return 0
	fi

	echo "ref:       $REF"

	local latest
	latest="$(remote_commit)" || latest=""
	echo "latest:    ${latest:-unknown}"

	if [ -z "$latest" ] || [ -z "$INST_COMMIT" ]; then
		echo "update:    unknown"
	elif [ "$latest" = "$INST_COMMIT" ]; then
		echo "update:    current"
	else
		echo "update:    available"
	fi
}

do_self_update() {
	load_info
	parse_repo || die "cannot update automatically from $REPO -- re-run install.sh by hand"

	local url="https://raw.githubusercontent.com/$SLUG/$REF/install.sh"
	local script="/tmp/clashwrt-selfupdate.sh"
	local runner="/tmp/clashwrt-selfupdate-run.sh"

	rm -f "$script" "$runner"
	curl -sSL --fail -m 120 -o "$script" "$url" || die "could not download $url"
	[ -s "$script" ] || die "the downloaded installer is empty"

	# A truncated or redirected download would otherwise be executed as far
	# as it goes, part-way through replacing the installation.
	head -n 20 "$script" | grep -q 'One-shot installer for clashwrt' \
		|| die "what came back from $url is not the clashwrt installer"

	# The core is updated by its own button. Bundling it here would make one
	# button do two unrelated things, and hide a failed core download behind
	# a successful reinstall.
	cat > "$runner" <<RUNNER
#!/bin/sh
echo "=== clashwrt update started \$(date -u '+%Y-%m-%d %H:%M:%SZ') ==="
SKIP_CORE=1 REPO_URL='$REPO' sh '$script'
_rc=\$?
echo
echo "=== clashwrt update finished, rc=\$_rc ==="
RUNNER
	chmod +x "$runner"

	: > "$LOG"

	# setsid puts the installer in its own session, so the rpcd restart at
	# the end of install.sh cannot take down the process performing it.
	if command -v setsid >/dev/null 2>&1; then
		setsid "$runner" >"$LOG" 2>&1 </dev/null &
	else
		"$runner" >"$LOG" 2>&1 </dev/null &
	fi

	echo "update started; follow it with: updctl.sh log"
}

do_log() {
	[ -f "$LOG" ] && cat "$LOG" || echo "no update has been run yet"
}

case "${1:-}" in
	core-status)  do_core_status ;;
	core-install) do_core_install "${2:-}" ;;
	self-status)  do_self_status ;;
	self-update)  do_self_update ;;
	log)          do_log ;;
	*)
		echo "usage: $0 core-status|core-install [version]|self-status|self-update|log" >&2
		exit 1
		;;
esac
