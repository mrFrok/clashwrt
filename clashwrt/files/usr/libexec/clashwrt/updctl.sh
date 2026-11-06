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
# Usage: updctl.sh core-status|core-install [version]|core-store flash|gz|ram
#        updctl.sh core-use mihomo|meow [tiny|lightweight|full]
#        updctl.sh core-prepare|cores|prune-cores
#        updctl.sh self-status|self-update|log
#
# CLASHWRT_TMPDIR names a directory to unpack the core in ahead of /tmp.

SLUG_DEFAULT="mrFrok/clashwrt"
# Releases are the default channel: a router should not pick up whatever landed
# on the branch an hour ago. An install that came from a branch keeps tracking
# that branch, because switching channels under someone is not an update.
REPO_DEFAULT=""
INFO="${CLASHWRT_INFO:-/usr/libexec/clashwrt/.install-info}"
LOG="/tmp/clashwrt-update.log"
# Where the core lives; overridden only by the tests.
BIN_DIR="${CLASHWRT_BIN_DIR:-/usr/bin}"
CORE_BIN="$BIN_DIR/mihomo"
CORE_INIT="${CLASHWRT_CORE_INIT:-/etc/init.d/mihomo}"
# meow-openwrt, the other core: installed as an OpenWrt package, which puts
# it in /usr/bin/meow; /usr/bin/mihomo is then a link to it, so everything
# that starts or looks for "mihomo" by name finds it.
MEOW_SLUG="mrFrok/meow-openwrt"
MEOW_BIN="$BIN_DIR/meow"
# where opkg and apk keep what is installed; overridden only by the tests
PKG_ROOT="${CLASHWRT_PKG_ROOT:-}"

die() { echo "ERROR: $*" >&2; exit 1; }

# Downloads go through the proxy first (net.sh); a copy of this script run
# on its own, without net.sh beside it, fetches directly.
CW_NET="${CLASHWRT_LIBEXEC:-$(dirname "$0")}/net.sh"
if [ -f "$CW_NET" ]; then
	# shellcheck source=net.sh
	. "$CW_NET"
else
	cw_proxy_url() { return 1; }
	cw_curl() { curl "$@"; }
fi


# --------------------------------------------------------------------------
# where this copy came from
# --------------------------------------------------------------------------

# install.sh records the branch head it installed. A copy installed from the
# OpenWrt package feed has no such file: report what is knowable rather than
# guessing, and leave the update button working for whoever wants it.
load_info() {
	REPO="$REPO_DEFAULT"
	INST_COMMIT=""
	INST_VERSION=""
	INST_DATE=""

	[ -f "$INFO" ] || return 0
	while IFS='=' read -r k v; do
		case "$k" in
			repo)   [ -n "$v" ] && REPO="$v" ;;
			commit)  INST_COMMIT="$v" ;;
			version) INST_VERSION="$v" ;;
			date)   INST_DATE="$v" ;;
		esac
	done < "$INFO"
}

# Split https://github.com/<owner>/<name>/archive/refs/heads/<ref>.tar.gz into
# the slug and ref the API needs. Anything else -- a private mirror, a local
# file, a release tarball -- is updatable but not checkable, and says so.
parse_repo() {
	SLUG=""; REF=""; KIND=""
	case "$REPO" in
		https://github.com/*/archive/refs/heads/*.tar.gz)
			KIND="heads"
			REF="${REPO##*/heads/}"; REF="${REF%.tar.gz}"
			;;
		https://github.com/*/archive/refs/tags/*.tar.gz)
			KIND="tags"
			REF="${REPO##*/tags/}"; REF="${REF%.tar.gz}"
			;;
		https://github.com/*/releases/download/*/clashwrt-*.tar.gz)
			# what 1.4.0 and 1.4.1 recorded: the release's own tarball
			KIND="tags"
			REF="${REPO##*/download/}"; REF="${REF%%/*}"
			SLUG="${REPO#https://github.com/}"; SLUG="${SLUG%%/releases/*}"
			[ -n "$SLUG" ] && [ -n "$REF" ]
			return
			;;
		"")
			# nothing recorded: this copy predates channels, or came from the
			# package feed. Treat it as following releases.
			SLUG="$SLUG_DEFAULT"; KIND="tags"; REF="${INST_VERSION:-unknown}"
			return 0
			;;
		*) return 1 ;;
	esac
	SLUG="${REPO#https://github.com/}"; SLUG="${SLUG%%/archive/*}"
	[ -n "$SLUG" ] && [ -n "$REF" ]
}

# The newest published release, by tag name. Anything that is not a plausible
# tag -- a rate-limit body, an error page, a repository with no releases yet --
# is discarded rather than shown as a version.
remote_tag() {
	local t
	t="$(cw_curl -sSL -m 25 "https://api.github.com/repos/$SLUG/releases/latest" 2>/dev/null \
		| sed -n 's/.*"tag_name"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' | head -n1)"
	case "$t" in
		"" | *[!A-Za-z0-9._-]*) return 1 ;;
	esac
	echo "$t"
}

# The commits endpoint returns the bare sha as text under this Accept header,
# so no JSON parsing is needed. Anything that is not a sha -- a rate-limit
# body, an HTML error page, nothing at all -- is discarded rather than shown.
remote_commit() {
	local sha
	sha="$(cw_curl -sSL -m 25 -H 'Accept: application/vnd.github.sha' \
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
	local t
	t="$(cw_curl -sSL -m 30 https://api.github.com/repos/MetaCubeX/mihomo/releases/latest 2>/dev/null \
		| sed -n 's/.*"tag_name"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' | head -n1)"
	valid_tag "$t" && echo "$t"
}

# A release tag goes into the download URL twice, so it must be a tag and
# nothing else: no '/', '..', '#' or '?' that could point the download of a
# file that is then run as root somewhere other than mihomo's releases.
valid_tag() {
	case "$1" in
		""|*[!A-Za-z0-9._-]*|*..*|[.-]*) return 1 ;;
	esac
	[ "${#1}" -le 64 ]
}

# Where the core is, without asking GitHub anything: for the Storage tab.
do_core_where() {
	echo "core:      $(core_live_type)"
	meow_live && echo "profile:   $(meow_live_profile)"
	echo "store:     $(core_store)"
	if meow_live; then
		echo "location:  flash $(size_kb "$MEOW_BIN")K"
	elif [ -L "$CORE_BIN" ]; then
		echo "location:  ram $(size_kb "$RAM_CORE")K$( [ -f "$STORE_GZ" ] && echo ", packed on flash $(size_kb "$STORE_GZ")K")"
	elif [ -f "$CORE_BIN" ]; then
		echo "location:  flash $(size_kb "$CORE_BIN")K"
	else
		echo "location:  none"
	fi
	echo "flash:     $(avail_kb "$BIN_DIR")K free"
	echo "ram:       $(meminfo_kb MemAvailable)K available of $(meminfo_kb MemTotal)K"
}

do_core_status() {
	local arch installed latest
	if meow_live; then
		arch="$(meow_arch 2>/dev/null)" || arch=""
		installed="$(meow_installed 2>/dev/null)" || installed=""
		latest="$(meow_latest)"
	else
		arch="$(map_arch 2>/dev/null)" || arch=""
		installed="$(core_installed 2>/dev/null)" || installed=""
		latest="$(core_latest)"
	fi

	echo "arch:      ${arch:-unknown}"
	echo "installed: ${installed:-none}"
	echo "latest:    ${latest:-unknown}"
	do_core_where

	if [ -z "$latest" ] || [ -z "$installed" ]; then
		echo "update:    unknown"
	elif [ "$installed" = "$latest" ]; then
		echo "update:    current"
	else
		echo "update:    available"
	fi
}

# --------------------------------------------------------------------------
# room for a new core
# --------------------------------------------------------------------------
#
# A core is ~45 MB unpacked, which is a lot on both of the places it passes
# through: /tmp is RAM, and the overlay behind /usr/bin is often tens of MB
# all told. Running out halfway through either leaves a truncated file, and
# running out while replacing /usr/bin/mihomo leaves a router with no core.
# So the room is measured before anything is downloaded, and again before
# anything is replaced.

# Available kilobytes on the filesystem holding $1. The device column wraps
# onto its own line when the name is long, so the Available column is found
# relative to the field ending in "%" rather than by a fixed position.
avail_kb() {
	df -k "$1" 2>/dev/null |
		awk 'END { for (i = 1; i <= NF; i++) if ($i ~ /%$/) { print $(i-1); exit } }'
}

# The mount point of the filesystem holding $1: the last field of df's
# last line, whether or not the device column wrapped.
mount_of() {
	df -k "$1" 2>/dev/null | awk 'END { print $NF }'
}

# The type and options /proc/mounts lists for mount point $1, the last entry
# winning as it does for the kernel.
mount_info() {
	awk -v m="$1" '$2 == m { t = $3 " " $4 } END { print t }' /proc/mounts 2>/dev/null
}

size_kb() {
	local n
	[ -f "$1" ] || { echo 0; return; }
	n="$(wc -c < "$1")" || n=0
	echo $(( ${n:-0} / 1024 ))
}

# MemAvailable in kB. A file in tmpfs is held in RAM, and df on a tmpfs only
# reports its size limit (half the RAM by default), not what is actually free
# with mihomo itself loaded.
mem_avail_kb() {
	awk '/^MemAvailable:/ { print $2; f = 1 } END { if (!f) print 0 }' /proc/meminfo 2>/dev/null
}

# RAM left over for everything else when the core is unpacked into tmpfs.
MEM_RESERVE_KB=16384

# What a candidate directory can actually take: free space, and for a RAM
# filesystem also what the RAM can spare.
usable_kb() {
	local dir="$1" a m mp
	a="$(avail_kb "$dir")"
	case "$a" in ''|*[!0-9]*) echo 0; return ;; esac
	mp="$(mount_of "$dir")"
	case "$(mount_info "$mp")" in
		tmpfs\ *|ramfs\ *)
			m=$(( $(mem_avail_kb) - MEM_RESERVE_KB ))
			[ "$m" -lt "$a" ] && a="$m"
			;;
	esac
	[ "$a" -gt 0 ] || a=0
	echo "$a"
}

# Where the core may be unpacked, best first, one per line: an explicit
# CLASHWRT_TMPDIR, then /tmp, then anything else mounted read-write that can
# run programs -- a USB stick, an extroot, a data partition. The overlay
# itself comes last, as /usr/bin: a core unpacked there costs the same room
# as the staged copy it would need anyway, and is renamed into place.
#
# The candidate must allow exec, because the downloaded core is run once
# (mihomo -v) to prove it suits this CPU before anything is replaced.
work_candidates() {
	local usr_mp
	usr_mp="$(mount_of "$BIN_DIR")"
	{
		[ -n "${CLASHWRT_TMPDIR:-}" ] && echo "$CLASHWRT_TMPDIR"
		echo /tmp
		awk '$4 ~ /(^|,)rw(,|$)/ && $4 !~ /(^|,)noexec(,|$)/ { print $2 }' /proc/mounts 2>/dev/null
	} | while read -r d; do
		case "$d" in
			/|/rom|/rom/*|/overlay|/overlay/*|/proc|/proc/*|/sys|/sys/*|/dev|/dev/*) continue ;;
			*\\*) continue ;;            # /proc/mounts escapes spaces as \040
		esac
		[ -d "$d" ] || continue
		# a directory on the overlay is /usr/bin's case, handled last
		[ "$(mount_of "$d")" = "$usr_mp" ] && continue
		case " $(mount_info "$(mount_of "$d")") " in
			*,noexec,*|*\ noexec,*|*,noexec\ *|*\ noexec\ *) continue ;;
		esac
		echo "$d"
	done | awk '!seen[$0]++'
	echo "$BIN_DIR"
}

# Does the filesystem /usr/bin writes to compress what it stores? UBIFS (NAND)
# and JFFS2 (NOR) do, 4 KiB at a time, and df on them counts free space as if
# nothing compressed: a 56 MB core goes onto 36 MB "free". Under overlayfs it
# is the upper layer's filesystem that takes the writes.
flash_compresses() {
	local info up
	case "${CLASHWRT_FLASH_COMPRESSES:-}" in 1) return 0 ;; 0) return 1 ;; esac
	info="$(mount_info "$(mount_of "$BIN_DIR")")"
	case "$info" in overlay\ *)
		up="$(echo "$info" | sed -n 's/.*upperdir=\([^,]*\).*/\1/p')"
		[ -n "$up" ] && info="$(mount_info "$(mount_of "$up")")"
		;;
	esac
	case "$info" in *compr=none*) return 1 ;; ubifs\ *|jffs2\ *) return 0 ;; esac
	return 1
}

# What $1 kB of core takes on that filesystem. LZO, the weakest compressor
# UBIFS uses, packs a mihomo build to 0.59 of itself block by block (zlib
# 0.45), so three fifths; elsewhere all of it. The old and spare cores, being
# the same kind of file, free the same share.
disk_kb() {
	if flash_compresses; then echo $(( $1 * 3 / 5 )); else echo "$1"; fi
}

# Kilobytes of spare cores prune_old_cores would remove, i.e. room that can
# be had back on the overlay without touching anything in use.
spare_cores_kb() {
	local f t=0
	[ "${KEEP_OLD_CORES:-0}" = "1" ] && { echo 0; return; }
	for f in "$BIN_DIR"/mihomo?*; do
		[ -f "$f" ] || continue
		core_in_use "$f" && continue
		is_elf "$f" || continue
		"$f" -v 2>&1 | head -n1 | grep -qi mihomo || continue
		t=$(( t + $(size_kb "$f") ))
	done
	echo "$t"
}

# The download size of $1 in kB, from the Content-Length of the final
# response after GitHub's redirect. Empty when the server does not say.
remote_bytes() {
	local n
	n="$(cw_curl -sSIL -m 30 "$1" 2>/dev/null | tr -d '\r' |
		sed -n 's/^[Cc]ontent-[Ll]ength:[[:space:]]*\([0-9][0-9]*\)$/\1/p' | tail -n1)"
	[ -n "$n" ] && [ "$n" -gt 0 ] && echo "$n"
}

# Kilobytes the .gz at $1 ($2 bytes long) unpacks to, without downloading it:
# gzip ends with the unpacked size in four little-endian bytes, and GitHub's
# asset store serves a byte range, so four bytes tell. Anything but exactly
# four bytes back (no od, a server that ignores ranges) gives nothing.
gz_unpacked_kb() {
	local b n
	[ -n "$2" ] && [ "$2" -gt 4 ] || return 1
	b="$(cw_curl -sSL --fail -m 30 -r "$(( $2 - 4 ))-$(( $2 - 1 ))" "$1" 2>/dev/null | od -An -v -tu1 2>/dev/null)" || return 1
	# shellcheck disable=SC2086
	set -- $b
	[ $# -eq 4 ] || return 1
	n=$(( $1 + $2 * 256 + $3 * 65536 + $4 * 16777216 ))
	[ "$n" -gt 0 ] || return 1
	echo $(( (n + 1023) / 1024 ))
}

# Kilobytes the unpacked core will need when gz_unpacked_kb cannot tell. This only
# decides whether a download is worth starting -- the real size is checked
# again once the core is unpacked -- so it must not refuse a router that has
# the room. The core already installed is the same program and the best
# guide: a release grows it by a few percent, not by an eighth. Without one,
# a Go binary compresses to roughly a third, so three times the .gz is a
# ceiling; with neither, 64 MB covers every build mihomo publishes today.
estimate_core_kb() {
	local gz="$1" cur=0
	# meow is a fifth of mihomo's size, no guide to it
	meow_live || cur="$(size_kb "$CORE_BIN")"
	if [ "$cur" -gt 0 ]; then
		echo $(( cur + cur / 8 ))
	elif [ -n "$gz" ]; then
		echo $(( gz * 3 ))
	else
		echo 65536
	fi
}

# Can /usr/bin take a core of $1 kB? Prints how, or fails:
#   stage    a second copy fits beside the old one: copy, then rename (atomic)
#   inplace  only after the old one is gone: overwrite it
#   stop     like inplace, but the old one is running and holds its blocks
#            until it exits, so mihomo has to stop first
# A running binary keeps its disk blocks after it is overwritten or renamed
# over, until the process exits; only a core that is not running gives its
# room back on the spot.
install_plan() {
	local need=$(( $(disk_kb "$1") + 1024 )) avail old=0
	avail="$(usable_kb "$BIN_DIR")"
	old="$(disk_kb "$(flash_core_kb)")"

	if [ "$avail" -ge "$need" ]; then
		echo stage
	elif [ $(( avail + old )) -ge "$need" ]; then
		if core_in_use "$CORE_BIN"; then echo stop; else echo inplace; fi
	else
		return 1
	fi
}

install_room_error() {
	echo "ERROR: not enough room in $BIN_DIR for the new core: it needs about $(disk_kb "$1")K there," \
		"there is $(usable_kb "$BIN_DIR")K free and the current core frees $(disk_kb "$(flash_core_kb)")K." \
		"Free some space on the overlay (opkg remove, or delete files you added) and try again." >&2
}

# Before the download: could the overlay take a core of $1 kB at all, counting
# the old core and any spare ones as room? Nothing is removed here -- a
# download that then fails must not have cost anyone the cores they kept.
install_possible() {
	local need=$(( $(disk_kb "$1") + 1024 )) have
	have=$(( $(usable_kb "$BIN_DIR") + $(disk_kb $(( $(flash_core_kb) + $(spare_cores_kb) ))) ))
	[ "$have" -ge "$need" ] && return 0
	install_room_error "$1"
	return 1
}

# After the download, with the new core in hand: room on the overlay, freeing
# spare cores if that is what it takes. Prints the plan; fails with the
# numbers when even that is not enough.
ensure_install_room() {
	local kb="$1" plan
	plan="$(install_plan "$kb")" && { echo "$plan"; return 0; }

	if [ "$(spare_cores_kb)" -gt 0 ]; then
		echo "the overlay is short of room; removing spare cores first" >&2
		prune_old_cores >&2
		plan="$(install_plan "$kb")" && { echo "$plan"; return 0; }
	fi

	install_room_error "$kb"
	return 1
}

# The first candidate that can hold $1 kB, or fail listing what each had.
pick_workdir() {
	local need="$1" d free tried=""
	for d in $(work_candidates); do
		free="$(usable_kb "$d")"
		if [ "$free" -ge "$need" ] && [ -w "$d" ]; then
			echo "$d"
			return 0
		fi
		tried="$tried $d=${free}K"
	done
	echo "ERROR: nowhere to unpack the core: it needs about ${need}K and the candidates have$tried." \
		"Free some RAM or space, or set CLASHWRT_TMPDIR to a directory with room." >&2
	return 1
}

# Replacing /usr/bin/mihomo cannot be a plain write while the daemon is up:
# the kernel returns ETXTBSY for an open-for-write on a running executable.
# How it is done is decided by install_plan, and said out loud:
#
# A core unpacked on the overlay already is simply renamed into place (move).
#
# Staging a copy alongside and renaming over the target is atomic -- either
# the old core or the new one is there, never neither -- but it needs room for
# a second copy on the same filesystem. On an OpenWrt overlay that is the
# unusual case, not the usual one: 46 MB of core against 41 MB free is what a
# BPI-R4 with a full-ish overlay actually looks like.
#
# `cp -f` over the old file needs no extra room once the old one's blocks are
# free, but that leaves a moment with no core at all -- and if the write then
# fails, the router stays that way. That is why the room is checked first.
install_core_binary() {
	local src="$1" plan="$2" backup
	local staged="$BIN_DIR/.mihomo.clashwrt-new" i=0

	rm -f "$staged"

	case "$plan" in
	move)
		mv -f "$src" "$CORE_BIN" && return 0
		echo "ERROR: could not move the new core into $BIN_DIR; the old core is untouched" >&2
		return 1
		;;
	stage)
		if cp -f "$src" "$staged" && chmod 0755 "$staged" && mv -f "$staged" "$CORE_BIN"; then
			return 0
		fi
		rm -f "$staged"
		echo "ERROR: could not stage a copy in $BIN_DIR; the old core is untouched" >&2
		return 1
		;;
	stop)
		echo "the overlay has room for one core only; stopping mihomo while it is replaced"
		"$CORE_INIT" stop >/dev/null 2>&1
		while core_in_use "$CORE_BIN" && [ "$i" -lt 10 ]; do
			sleep 1
			i=$((i + 1))
		done
		core_in_use "$CORE_BIN" && {
			echo "ERROR: mihomo did not stop, so its blocks cannot be reused; the old core is untouched" >&2
			return 1
		}
		;;
	inplace)
		echo "not enough room in $BIN_DIR for a second copy; replacing in place"
		;;
	esac

	# meow's room is only had back by removing its package
	if meow_live; then
		echo "removing meow-openwrt to make room"
		meow_remove_pkgs || { echo "ERROR: could not remove the meow-openwrt package; the old core is untouched" >&2; return 1; }
	fi
	# a link into RAM (or to meow) is replaced, not written through
	[ -L "$CORE_BIN" ] && rm -f "$CORE_BIN"
	# On a compressing flash the room was an estimate. A copy of the old core
	# in RAM, where there is room for one, brings it back if the write runs
	# out of space: the half-written file goes first and frees what it took.
	backup=""
	if [ -f "$CORE_BIN" ] && flash_compresses && ! ram_no_room "$(size_kb "$CORE_BIN")" >/dev/null; then
		mkdir -p "${RAM_DIR%/*}" && backup="${RAM_DIR}.old-core" && cp -f "$CORE_BIN" "$backup" || { rm -f "$backup"; backup=""; }
	fi
	if ! cp -f "$src" "$CORE_BIN"; then
		rm -f "$CORE_BIN"
		if [ -n "$backup" ] && cp -f "$backup" "$CORE_BIN"; then
			chmod 0755 "$CORE_BIN"
			echo "ERROR: $BIN_DIR ran out of room for the new core; the old core is back" >&2
		else
			rm -f "$CORE_BIN"
			echo "ERROR: could not install $CORE_BIN; there is no core on flash now (Settings -> Storage can keep it in RAM)" >&2
		fi
		rm -f "$backup"
		return 1
	fi
	rm -f "$backup"
	chmod 0755 "$CORE_BIN"
}

# Is this exact file the binary behind a process that is running right now?
# Unlinking one out from under a running process is survivable on Linux, but
# it makes `restart` reach for a file that is no longer there, so it is not
# something to do casually.
core_in_use() {
	local target p
	# /usr/bin/mihomo may be a link to the core in RAM, which is what runs
	target="$(readlink -f "$1" 2>/dev/null)" || target="$1"
	[ -n "$target" ] || target="$1"
	for p in /proc/[0-9]*; do
		[ "$(readlink "$p/exe" 2>/dev/null)" = "$target" ] && return 0
	done
	return 1
}

# Asking a file for its version runs it, as root, so only ELF executables are
# asked: a script or anything else named mihomo-something is left alone.
is_elf() {
	[ -f "$1" ] && [ ! -L "$1" ] && [ "$(dd if="$1" bs=1 skip=1 count=3 2>/dev/null)" = "ELF" ]
}

# Every mihomo binary sitting in /usr/bin, live one included.
#
# Prints: path, size in KB, version, and what it is. A file that will not run
# or will not identify itself is listed as "not a mihomo binary" and, more to
# the point, is never a candidate for removal.
list_cores() {
	local f r sz ver what name
	for f in "$BIN_DIR"/mihomo*; do
		[ -f "$f" ] || continue
		case "$f" in "$BIN_DIR"/.*) continue ;; esac

		# the live core may be a link to the copy in RAM (core_store)
		r="$f"; name="$f"
		if [ "$f" = "$CORE_BIN" ] && [ -L "$f" ]; then
			r="$(readlink -f "$f")"; name="$f -> $r"
		fi
		sz=$(( $(wc -c < "$r") / 1024 ))
		ver=""
		is_elf "$r" && ver="$("$r" -v 2>&1 | head -n1 | grep -o 'v[0-9][^[:space:]]*' | head -n1)"
		# the live core may be meow-openwrt, which says "Meow Meta 0.29.0"
		[ "$f" = "$CORE_BIN" ] && meow_live && ver="$(meow_installed)"

		if is_elf "$r" && "$r" -v 2>&1 | head -n1 | grep -qiE 'mihomo|meow meta'; then
			if [ "$f" = "$CORE_BIN" ]; then
				what="live"
				core_in_use "$f" && what="live, running"
			elif core_in_use "$f"; then
				what="running"
			else
				what="unused"
			fi
		else
			what="not a mihomo binary"
			ver=""
		fi

		printf '%-34s %8sK  %-12s %s\n' "$name" "$sz" "${ver:-?}" "$what"
	done
}

# Spare cores in /usr/bin are the single biggest thing on an OpenWrt overlay.
# A Go binary carries its whole runtime, so each one is ~45 MB, and they
# accumulate because keeping the old one before an upgrade is the obvious
# thing to do by hand -- three spare copies is most of a 308 MB overlay.
#
# What this removes is deliberately narrow: the file must be in /usr/bin, be
# named mihomo-something, not be the live /usr/bin/mihomo, not be executing,
# and identify itself as Mihomo when asked. A differently named proxy core
# next to it -- sing-box being the one people actually have -- is never a
# candidate, whatever else is true of it. Nothing is removed silently: every
# deletion is printed with what it reclaimed, and KEEP_OLD_CORES=1 turns the
# whole thing off.
prune_old_cores() {
	local f sz n=0 freed=0

	if [ "${KEEP_OLD_CORES:-0}" = "1" ]; then
		return 0
	fi

	for f in "$BIN_DIR"/mihomo*; do
		[ -f "$f" ] || continue
		[ "$f" = "$CORE_BIN" ] && continue
		case "$f" in "$BIN_DIR"/.*) continue ;; esac

		core_in_use "$f" && { echo "keeping $f: it is running"; continue; }
		is_elf "$f" || continue
		"$f" -v 2>&1 | head -n1 | grep -qi mihomo || continue

		sz=$(( $(wc -c < "$f") / 1024 ))
		if rm -f "$f"; then
			n=$((n + 1))
			freed=$((freed + sz))
			echo "removed $f (${sz}K)"
		fi
	done

	[ "$n" -gt 0 ] && echo "reclaimed ${freed}K from ${n} spare core(s)"
	return 0
}

# --------------------------------------------------------------------------
# where the core is kept
# --------------------------------------------------------------------------
#
# A core is ~55 MB, more than many routers have left on flash. core_store
# says where it is kept between boots:
#
#   flash  /usr/bin/mihomo, as it always was
#   gz     the release's .gz (~22 MB) in $STORE_DIR, unpacked into RAM at boot
#   ram    only a note of the version on flash; downloaded into RAM at every
#          boot, so a boot without GitHub is a boot without a core until a
#          retry gets through
#
# With gz and ram, /usr/bin/mihomo is a symlink into $RAM_DIR, so everything
# that runs "mihomo" by name finds it either way. RAM is taken only while there
# is clearly room for it, by the measure provctl.sh uses for providers.

STORE_DIR="${CLASHWRT_STORE_DIR:-/etc/clashwrt/store}"
RAM_DIR="${CLASHWRT_RAM_DIR:-/tmp/clashwrt-core}"
RAM_CORE="$RAM_DIR/mihomo"
STORE_GZ="$STORE_DIR/mihomo.gz"
# One line, "<version> <asset> <GitHub's SHA-256 of it> <SHA-256 of mihomo.gz>",
# '-' for what is not known: what ram downloads at boot and checks it against,
# and what gz's file must still hash to before it is unpacked.
STORE_NOTE="$STORE_DIR/mihomo.note"
RETRY_PID="$RAM_DIR.retry.pid"
MEMINFO="${CLASHWRT_MEMINFO:-/proc/meminfo}"
# A "256 MB" router reports less in MemTotal (the kernel and Wi-Fi firmware
# keep their share: an AX3000T shows about 230 MB), so 192 MB is the line.
MIN_RAM_KB=196608

core_store() {
	case "$(uci -q get clashwrt.config.core_store)" in
		gz) echo gz ;; ram) echo ram ;; *) echo flash ;;
	esac
}

meminfo_kb() { awk -v k="$1:" '$1 == k { print $2; f = 1 } END { if (!f) print 0 }' "$MEMINFO" 2>/dev/null; }

# Why RAM cannot take $1 KB more, or nothing (and failure) when it can: the
# router has 256 MB or more, MemAvailable stays at max(32 MB, 15 % of RAM)
# after it, and /tmp keeps a quarter of itself free.
ram_no_room() {
	local need=$(( $1 + 1024 )) total avail floor tfree tsize
	total="$(meminfo_kb MemTotal)"
	avail="$(meminfo_kb MemAvailable)"
	[ "$total" -ge "$MIN_RAM_KB" ] || { echo "the router has under 256 MB of RAM"; return 0; }
	floor=$((total * 15 / 100)); [ "$floor" -ge 32768 ] || floor=32768
	[ $((avail - need)) -ge "$floor" ] || { echo "too little free RAM (${avail}K free, ${need}K needed, ${floor}K kept spare)"; return 0; }
	mkdir -p "$RAM_DIR" 2>/dev/null
	tfree="$(avail_kb "$RAM_DIR")"
	tsize="$(df -k "$RAM_DIR" 2>/dev/null | awk 'END { for (i = 1; i <= NF; i++) if ($i ~ /%$/) { print $(i-3); exit } }')"
	case "$tfree$tsize" in ''|*[!0-9]*) echo "cannot measure $RAM_DIR"; return 0 ;; esac
	[ $((tfree - need)) -ge $((tsize / 4)) ] || { echo "$(mount_of "$RAM_DIR") is nearly full"; return 0; }
	return 1
}

# A core sitting in RAM that runs and says it is mihomo.
core_ready() {
	[ -x "$RAM_CORE" ] && "$RAM_CORE" -v 2>&1 | head -n1 | grep -qi mihomo
}

link_core() {
	[ "$(readlink "$CORE_BIN" 2>/dev/null)" = "$RAM_CORE" ] || ln -sf "$RAM_CORE" "$CORE_BIN"
}

# The core on flash, as a regular file, or nothing. meow counts: a mihomo
# that replaces it removes its package first if that is what the room takes.
flash_core_kb() {
	if [ -f "$CORE_BIN" ] && [ ! -L "$CORE_BIN" ]; then size_kb "$CORE_BIN"
	elif meow_live; then size_kb "$MEOW_BIN"
	else echo 0; fi
}

version_of() {
	"$1" -v 2>&1 | head -n1 | grep -o 'v[0-9][^[:space:]]*' | head -n1
}

# Downloads release asset $1 into $2/mihomo, unpacked, checking the .gz
# against SHA-256 $3 (unless empty) and keeping a copy of it as $4 (unless
# empty). Through the proxy first and directly second (see net.sh). Leaves
# the .gz's hash in $2/gz.sha. Run in a subshell: it dies on failure.
fetch_core() {
	local url="$1" tmp="$2" want="$3" keep="$4" route proxy gz_rc shapid got why
	for route in proxy direct; do
		proxy=""
		if [ "$route" = proxy ]; then
			proxy="$(cw_proxy_url)" || continue
			echo "downloading ${url##*/} through the proxy"
		else
			echo "downloading ${url##*/}"
		fi
		rm -f "$tmp/curl.failed" "$tmp/mihomo" "$tmp/gz.fifo" "$tmp/gz.sha"
		# Downloaded, hashed and unpacked in one stream, so neither the .gz
		# nor the check needs room of its own; the hash is taken through a
		# fifo as the bytes go past. gzip checks the CRC at the end of the
		# stream, so a cut-off download fails here instead of leaving a
		# truncated core. Each route starts the pipeline afresh rather than
		# appending to what a failed one left behind.
		mkfifo "$tmp/gz.fifo" || die "cannot create a fifo in $tmp"
		sha256_of < "$tmp/gz.fifo" > "$tmp/gz.sha" &
		shapid=$!
		{ curl ${proxy:+--proxy "$proxy"} -sSL --fail --proto '=https' -m 300 "$url" 2>"$tmp/curl.err" ||
			: > "$tmp/curl.failed"; } |
			tee "$tmp/gz.fifo" ${keep:+"$keep"} |
			gzip -dc > "$tmp/mihomo" 2>"$tmp/gzip.err"
		gz_rc=$?
		wait "$shapid"
		[ ! -e "$tmp/curl.failed" ] && [ "$gz_rc" = 0 ] && break
		[ "$route" = proxy ] && echo "that failed; trying directly"
	done
	if [ -e "$tmp/curl.failed" ]; then
		why="$(awk 'NF { print; exit }' "$tmp/curl.err" 2>/dev/null)"
		die "download failed: $url${why:+ ($why)}"
	fi
	# Report what gzip actually said rather than guessing at a cause. It
	# opens with a blank line, so take the first line that has something on
	# it. A full disk shows up here too.
	if [ "$gz_rc" != 0 ]; then
		why="$(awk 'NF { print; exit }' "$tmp/gzip.err" 2>/dev/null)"
		die "could not decompress the core${why:+: $why}"
	fi
	got="$(cat "$tmp/gz.sha" 2>/dev/null)"
	if [ -n "$want" ] && [ "$got" != "$want" ]; then
		die "SHA-256 mismatch for ${url##*/}: GitHub says $want, the download is ${got:-unreadable}; nothing was installed"
	fi
	[ -n "$want" ] && echo "SHA-256 checked: $got"
	chmod 0755 "$tmp/mihomo"
	# A core that cannot run is worse than none, and this is the one check
	# that catches a wrongly guessed architecture before it takes the proxy
	# down rather than after.
	"$tmp/mihomo" -v >/dev/null 2>&1 ||
		die "the downloaded core does not run on this system (wrong architecture? set MIHOMO_ARCH)"
}

core_url() { echo "https://github.com/MetaCubeX/mihomo/releases/download/$1/$2"; }

restart_if_running() {
	if [ "$1" = 1 ]; then
		echo "restarting mihomo"
		"$CORE_INIT" restart >/dev/null 2>&1 \
			|| echo "WARNING: mihomo did not come back up -- check the logs" >&2
	else
		echo "mihomo is not running; start it to use the new core"
	fi
}

do_core_install() {
	local want="$1"
	local arch ver url tmp running need work plan asset want_sha mode keep="" gzkb gzb why

	if [ "$(core_type)" = meow ]; then
		do_meow_install "$want"
		return
	fi
	# a version named for the other core is a mistake, not a mihomo release
	case "$want" in owrt-*) die "$want is a meow-openwrt release; switch with: $0 core-use meow" ;; esac

	arch="$(map_arch)" || die "unsupported CPU architecture: $(uname -m) -- set MIHOMO_ARCH to name a build"
	mode="$(core_store)"

	ver="${want:-${MIHOMO_VERSION:-}}"
	if [ -z "$ver" ]; then
		echo "looking up the latest mihomo release"
		ver="$(core_latest)"
	fi
	[ -n "$ver" ] || die "could not determine the mihomo version (pass it as an argument, or set MIHOMO_VERSION)"
	valid_tag "$ver" || die "not a release tag: $ver"

	asset="mihomo-linux-${arch}-${ver}.gz"
	url="$(core_url "$ver" "$asset")"

	# What the .gz must hash to, asked before anything is downloaded. A core
	# that cannot be checked is not installed unless core_verify is '0'.
	want_sha="$(asset_digest MetaCubeX/mihomo "$ver" "$asset")"
	if [ -z "$want_sha" ]; then
		[ "$(uci -q get clashwrt.config.core_verify)" = 0 ] ||
			die "GitHub did not give the SHA-256 of $asset, so the download cannot be checked (set core_verify to '0' in /etc/config/clashwrt to install it unchecked)"
		echo "WARNING: installing $asset without a SHA-256 check (core_verify is '0')" >&2
	fi

	# Everything about room is settled before the download, so a router that
	# cannot take the core finds out in a second, not after a minute of
	# downloading -- and nothing has been touched when it does.
	gzkb=""
	gzb="$(remote_bytes "$url")" && gzkb=$(( gzb / 1024 ))
	need="$(gz_unpacked_kb "$url" "$gzb")" || need="$(estimate_core_kb "$gzkb")"
	if [ "$mode" = flash ]; then
		install_possible "$need" || exit 1
		work="$(pick_workdir "$need")" || exit 1
		echo "unpacking in $work (about ${need}K needed, $(usable_kb "$work")K usable)"
	else
		# a core already in RAM stays there until mihomo restarts on the new one
		why="$(ram_no_room "$need")" &&
			die "no room in RAM for the core: $why. Keep it on flash instead (Settings -> Storage)"
		if [ "$mode" = gz ]; then
			mkdir -p "$STORE_DIR" || die "cannot create $STORE_DIR"
			[ -n "$gzkb" ] || gzkb=$(( need * 2 / 5 ))
			[ $(( $(avail_kb "$STORE_DIR") + $(size_kb "$STORE_GZ") )) -ge $(( gzkb + 1024 )) ] ||
				die "not enough room on flash for the packed core: it needs about $((gzkb + 1024))K, $(avail_kb "$STORE_DIR")K is free"
			keep="$STORE_GZ.new"
		fi
		work="$RAM_DIR"
		mkdir -p "$work" || die "cannot create $work"
		echo "unpacking in $work, $mode mode (about ${need}K)"
	fi

	tmp="$work/.clashwrt-core.$$"
	rm -rf "$tmp"; mkdir -p "$tmp" || die "cannot create $tmp"

	echo "mihomo ${ver} for ${arch}"
	if ! ( fetch_core "$url" "$tmp" "$want_sha" "$keep" ); then
		rm -rf "$tmp"; [ -n "$keep" ] && rm -f "$keep"
		exit 1
	fi

	# Only decide about restarting once the replacement is known good.
	running=0
	pidof mihomo >/dev/null 2>&1 && running=1

	if [ "$mode" = flash ]; then
		# The estimate got the download this far; the real size decides how it
		# goes into /usr/bin. A core unpacked on the overlay already holds its
		# room and is only renamed, so there is nothing more to find.
		if [ "$(mount_of "$tmp")" = "$(mount_of "$BIN_DIR")" ]; then
			plan=move
		else
			plan="$(ensure_install_room "$(size_kb "$tmp/mihomo")")" || { rm -rf "$tmp"; exit 1; }
		fi
		if ! install_core_binary "$tmp/mihomo" "$plan"; then
			rm -rf "$tmp"
			# a core stopped to make room comes back, still the old one
			[ "$plan" = stop ] && [ "$running" = 1 ] && "$CORE_INIT" start >/dev/null 2>&1
			exit 1
		fi
		# a running core in RAM keeps its pages until the restart below
		rm -f "$RAM_CORE" "$STORE_GZ" "$STORE_NOTE"
	else
		mv -f "$tmp/mihomo" "$RAM_CORE" || { rm -rf "$tmp"; [ -n "$keep" ] && rm -f "$keep"; die "could not move the core into $RAM_DIR"; }
		if [ "$mode" = gz ]; then
			mv -f "$keep" "$STORE_GZ"
		else
			rm -f "$STORE_GZ"
		fi
		mkdir -p "$STORE_DIR"
		echo "$ver $asset ${want_sha:--} $( [ "$mode" = gz ] && cat "$tmp/gz.sha" || echo -)" > "$STORE_NOTE"
		# a core on flash before keeps its blocks until mihomo restarts
		link_core
	fi
	rm -rf "$tmp"

	echo "installed $("$CORE_BIN" -v 2>&1 | head -n1)"

	# Only once the new core is in place and known good. A download that
	# failed must never have cost anyone the binaries they were keeping.
	prune_old_cores
	# mihomo replaced meow-openwrt: its package goes too
	if meow_pkgs_present; then
		echo "removing meow-openwrt, which mihomo replaced"
		meow_remove_pkgs || echo "WARNING: could not remove the meow-openwrt package; remove it by hand" >&2
	fi
	rm -f "$MEOW_NOTE"
	set_core_type mihomo

	# The old binary keeps serving until the daemon is restarted, so leaving
	# it running would report a version nothing is actually using. A core
	# that was not running is left alone: this is an update, not a start.
	restart_if_running "$running"
}

# Puts the core into RAM for gz and ram, before mihomo starts: from the .gz on
# flash, or downloaded. Does nothing when the core is already there. In ram
# mode a download that fails is retried in the background until it works, and
# mihomo is started then (with no VPN yet, the watchdog's "when the VPN
# fails" choice is what LAN traffic gets meanwhile).
do_core_prepare() {
	local mode retry="$1" ver asset sha gzsha tmp
	mode="$(core_store)"
	[ "$mode" = flash ] && return 0
	if core_ready; then link_core; return 0; fi

	[ -f "$STORE_NOTE" ] || die "core_store is '$mode' but $STORE_NOTE is missing; install the core again"
	read -r ver asset sha gzsha < "$STORE_NOTE"
	valid_tag "$ver" || die "bad version in $STORE_NOTE"
	case "$asset" in mihomo-linux-*-"$ver".gz) ;; *) die "bad file name in $STORE_NOTE" ;; esac

	mkdir -p "$RAM_DIR" || die "cannot create $RAM_DIR"
	tmp="$RAM_DIR/.clashwrt-core.$$"
	rm -rf "$tmp"; mkdir -p "$tmp" || die "cannot create $tmp"

	if [ "$mode" = gz ]; then
		[ -f "$STORE_GZ" ] || { rm -rf "$tmp"; die "core_store is 'gz' but $STORE_GZ is missing; install the core again"; }
		if [ "$gzsha" != - ] && [ "$(sha256_of "$STORE_GZ")" != "$gzsha" ]; then
			rm -rf "$tmp"
			die "$STORE_GZ does not match its recorded SHA-256 (damaged flash?); install the core again"
		fi
		if ! { gzip -dc "$STORE_GZ" > "$tmp/mihomo" 2>/dev/null && chmod 0755 "$tmp/mihomo" &&
			"$tmp/mihomo" -v >/dev/null 2>&1; }; then
			rm -rf "$tmp"; die "could not unpack $STORE_GZ into $RAM_DIR"
		fi
	else
		[ "$sha" != - ] || sha="$(asset_digest MetaCubeX/mihomo "$ver" "$asset")"
		if [ -z "$sha" ] && [ "$(uci -q get clashwrt.config.core_verify)" != 0 ]; then
			echo "no SHA-256 to check the core against yet"
			rm -rf "$tmp"
			[ -n "$retry" ] || schedule_retry
			return 1
		fi
		if ! ( fetch_core "$(core_url "$ver" "$asset")" "$tmp" "$sha" "" ); then
			rm -rf "$tmp"
			[ -n "$retry" ] || schedule_retry
			return 1
		fi
	fi

	mv -f "$tmp/mihomo" "$RAM_CORE" || { rm -rf "$tmp"; die "could not move the core into $RAM_DIR"; }
	rm -rf "$tmp"
	link_core
	echo "core $ver ready in RAM"
	logger -t clashwrt "core $ver ready in RAM ($mode)" 2>/dev/null
	return 0
}

# At boot, before mihomo starts: a packed core is unpacked on the spot; one
# kept only in RAM is downloaded in the background, since the WAN may not be up
# yet, and mihomo is started once it is there.
do_core_boot() {
	case "$(core_store)" in
		gz)  do_core_prepare ;;
		ram) if core_ready; then link_core; else schedule_retry; fi ;;
	esac
}

# The Go runtime's memory settings for mihomo, as KEY=VALUE words for procd.
# GOMEMLIMIT is a soft ceiling: the collector works harder near it rather
# than letting the heap grow, which is what a small router needs; past it
# nothing is killed. core_mem_limit: 'auto' (by the router's RAM), 'off', or
# a number of MiB.
do_core_env() {
	local v total
	# meow is not a Go program and sizes itself by the router's RAM
	meow_live && return 0
	v="$(uci -q get clashwrt.config.core_mem_limit)"
	case "$v" in
		off) return 0 ;;
		''|auto)
			total="$(meminfo_kb MemTotal)"
			if [ "$total" -lt "$MIN_RAM_KB" ]; then echo "GOMEMLIMIT=48MiB GOGC=50"
			elif [ "$total" -lt 524288 ]; then echo "GOMEMLIMIT=96MiB GOGC=75"
			fi
			;;
		*[!0-9]*) return 0 ;;
		*) echo "GOMEMLIMIT=${v}MiB GOGC=50" ;;
	esac
}

# One background retry loop at a time: once a minute for a day.
schedule_retry() {
	local p
	p="$(cat "$RETRY_PID" 2>/dev/null)"
	[ -n "$p" ] && kill -0 "$p" 2>/dev/null && return 0
	echo "will keep trying in the background"
	logger -t clashwrt "core download failed; retrying every minute" 2>/dev/null
	if command -v setsid >/dev/null 2>&1; then
		setsid sh "$0" core-retry >/dev/null 2>&1 </dev/null &
	else
		sh "$0" core-retry >/dev/null 2>&1 </dev/null &
	fi
}

do_core_retry() {
	local i=0
	echo $$ > "$RETRY_PID"
	while [ "$i" -lt "${CORE_RETRIES:-1440}" ]; do
		i=$((i + 1))
		if ( do_core_prepare retry ) >/dev/null 2>&1; then
			rm -f "$RETRY_PID"
			"$CORE_INIT" enabled >/dev/null 2>&1 && ! pidof mihomo >/dev/null 2>&1 &&
				"$CORE_INIT" start >/dev/null 2>&1
			return 0
		fi
		sleep "${CORE_RETRY_DELAY:-60}"
	done
	rm -f "$RETRY_PID"
	logger -t clashwrt "core download still failing after $i tries; giving up until the next boot" 2>/dev/null
	return 1
}

# Moves the core already installed between flash, gz and ram, without
# downloading it again where that can be helped. New first, old last: at no
# point is there no core to start.
do_core_store() {
	local new="$1" old running src ver arch asset sha="-" gzsha="-" kb est tmp plan why _v="" _a _g=""
	case "$new" in flash|gz|ram) ;; *) die "usage: core-store flash|gz|ram" ;; esac
	# a package's files are where the package manager put them
	if meow_live; then
		[ "$new" = flash ] && { echo "the core is already on flash"; return 0; }
		die "meow-openwrt is installed as a package and stays on flash (it takes about $(size_kb "$MEOW_BIN")K there)"
	fi
	old="$(core_store)"
	running=0
	pidof mihomo >/dev/null 2>&1 && running=1

	if core_ready; then src="$RAM_CORE"
	elif [ -f "$CORE_BIN" ] && [ ! -L "$CORE_BIN" ] && "$CORE_BIN" -v 2>&1 | head -n1 | grep -qi mihomo; then src="$CORE_BIN"
	else
		uci set "clashwrt.config.core_store=$new"; uci commit clashwrt
		echo "no core installed yet; it will be kept as '$new' when it is installed"
		return 0
	fi
	ver="$(version_of "$src")"
	valid_tag "$ver" || die "cannot tell the version of $src"

	if [ "$new" = flash ]; then
		[ "$src" = "$CORE_BIN" ] && [ "$old" = flash ] && { echo "the core is already on flash"; return 0; }
		plan="$(ensure_install_room "$(size_kb "$src")")" || exit 1
		install_core_binary "$src" "$plan" || exit 1
		uci set clashwrt.config.core_store=flash; uci commit clashwrt
		rm -f "$RAM_CORE" "$STORE_GZ" "$STORE_NOTE"
		echo "the core is on flash now"
		restart_if_running "$running"
		return 0
	fi

	if [ "$src" != "$RAM_CORE" ]; then
		kb="$(size_kb "$src")"
		why="$(ram_no_room "$kb")" && die "no room in RAM for the core: $why"
	fi
	arch="$(map_arch)" || die "unsupported CPU architecture"
	asset="mihomo-linux-${arch}-${ver}.gz"
	[ -f "$STORE_NOTE" ] && read -r _v _a sha _g < "$STORE_NOTE" && [ "$_v" = "$ver" ] || sha="-"
	[ "$sha" != - ] || sha="$(asset_digest MetaCubeX/mihomo "$ver" "$asset")"
	[ -n "$sha" ] || sha="-"
	mkdir -p "$STORE_DIR" "$RAM_DIR" || die "cannot create $STORE_DIR"

	if [ "$new" = gz ]; then
		if [ -f "$STORE_GZ" ] && [ -f "$STORE_NOTE" ] && [ "$_v" = "$ver" ] && [ "$_g" != - ] &&
			[ "$(sha256_of "$STORE_GZ")" = "$_g" ]; then
			gzsha="$_g"
		else
			# a Go binary packs to about two fifths
			est=$(( $(size_kb "$src") * 2 / 5 ))
			[ $(( $(avail_kb "$STORE_DIR") + $(size_kb "$STORE_GZ") )) -ge $(( est + 1024 )) ] ||
				die "not enough room on flash for the packed core: it needs about $((est + 1024))K, $(avail_kb "$STORE_DIR")K is free"
			echo "packing the core (this takes a while)"
			if ! { gzip -c "$src" > "$STORE_GZ.new" && mv -f "$STORE_GZ.new" "$STORE_GZ"; }; then
				rm -f "$STORE_GZ.new"; die "could not write $STORE_GZ"
			fi
			gzsha="$(sha256_of "$STORE_GZ")"
		fi
	fi

	if [ "$src" != "$RAM_CORE" ]; then
		tmp="$RAM_DIR/.mihomo.new.$$"
		if ! { cp -f "$src" "$tmp" && chmod 0755 "$tmp" && mv -f "$tmp" "$RAM_CORE"; }; then
			rm -f "$tmp"; die "could not copy the core into $RAM_DIR"
		fi
	fi
	echo "$ver $asset $sha $gzsha" > "$STORE_NOTE"
	[ "$new" = ram ] && rm -f "$STORE_GZ"
	uci set "clashwrt.config.core_store=$new"; uci commit clashwrt
	# replaces a core on flash, whose blocks come back when mihomo restarts
	link_core
	[ "$new" = ram ] && [ "$sha" = - ] &&
		echo "WARNING: GitHub gave no SHA-256 for $asset; the download at boot needs one unless core_verify is '0'" >&2
	echo "the core is kept as '$new' now"
	restart_if_running "$running"
}

# --------------------------------------------------------------------------
# meow-openwrt
# --------------------------------------------------------------------------
#
# meow-openwrt (github.com/mrFrok/meow-openwrt) reads the same config.yaml and
# answers the same REST API as mihomo, in 9-14 MB instead of 55. Its releases
# carry OpenWrt packages, one per profile -- meow-tiny, meow, meow-full, which
# conflict with each other -- and a package is what is installed, so opkg or
# apk knows the file and can take it away again. The package puts the binary
# at /usr/bin/meow and /usr/bin/mihomo becomes a link to it; started by that
# name, the process is "mihomo" to pidof as well. A package's file stays on
# flash: core_store does not apply.
#
# core_type in /etc/config/clashwrt says which core is installed, and
# core_profile which meow; both are written once an install has succeeded.

# "<tag> <package>" of the meow installed here
MEOW_NOTE="$STORE_DIR/meow.note"

core_type() {
	case "${CORE_TYPE:-$(uci -q get clashwrt.config.core_type)}" in
		meow) echo meow ;; *) echo mihomo ;;
	esac
}

set_core_type() {
	uci -q set "clashwrt.config.core_type=$1"
	[ -n "${2:-}" ] && uci -q set "clashwrt.config.core_profile=$2"
	uci -q commit clashwrt
}

meow_profile() {
	case "${MEOW_PROFILE:-$(uci -q get clashwrt.config.core_profile)}" in
		tiny) echo tiny ;; full) echo full ;; *) echo lightweight ;;
	esac
}

meow_pkg() {
	case "$1" in tiny) echo meow-tiny ;; full) echo meow-full ;; *) echo meow ;; esac
}

# /usr/bin/mihomo is the link to meow's binary
meow_live() { [ -L "$CORE_BIN" ] && [ "$(readlink "$CORE_BIN")" = "$MEOW_BIN" ]; }

core_live_type() { if meow_live; then echo meow; else echo mihomo; fi; }

# opkg keeps a .control per installed package, apk on OpenWrt a .list
meow_pkg_present() {
	[ -f "$PKG_ROOT/usr/lib/opkg/info/$1.control" ] || [ -f "$PKG_ROOT/lib/apk/packages/$1.list" ]
}

meow_pkgs_present() {
	local p
	for p in meow-tiny meow meow-full; do meow_pkg_present "$p" && return 0; done
	return 1
}

meow_live_profile() {
	local p
	for p in tiny lightweight full; do
		meow_pkg_present "$(meow_pkg "$p")" && { echo "$p"; return 0; }
	done
	echo unknown
}

# apk on OpenWrt 25 and later, opkg before
pkg_kind() {
	case "${CLASHWRT_PKG:-}" in apk|ipk) echo "$CLASHWRT_PKG"; return 0 ;; esac
	if command -v apk >/dev/null 2>&1; then echo apk
	elif command -v opkg >/dev/null 2>&1; then echo ipk
	else return 1
	fi
}

pkg_add() {
	# unsigned: the SHA-256 GitHub keeps for the file is what was checked
	if [ "$(pkg_kind)" = apk ]; then apk add --allow-untrusted "$1"
	else opkg install --force-reinstall "$1"
	fi
}

meow_remove_pkgs() {
	local p rc=0
	for p in meow-tiny meow meow-full; do
		meow_pkg_present "$p" || continue
		if [ "$(pkg_kind)" = apk ]; then apk del "$p" >/dev/null 2>&1 || rc=1
		else opkg remove "$p" >/dev/null 2>&1 || rc=1
		fi
	done
	return "$rc"
}

# The OpenWrt arch meow has a package for: the packages are named by it, so
# DISTRIB_ARCH is the whole answer. MEOW_ARCH overrides it.
meow_arch() {
	local a="${MEOW_ARCH:-}"
	if [ -z "$a" ] && [ -f /etc/openwrt_release ]; then
		a="$(sed -n "s/^DISTRIB_ARCH='\\(.*\\)'\$/\\1/p" /etc/openwrt_release | head -n1)"
	fi
	if [ -n "${MEOW_ARCH:-}" ]; then valid_tag "$a" && echo "$a"; return; fi
	case "$a" in
		aarch64_generic|aarch64_cortex-a53|aarch64_cortex-a72|aarch64_cortex-a76|\
		arm_cortex-a7_neon-vfpv4|mipsel_24kc|mips_24kc) echo "$a" ;;
		*) return 1 ;;
	esac
}

# owrt-v<version>-<release>, as meow-openwrt tags its releases
meow_tag() {
	valid_tag "$1" || return 1
	case "$1" in owrt-v[0-9]*-[0-9]*) return 0 ;; esac
	return 1
}

meow_latest() {
	local t
	t="$(cw_curl -sSL -m 30 "https://api.github.com/repos/$MEOW_SLUG/releases/latest" 2>/dev/null \
		| sed -n 's/.*"tag_name"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' | head -n1)"
	meow_tag "$t" && echo "$t"
}

# The release's file for tag $1, profile $2, OpenWrt arch $3, package kind $4:
# meow_0.29.0-1_mipsel_24kc.ipk, or meow-0.29.0-r1_mipsel_24kc.apk.
meow_asset() {
	local v="${1#owrt-v}" name
	name="$(meow_pkg "$2")"
	if [ "$4" = apk ]; then echo "${name}-${v%-*}-r${v##*-}_$3.apk"
	else echo "${name}_${v}_$3.ipk"
	fi
}

# The release installed, as its tag; one installed by hand, by the version
# the binary reports.
meow_installed() {
	local t p
	[ -x "$MEOW_BIN" ] || return 1
	if [ -f "$MEOW_NOTE" ] && read -r t p < "$MEOW_NOTE" && meow_tag "$t"; then
		echo "$t"
		return 0
	fi
	"$MEOW_BIN" -v 2>&1 | head -n1 | sed -n 's/^Meow Meta \([0-9][^[:space:]]*\).*/v\1/p'
}

# What $1 kB of meow takes on a compressing flash. A Rust binary packs worse
# than Go's: JFFS2 keeps meow-tiny in about half of itself, UBIFS in two
# thirds, so three quarters.
meow_disk_kb() {
	if flash_compresses; then echo $(( $1 * 3 / 4 )); else echo "$1"; fi
}

# Downloads $1 to $2, through the proxy first and directly second, and checks
# it against SHA-256 $3 (unless empty). Dies on failure.
fetch_file() {
	local url="$1" out="$2" want="$3" route proxy ok=0 got why
	for route in proxy direct; do
		proxy=""
		if [ "$route" = proxy ]; then
			proxy="$(cw_proxy_url)" || continue
			echo "downloading ${url##*/} through the proxy"
		else
			echo "downloading ${url##*/}"
		fi
		rm -f "$out"
		if curl ${proxy:+--proxy "$proxy"} -sSL --fail --proto '=https' -m 300 -o "$out" "$url" 2>"$out.err"; then
			ok=1; break
		fi
		[ "$route" = proxy ] && echo "that failed; trying directly"
	done
	if [ "$ok" != 1 ]; then
		why="$(awk 'NF { print; exit }' "$out.err" 2>/dev/null)"
		rm -f "$out" "$out.err"
		die "download failed: $url${why:+ ($why)}"
	fi
	rm -f "$out.err"
	got="$(sha256_of "$out")"
	if [ -n "$want" ] && [ "$got" != "$want" ]; then
		rm -f "$out"
		die "SHA-256 mismatch for ${url##*/}: GitHub says $want, the download is ${got:-unreadable}; nothing was installed"
	fi
	[ -n "$want" ] && echo "SHA-256 checked: $got"
	return 0
}

# Kilobytes the package unpacks to: an .ipk says so in its control file; for
# an .apk, three times the download is the ceiling.
pkg_unpacked_kb() {
	local n
	case "$1" in *.ipk)
		n="$(tar -xzOf "$1" ./control.tar.gz 2>/dev/null | tar -xzOf - ./control 2>/dev/null |
			sed -n 's/^Installed-Size:[[:space:]]*\([0-9][0-9]*\).*/\1/p')"
		[ -n "$n" ] && [ "$n" -gt 0 ] && { echo $(( (n + 1023) / 1024 )); return 0; }
		;;
	esac
	echo $(( $(size_kb "$1") * 3 ))
}

stop_core() {
	local i=0
	"$CORE_INIT" stop >/dev/null 2>&1
	while pidof mihomo >/dev/null 2>&1 && [ "$i" -lt 10 ]; do
		sleep 1
		i=$((i + 1))
	done
	! pidof mihomo >/dev/null 2>&1
}

do_meow_install() {
	local want="$1"
	local arch kind profile pkg tag asset url sha work tmp f kb need have spare running=0 stopped=0 p

	arch="$(meow_arch)" || die "meow-openwrt has no build for this router ($(sed -n "s/^DISTRIB_ARCH='\\(.*\\)'\$/\\1/p" /etc/openwrt_release 2>/dev/null | head -n1)); it is built for aarch64, arm_cortex-a7_neon-vfpv4, mipsel_24kc and mips_24kc. Keep mihomo: $0 core-use mihomo"
	kind="$(pkg_kind)" || die "neither apk nor opkg found"
	profile="$(meow_profile)"
	pkg="$(meow_pkg "$profile")"

	tag="${want:-${MEOW_VERSION:-}}"
	case "$tag" in ""|owrt-*) ;; *) tag="owrt-v${tag#v}" ;; esac
	if [ -z "$tag" ]; then
		echo "looking up the latest meow-openwrt release"
		tag="$(meow_latest)"
	fi
	[ -n "$tag" ] || die "could not determine the meow-openwrt version (pass it as an argument, e.g. owrt-v0.29.0-1)"
	meow_tag "$tag" || die "not a meow-openwrt release tag: $tag"

	asset="$(meow_asset "$tag" "$profile" "$arch" "$kind")"
	url="https://github.com/$MEOW_SLUG/releases/download/$tag/$asset"
	sha="$(asset_digest "$MEOW_SLUG" "$tag" "$asset")"
	if [ -z "$sha" ]; then
		[ "$(uci -q get clashwrt.config.core_verify)" = 0 ] ||
			die "GitHub did not give the SHA-256 of $asset (no such file in $tag, or GitHub is out of reach), so the download cannot be checked (set core_verify to '0' in /etc/config/clashwrt to install it unchecked)"
		echo "WARNING: installing $asset without a SHA-256 check (core_verify is '0')" >&2
	fi

	# the package is a few MB and waits in RAM, or wherever there is room
	work="$(pick_workdir 8192)" || exit 1
	tmp="$work/.clashwrt-meow.$$"
	rm -rf "$tmp"; mkdir -p "$tmp" || die "cannot create $tmp"
	f="$tmp/$asset"
	echo "meow-openwrt $tag ($pkg) for $arch"
	( fetch_file "$url" "$f" "$sha" ) || { rm -rf "$tmp"; exit 1; }

	# Room on flash, with what the switch frees counted: the meow it
	# replaces, a mihomo on flash, its packed copy and spare cores. Nothing
	# is touched when even that is not enough.
	kb="$(pkg_unpacked_kb "$f")"
	need=$(( $(meow_disk_kb "$kb") + 1024 ))
	have="$(usable_kb "$BIN_DIR")"
	spare=0
	meow_pkgs_present && spare=$(( spare + $(meow_disk_kb "$(size_kb "$MEOW_BIN")") ))
	[ -f "$CORE_BIN" ] && [ ! -L "$CORE_BIN" ] && spare=$(( spare + $(disk_kb "$(size_kb "$CORE_BIN")") ))
	spare=$(( spare + $(size_kb "$STORE_GZ") + $(disk_kb "$(spare_cores_kb)") ))
	if [ $(( have + spare )) -lt "$need" ]; then
		rm -rf "$tmp"
		die "not enough room on flash for meow-openwrt: it needs about ${need}K, there is ${have}K free and the switch frees ${spare}K. Try the tiny profile, or free some space on the overlay"
	fi

	pidof mihomo >/dev/null 2>&1 && running=1
	# a running meow is not replaced under itself; nor is anything, when its
	# room has to be had back first
	if [ "$running" = 1 ] && { meow_live || [ "$have" -lt "$need" ]; }; then
		echo "stopping the core while it is replaced"
		stop_core || { rm -rf "$tmp"; die "the core did not stop; nothing was changed"; }
		stopped=1
	fi
	if [ "$have" -lt "$need" ]; then
		echo "the overlay is short of room; removing the old core first"
		prune_old_cores
		rm -f "$STORE_GZ"
		[ -f "$CORE_BIN" ] && [ ! -L "$CORE_BIN" ] && rm -f "$CORE_BIN"
	fi

	# the profiles conflict: another one goes first
	for p in meow-tiny meow meow-full; do
		[ "$p" = "$pkg" ] && continue
		meow_pkg_present "$p" || continue
		echo "removing $p"
		if [ "$kind" = apk ]; then apk del "$p" >/dev/null 2>&1; else opkg remove "$p" >/dev/null 2>&1; fi ||
			echo "WARNING: could not remove $p" >&2
	done

	echo "installing $asset"
	if ! pkg_add "$f" || ! "$MEOW_BIN" -v 2>&1 | head -n1 | grep -q '^Meow'; then
		rm -rf "$tmp"
		if [ -x "$CORE_BIN" ]; then
			[ "$stopped" = 1 ] && "$CORE_INIT" start >/dev/null 2>&1
			die "could not install $asset; the old core is still in place"
		fi
		die "could not install $asset, and the old core is gone; install one again: $0 core-use mihomo"
	fi
	rm -rf "$tmp"

	# /usr/bin/mihomo becomes the link; a core in RAM goes with it
	if ! meow_live; then
		rm -f "$CORE_BIN"
		ln -s "$MEOW_BIN" "$CORE_BIN" || die "could not link $CORE_BIN to $MEOW_BIN"
	fi
	rm -f "$RAM_CORE" "$STORE_GZ" "$STORE_NOTE"
	mkdir -p "$STORE_DIR"
	echo "$tag $pkg" > "$MEOW_NOTE"
	uci -q set clashwrt.config.core_store=flash
	set_core_type meow "$profile"

	echo "installed $("$MEOW_BIN" -v 2>&1 | head -n1) ($pkg $tag)"
	prune_old_cores

	if [ "$stopped" = 1 ]; then
		echo "starting the core"
		"$CORE_INIT" start >/dev/null 2>&1 || echo "WARNING: the core did not come back up -- check the logs" >&2
	else
		restart_if_running "$running"
	fi
}

# Switches the core: mihomo, or meow-openwrt in one of its profiles.
do_core_use() {
	case "$1" in
		mihomo)
			[ -z "${2:-}" ] || die "mihomo has no profiles"
			CORE_TYPE=mihomo
			;;
		meow)
			case "${2:-}" in ""|tiny|lightweight|full) ;; *) die "a meow-openwrt profile is tiny, lightweight or full" ;; esac
			CORE_TYPE=meow
			[ -n "${2:-}" ] && MEOW_PROFILE="$2"
			;;
		*) die "usage: $0 core-use mihomo|meow [tiny|lightweight|full]" ;;
	esac
	do_core_install ""
}

# --------------------------------------------------------------------------
# clashwrt itself
# --------------------------------------------------------------------------

do_self_status() {
	load_info

	if ! parse_repo; then
		echo "repo:      ${REPO:-unknown}"
		echo "installed: ${INST_VERSION:-${INST_COMMIT:-unknown}}"
		echo "date:      ${INST_DATE:-unknown}"
		echo "channel:   unknown"
		echo "latest:    unknown"
		echo "update:    unknown"
		return 0
	fi

	local installed latest
	if [ "$KIND" = "tags" ]; then
		echo "channel:   release"
		installed="${INST_VERSION:-$REF}"
		latest="$(remote_tag)" || latest=""
	else
		echo "channel:   $REF"
		installed="$INST_COMMIT"
		latest="$(remote_commit)" || latest=""
	fi

	echo "repo:      https://github.com/$SLUG"
	echo "installed: ${installed:-unknown}"
	echo "date:      ${INST_DATE:-unknown}"
	echo "latest:    ${latest:-unknown}"

	if [ -z "$latest" ] || [ -z "$installed" ] || [ "$installed" = "unknown" ]; then
		echo "update:    unknown"
	elif [ "$latest" = "$installed" ]; then
		echo "update:    current"
	else
		echo "update:    available"
	fi
}

do_self_update() {
	load_info
	parse_repo || die "cannot update automatically from $REPO -- re-run install.sh by hand"

	# On the release channel the point to install is the newest tag, not the
	# one already on disk -- otherwise "update" would reinstall what is there.
	local want="$REF" src="$REPO"
	if [ "$KIND" = "tags" ]; then
		want="$(remote_tag)" || die "could not find the latest release"
		src="https://github.com/$SLUG/archive/refs/tags/$want.tar.gz"
	fi

	# A release carries install.sh as an attached file with a SHA-256 GitHub
	# keeps for it, and the installer checks the tarball the same way. The
	# main branch has nothing to check against.
	local url="https://raw.githubusercontent.com/$SLUG/$want/install.sh" sha=""
	if [ "$KIND" = "tags" ]; then
		url="https://github.com/$SLUG/releases/download/$want/install.sh"
		sha="$(asset_digest "$SLUG" "$want" install.sh)"
		[ -n "$sha" ] || die "release $want lists no SHA-256 for install.sh, so the update cannot be checked"
	fi
	# The installer is run as root, so it is fetched into a directory only
	# this process created: nothing can be planted there or swapped in
	# between the check below and the run.
	local dir script runner
	dir="$(mktemp -d /tmp/clashwrt-selfupdate.XXXXXX)" || die "cannot create a temporary directory"
	script="$dir/install.sh"
	runner="$dir/run.sh"

	cw_curl -sSL --fail --proto '=https' -m 120 -o "$script" "$url" || die "could not download $url"
	[ -s "$script" ] || die "the downloaded installer is empty"

	# A truncated or redirected download would otherwise be executed as far
	# as it goes, part-way through replacing the installation.
	head -n 20 "$script" | grep -q 'One-shot installer for clashwrt' \
		|| die "what came back from $url is not the clashwrt installer"
	if [ -n "$sha" ]; then
		[ "$(sha256_of "$script")" = "$sha" ] ||
			{ rm -rf "$dir"; die "SHA-256 mismatch for $url; nothing was run"; }
		echo "installer SHA-256 checked"
	else
		echo "WARNING: the main branch has no SHA-256 to check the installer against" >&2
	fi

	# The core is updated by its own button. Bundling it here would make one
	# button do two unrelated things, and hide a failed core download behind
	# a successful reinstall.
	cat > "$runner" <<RUNNER
#!/bin/sh
echo "=== clashwrt update started \$(date -u '+%Y-%m-%d %H:%M:%SZ') ==="
SKIP_CORE=1 REPO_URL='$src' sh '$script'
_rc=\$?
echo
echo "=== clashwrt update finished, rc=\$_rc ==="
rm -rf '$dir'
RUNNER
	chmod +x "$runner"

	rm -f "$LOG"

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
	core-prepare) do_core_prepare ;;
	core-boot)    do_core_boot ;;
	core-env)     do_core_env ;;
	core-where)   do_core_where ;;
	arch)         map_arch ;;
	core-retry)   do_core_retry ;;
	core-store)   do_core_store "${2:-}" ;;
	core-use)     do_core_use "${2:-}" "${3:-}" ;;
	cores)        list_cores ;;
	prune-cores)  prune_old_cores ;;
	self-status)  do_self_status ;;
	self-update)  do_self_update ;;
	log)          do_log ;;
	*)
		echo "usage: $0 core-status|core-install [version]|core-use mihomo|meow [profile]|core-store flash|gz|ram|core-prepare|cores|prune-cores|self-status|self-update|log" >&2
		exit 1
		;;
esac
