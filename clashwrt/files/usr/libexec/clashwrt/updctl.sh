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
# Usage: updctl.sh core-status|core-install [version]|cores|prune-cores
#        updctl.sh self-status|self-update|log
#
# CLASHWRT_TMPDIR names a directory to unpack the core in ahead of /tmp.

SLUG_DEFAULT="mrFrok/clashwrt"
# Releases are the default channel: a router should not pick up whatever landed
# on the branch an hour ago. An install that came from a branch keeps tracking
# that branch, because switching channels under someone is not an update.
REPO_DEFAULT=""
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
	t="$(curl -sSL -m 25 "https://api.github.com/repos/$SLUG/releases/latest" 2>/dev/null \
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
	local t
	t="$(curl -sSL -m 30 https://api.github.com/repos/MetaCubeX/mihomo/releases/latest 2>/dev/null \
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
	usr_mp="$(mount_of /usr/bin)"
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
	echo /usr/bin
}

# Kilobytes of spare cores prune_old_cores would remove, i.e. room that can
# be had back on the overlay without touching anything in use.
spare_cores_kb() {
	local f t=0
	[ "${KEEP_OLD_CORES:-0}" = "1" ] && { echo 0; return; }
	for f in /usr/bin/mihomo?*; do
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
remote_kb() {
	local n
	n="$(curl -sSIL -m 30 "$1" 2>/dev/null | tr -d '\r' |
		sed -n 's/^[Cc]ontent-[Ll]ength:[[:space:]]*\([0-9][0-9]*\)$/\1/p' | tail -n1)"
	[ -n "$n" ] && [ "$n" -gt 0 ] && echo $(( n / 1024 ))
}

# Kilobytes the unpacked core will need, before it is downloaded. This only
# decides whether a download is worth starting -- the real size is checked
# again once the core is unpacked -- so it must not refuse a router that has
# the room. The core already installed is the same program and the best
# guide: a release grows it by a few percent, not by an eighth. Without one,
# a Go binary compresses to roughly a third, so three times the .gz is a
# ceiling; with neither, 64 MB covers every build mihomo publishes today.
estimate_core_kb() {
	local gz="$1" cur
	cur="$(size_kb /usr/bin/mihomo)"
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
	local need=$(( $1 + 1024 )) avail old=0
	avail="$(usable_kb /usr/bin)"
	[ -f /usr/bin/mihomo ] && old="$(size_kb /usr/bin/mihomo)"

	if [ "$avail" -ge "$need" ]; then
		echo stage
	elif [ $(( avail + old )) -ge "$need" ]; then
		if core_in_use /usr/bin/mihomo; then echo stop; else echo inplace; fi
	else
		return 1
	fi
}

install_room_error() {
	echo "ERROR: not enough room in /usr/bin for the new core: it needs about ${1}K," \
		"there is $(usable_kb /usr/bin)K free and the current core frees $(size_kb /usr/bin/mihomo)K." \
		"Free some space on the overlay (opkg remove, or delete files you added) and try again." >&2
}

# Before the download: could the overlay take a core of $1 kB at all, counting
# the old core and any spare ones as room? Nothing is removed here -- a
# download that then fails must not have cost anyone the cores they kept.
install_possible() {
	local need=$(( $1 + 1024 )) have
	have=$(( $(usable_kb /usr/bin) + $(size_kb /usr/bin/mihomo) + $(spare_cores_kb) ))
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
	local src="$1" plan="$2"
	local staged="/usr/bin/.mihomo.clashwrt-new" i=0

	rm -f "$staged"

	case "$plan" in
	move)
		mv -f "$src" /usr/bin/mihomo && return 0
		echo "ERROR: could not move the new core into /usr/bin; the old core is untouched" >&2
		return 1
		;;
	stage)
		if cp -f "$src" "$staged" && chmod 0755 "$staged" && mv -f "$staged" /usr/bin/mihomo; then
			return 0
		fi
		rm -f "$staged"
		echo "ERROR: could not stage a copy in /usr/bin; the old core is untouched" >&2
		return 1
		;;
	stop)
		echo "the overlay has room for one core only; stopping mihomo while it is replaced"
		/etc/init.d/mihomo stop >/dev/null 2>&1
		while core_in_use /usr/bin/mihomo && [ "$i" -lt 10 ]; do
			sleep 1
			i=$((i + 1))
		done
		core_in_use /usr/bin/mihomo && {
			echo "ERROR: mihomo did not stop, so its blocks cannot be reused; the old core is untouched" >&2
			return 1
		}
		;;
	inplace)
		echo "not enough room in /usr/bin for a second copy; replacing in place"
		;;
	esac

	cp -f "$src" /usr/bin/mihomo || { echo "ERROR: could not install /usr/bin/mihomo" >&2; return 1; }
	chmod 0755 /usr/bin/mihomo
}

# Is this exact file the binary behind a process that is running right now?
# Unlinking one out from under a running process is survivable on Linux, but
# it makes `restart` reach for a file that is no longer there, so it is not
# something to do casually.
core_in_use() {
	local target="$1" p
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
	local f sz ver what
	for f in /usr/bin/mihomo*; do
		[ -f "$f" ] || continue
		case "$f" in /usr/bin/.*) continue ;; esac

		sz=$(( $(wc -c < "$f") / 1024 ))
		ver=""
		is_elf "$f" && ver="$("$f" -v 2>&1 | head -n1 | grep -o 'v[0-9][^[:space:]]*' | head -n1)"

		if is_elf "$f" && "$f" -v 2>&1 | head -n1 | grep -qi mihomo; then
			if [ "$f" = "/usr/bin/mihomo" ]; then
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

		printf '%-34s %8sK  %-12s %s\n' "$f" "$sz" "${ver:-?}" "$what"
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

	for f in /usr/bin/mihomo*; do
		[ -f "$f" ] || continue
		[ "$f" = "/usr/bin/mihomo" ] && continue
		case "$f" in /usr/bin/.*) continue ;; esac

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

do_core_install() {
	local want="$1"
	local arch ver url tmp running need work gz_rc plan

	arch="$(map_arch)" || die "unsupported CPU architecture: $(uname -m) -- set MIHOMO_ARCH to name a build"

	ver="${want:-${MIHOMO_VERSION:-}}"
	if [ -z "$ver" ]; then
		echo "looking up the latest mihomo release"
		ver="$(core_latest)"
	fi
	[ -n "$ver" ] || die "could not determine the mihomo version (pass it as an argument, or set MIHOMO_VERSION)"
	valid_tag "$ver" || die "not a release tag: $ver"

	url="https://github.com/MetaCubeX/mihomo/releases/download/${ver}/mihomo-linux-${arch}-${ver}.gz"

	# Everything about room is settled before the download, so a router that
	# cannot take the core finds out in a second, not after a minute of
	# downloading -- and nothing has been touched when it does.
	need="$(estimate_core_kb "$(remote_kb "$url")")"
	install_possible "$need" || exit 1
	work="$(pick_workdir "$need")" || exit 1
	echo "unpacking in $work (about ${need}K needed, $(usable_kb "$work")K usable)"

	tmp="$work/.clashwrt-core.$$"
	rm -rf "$tmp"; mkdir -p "$tmp" || die "cannot create $tmp"

	# Downloaded and unpacked in one stream, so the .gz never needs room of
	# its own. gzip checks the CRC at the end of the stream, so a cut-off
	# download fails here instead of leaving a truncated core.
	echo "downloading mihomo ${ver} for ${arch}"
	{ curl -sSL --fail --proto '=https' -m 300 "$url" 2>"$tmp/curl.err" || : > "$tmp/curl.failed"; } |
		gzip -dc > "$tmp/mihomo" 2>"$tmp/gzip.err"
	gz_rc=$?
	if [ -e "$tmp/curl.failed" ]; then
		local why
		why="$(awk 'NF { print; exit }' "$tmp/curl.err" 2>/dev/null)"
		rm -rf "$tmp"
		die "download failed: $url${why:+ ($why)}"
	fi

	# Report what gzip actually said rather than guessing at a cause. It
	# opens with a blank line, so take the first line that has something on
	# it rather than the first line. A full disk shows up here too.
	if [ "$gz_rc" != 0 ]; then
		local why
		why="$(awk 'NF { print; exit }' "$tmp/gzip.err" 2>/dev/null)"
		rm -rf "$tmp"
		die "could not decompress the core${why:+: $why}"
	fi
	chmod 0755 "$tmp/mihomo"

	# A core that cannot run is worse than none, and this is the one check
	# that catches a wrongly guessed architecture before it takes the proxy
	# down rather than after.
	"$tmp/mihomo" -v >/dev/null 2>&1 || {
		rm -rf "$tmp"
		die "the downloaded core does not run on this system (wrong architecture? set MIHOMO_ARCH)"
	}

	# Only decide about restarting once the replacement is known good.
	running=0
	pidof mihomo >/dev/null 2>&1 && running=1

	# The estimate got the download this far; the real size decides how it
	# goes into /usr/bin. A core unpacked on the overlay already holds its
	# room and is only renamed, so there is nothing more to find.
	if [ "$(mount_of "$tmp")" = "$(mount_of /usr/bin)" ]; then
		plan=move
	else
		plan="$(ensure_install_room "$(size_kb "$tmp/mihomo")")" || { rm -rf "$tmp"; exit 1; }
	fi

	if ! install_core_binary "$tmp/mihomo" "$plan"; then
		rm -rf "$tmp"
		# a core stopped to make room comes back, still the old one
		[ "$plan" = stop ] && [ "$running" = 1 ] && /etc/init.d/mihomo start >/dev/null 2>&1
		exit 1
	fi
	rm -rf "$tmp"

	echo "installed $(/usr/bin/mihomo -v 2>&1 | head -n1)"

	# Only once the new core is in place and known good. A download that
	# failed must never have cost anyone the binaries they were keeping.
	prune_old_cores

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

	local url="https://raw.githubusercontent.com/$SLUG/$want/install.sh"
	# The installer is run as root, so it is fetched into a directory only
	# this process created: nothing can be planted there or swapped in
	# between the check below and the run.
	local dir script runner
	dir="$(mktemp -d /tmp/clashwrt-selfupdate.XXXXXX)" || die "cannot create a temporary directory"
	script="$dir/install.sh"
	runner="$dir/run.sh"

	curl -sSL --fail --proto '=https' -m 120 -o "$script" "$url" || die "could not download $url"
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
	cores)        list_cores ;;
	prune-cores)  prune_old_cores ;;
	self-status)  do_self_status ;;
	self-update)  do_self_update ;;
	log)          do_log ;;
	*)
		echo "usage: $0 core-status|core-install [version]|cores|prune-cores|self-status|self-update|log" >&2
		exit 1
		;;
esac
