#!/bin/sh
# SPDX-License-Identifier: GPL-3.0-or-later
#
# Maintains the nftables set that decides, before any marking happens, which
# destinations skip the proxy entirely.
#
# mihomo can do this itself with route-exclude-address-set, but only when it
# owns the firewall: that option requires auto-route and auto-redirect and is
# incompatible with routing-mark, which is exactly the arrangement ClashWrt
# does not use -- the four interception modes exist because mihomo's own
# routing cannot be relied on. So the same idea is implemented here instead,
# where it costs nothing architecturally.
#
# Why it matters: a DIRECT rule inside mihomo is not a fast path. The
# connection still terminates on the router and is relayed through userspace,
# which costs throughput and also collapses every device behind one address,
# so a shaper like cake can no longer tell hosts apart. Traffic excluded here
# never reaches mihomo at all.
#
# Two modes, mirroring mihomo's own pair:
#
#   exclude  listed destinations bypass the proxy, everything else is
#            intercepted. Pair with "everything through the proxy except
#            Russia": the list is Russian networks.
#
#   include  only listed destinations are intercepted, everything else
#            bypasses. Pair with "everything direct except the lists": the
#            list is what actually needs a proxy.
#
# ...and "auto", which works the pairing out instead of asking for it. The
# direction is not a preference: the set holds the exceptions to whatever
# mihomo does by default, so the default decides which way round it goes.
# mihomo states that default in one line -- its terminal MATCH rule -- and
# reading it is exact where guessing from the addresses would not be.
#
# A downloaded list is not the only thing that says which traffic needs the
# proxy: config.yaml says so too, rule by rule. With 'include', a destination
# that a config rule sends to the proxy but no list happens to contain never
# reached mihomo at all, so the rule could not fire. bypass_set_from_config
# adds what the config's own rules name (see the "from config.yaml" section).
#
# Usage: setctl.sh update [force] | load | status | clear | sources
#        setctl.sh direction | detect | from-config | install-dnsmasq-full
#        setctl.sh doh-update | doh-load

# The CLASHWRT_* overrides exist so tests/ can run this file off the router.
# shellcheck source=/dev/null
. "${CLASHWRT_FUNCTIONS:-/lib/functions.sh}"
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

NAME="clashwrt"
TABLE="inet clashwrt"
SET4="bypass4"
SET4_DNS="bypass4_dns"
STATE_DIR="${CLASHWRT_STATE_DIR:-/etc/clashwrt}"
LIST="$STATE_DIR/bypass4.list"
STAMP="$STATE_DIR/bypass4.stamp"
CONF_LIST="$STATE_DIR/config4.list"
CONF_DOMAINS="$STATE_DIR/config-domains.list"
CONF_NOTES="$STATE_DIR/config.notes"
DOH_LIST="$STATE_DIR/doh4.list"
DOH_STAMP="$STATE_DIR/doh4.stamp"
DOH_URL="https://raw.githubusercontent.com/dibdot/DoH-IP-blocklists/master/doh-ipv4.txt"

# The largest of the preset lists is a few hundred KB and well under 100000
# networks; ten times that is a list from somewhere that should not be
# trusted with a router's memory.
MAX_LIST_BYTES=16777216
MAX_LIST_ENTRIES=500000

log() { logger -t "$NAME" "$@"; [ -t 1 ] && echo "$NAME: $*" >&2; return 0; }
die() { logger -t "$NAME" "ERROR: $*"; echo "$NAME: ERROR: $*" >&2; exit 1; }

load_cfg() {
	config_load "$NAME"
	config_get set_mode     config bypass_set_mode     off
	config_get set_source   config bypass_set_source   ru
	config_get set_url      config bypass_set_url      ""
	config_get set_interval config bypass_set_interval 86400
	config_get from_config  config bypass_set_from_config 1
	config_get max_domains_cfg config bypass_set_max_domains ""
	config_get dns_hijack   config dns_hijack          0
	config_get mihomo_dir   config mihomo_dir          /etc/mihomo

	# 'config' is a source with nothing to download: the set is only what
	# config.yaml names, so taking from the config is not optional there.
	[ "$set_source" = "config" ] && from_config=1

	MIHOMO_CONF="$mihomo_dir/config.yaml"

	# Kept apart from set_mode so status can show both what was configured
	# and what it came out as.
	set_mode_raw="$set_mode"
	set_mode_why=""

	# Resolved softly: 'status' and 'detect' exist to explain a failure here,
	# so load_cfg must not be what stops them from running. An unresolved
	# 'auto' leaves set_mode empty, and require_direction() is what refuses.
	if [ "$set_mode" = "auto" ]; then
		if detect_direction; then
			set_mode="$DETECT_DIR"
			set_mode_why="$DETECT_WHY"
		else
			set_mode=""
			set_mode_why=""
		fi
	fi
}

# Anything about to build a rule or fetch a list needs a real direction.
require_direction() {
	[ -n "$set_mode" ] && return 0
	die "$(detect_failure_message)"
}

# Which way round the set goes, worked out rather than asked for.
#
# The set holds the exceptions to mihomo's default, so the default is what
# decides the direction. If everything is proxied unless a rule says otherwise,
# the list is what comes out of the proxy -- exclude. If everything is direct
# unless a rule says otherwise, the list is what goes into it -- include.
#
# mihomo states that default in exactly one place: the terminal MATCH rule at
# the end of its rules. Reading it is exact, and it is the only source that is
# also right for a config somebody wrote by hand. The wizard's stored answer
# says the same thing, but only if the wizard is what wrote the config, so it
# is the fallback and not the first choice.
#
# Answers through DETECT_DIR and DETECT_WHY rather than through stdout: every
# caller wants the evidence as well as the verdict, and $(...) would run this
# in a subshell where a second variable could not come back. DETECT_WHY exists
# at all because an automatic decision nobody can see the reasoning for is
# worse than a question.
DETECT_DIR=""
DETECT_WHY=""

detect_direction() {
	DETECT_DIR=""
	DETECT_WHY=""

	local last=""
	if [ -f "$MIHOMO_CONF" ]; then
		# Only list entries of the top-level rules: a commented-out
		# "# - MATCH,DIRECT" must not count, nor one inside sub-rules.
		last="$(awk '/^[A-Za-z0-9_-]+:/ { r = ($0 ~ /^rules:/) } r' "$MIHOMO_CONF" 2>/dev/null |
			sed -n 's/^[[:space:]]*-[[:space:]]*MATCH,[[:space:]]*\([^ ,#]*\).*/\1/p' | tail -n1)"
	fi

	case "$last" in
		DIRECT)
			DETECT_WHY="MATCH,DIRECT in $MIHOMO_CONF"
			DETECT_DIR=include; return 0 ;;
		# REJECT means the default is to drop, which is neither direction.
		REJECT|"")
			;;
		*)
			DETECT_WHY="MATCH,$last in $MIHOMO_CONF"
			DETECT_DIR=exclude; return 0 ;;
	esac

	case "$(uci -q get "$NAME".wizard.routing)" in
		direct_except_list)
			DETECT_WHY="the wizard's routing strategy (direct except the lists)"
			DETECT_DIR=include; return 0 ;;
		proxy_except_ru)
			DETECT_WHY="the wizard's routing strategy (proxy except Russia)"
			DETECT_DIR=exclude; return 0 ;;
	esac

	return 1
}

# Say which two things failed to answer and what to do about it, in the shape
# fw.sh uses for the config disagreements it refuses to guess through.
detect_failure_message() {
	if [ ! -f "$MIHOMO_CONF" ]; then
		echo "bypass_set_mode is 'auto', but $MIHOMO_CONF does not exist yet, so there is no default routing to read the direction from. Run the setup wizard, or set bypass_set_mode to 'exclude' (the listed addresses go direct) or 'include' (only the listed addresses are intercepted)."
		return 0
	fi
	echo "bypass_set_mode is 'auto', but $MIHOMO_CONF has no terminal 'MATCH' rule to read the default routing from, and no wizard answer is stored either. Add a MATCH rule to the end of your rules (MATCH,DIRECT or MATCH,<your proxy group>), or set bypass_set_mode to 'exclude' or 'include' explicitly."
}

# Presets are plain-CIDR-per-line or a YAML payload list; both parse the same
# way, so a custom URL in either shape works too.
source_url() {
	case "$1" in
		ru)        echo "https://www.ipdeny.com/ipblocks/data/countries/ru.zone" ;;
		ru-geoip)  echo "https://raw.githubusercontent.com/MetaCubeX/meta-rules-dat/refs/heads/meta/geo/geoip/ru.yaml" ;;
		refilter)  echo "https://github.com/1andrevich/Re-filter-lists/releases/latest/download/ipsum.lst" ;;
		custom)    echo "$set_url" ;;
		config)    echo "" ;;
		*)         return 1 ;;
	esac
}

do_sources() {
	echo "ru	exclude	Russian networks (ipdeny)"
	echo "ru-geoip	exclude	Russian networks (meta-rules-dat geoip)"
	echo "refilter	include	Re-filter blocked IP ranges"
	echo "custom	any	A URL of your own"
	echo "config	any	Only what the rules in config.yaml name"
}

# Which direction a list is meant for. Getting this backwards is not a subtle
# misconfiguration: re-filter is a list of addresses that are *blocked* in
# Russia, so putting it behind "exclude" would send exactly the traffic that
# needs the proxy straight out the WAN instead. The reverse is just as wrong --
# "include" on a list of Russian networks would proxy the one thing that has no
# reason to be proxied and send everything else direct.
intended_mode() {
	case "$1" in
		ru|ru-geoip) echo "exclude" ;;
		refilter)    echo "include" ;;
		*)           echo "any" ;;
	esac
}

check_pairing() {
	local want
	want="$(intended_mode "$set_source")"
	[ "$want" = "any" ] && return 0

	# Nothing to disagree with: 'auto' derived the direction from the routing
	# rather than being told it.
	[ "$set_mode_raw" = "auto" ] || {
		[ "$want" = "$set_mode" ] && return 0

		if [ "$set_source" = "refilter" ]; then
			die "'refilter' lists addresses that are blocked in Russia, so they are what needs the proxy. Use it with mode 'include' (intercept only these), not '$set_mode'."
		fi
		die "'$set_source' lists Russian networks, which is what should skip the proxy. Use it with mode 'exclude' (these bypass), not '$set_mode'."
	}
	return 0
}

# A preset and a direction can agree with each other and still both be wrong
# for the routing actually configured -- 'refilter' with mode 'include' is a
# valid pair, and useless against a config that proxies everything by default,
# because then the set turns off the proxy for all the traffic not on the list.
# The old check could not see that; it only compared the list against the mode.
#
# This one warns rather than refusing. The detected routing is evidence, not
# authority: a config the parser read wrongly, or a deliberate arrangement,
# should not be able to stop a list from refreshing.
check_against_routing() {
	local want detected
	want="$(intended_mode "$set_source")"
	[ "$want" = "any" ] && return 0
	[ "$set_mode_raw" = "auto" ] && return 0

	detect_direction || return 0
	detected="$DETECT_DIR"
	[ "$detected" = "$set_mode" ] && return 0

	log "WARNING: '$set_source' is set to '$set_mode', but $DETECT_WHY says the direction should be '$detected'. As configured, the proxy is skipped for the traffic that needs it."
	return 0
}

# Accepts both a bare CIDR list and a YAML "payload:" list, keeps only well
# formed IPv4 networks, and drops anything else rather than feeding nft a line
# it will refuse -- one bad entry would otherwise abort the whole load.
parse_list() {
	sed -e 's/#.*//' -e 's/^[[:space:]]*-[[:space:]]*//' -e 's/[[:space:]]//g' \
		-e "s/['\"]//g" \
	| grep -E '^([0-9]{1,3}\.){3}[0-9]{1,3}(/[0-9]{1,2})?$' \
	| awk -F '[./]' '
		# the shape alone lets 999.1.1.1 or /99 through, and nft refuses the
		# whole load for one such line; /0 would swallow every address
		{ for (i = 1; i <= 4; i++) if ($i > 255) next }
		NF == 5 && ($5 > 32 || $5 == 0) { next }
		# 010.0.0.1 is the same address to nft only once written as 10.0.0.1
		{ a = ($1 + 0) "." ($2 + 0) "." ($3 + 0) "." ($4 + 0); if (NF == 5) a = a "/" ($5 + 0) }
		!seen[a]++ { print a }
	'
}

# ---------------------------------------------------------------------------
# from config.yaml
# ---------------------------------------------------------------------------
#
# Which of the config's rules can go into the set depends on the direction,
# and on which mistake is affordable:
#
#   include  the set is what reaches mihomo. Every rule that sends something
#            anywhere but DIRECT is taken, addresses and domains alike. Too
#            much in the set only means mihomo sees a connection it then
#            sends direct itself -- slower, never wrong.
#
#   exclude  the set is what skips mihomo. Only address rules to DIRECT are
#            taken, and only those before the first rule that sends anything
#            elsewhere: mihomo matches top down, so an earlier rule could have
#            proxied that address, and skipping mihomo for it would leak it.
#            Domains are never taken here -- a DIRECT site on a shared CDN
#            would take every other site on that CDN out of the proxy.
#
# Addresses go into the set directly. Domains have no address until somebody
# looks them up, so dnsmasq adds what it resolves for them to a second set
# (nftset=, which needs dnsmasq-full). Rule providers are read from the files
# mihomo has already downloaded; the binary .mrs format is turned back into
# text by mihomo itself (convert-ruleset), since nothing else here can read it.

# config.yaml as tab-separated records:
#   P <name> <behavior> <path> <format>    one per rule provider
#   R <type> <value> <target>              one per plain rule, in order
#   F <range>                              the fake-ip range, when fake-ip is on
config_records() {
	awk '
	function unq(s) {
		sub(/^[ \t]+/, "", s); sub(/[ \t]+$/, "", s)
		if (s ~ /^".*"$/ || s ~ /^\047.*\047$/) s = substr(s, 2, length(s) - 2)
		return s
	}
	function flush_p() {
		if (pname != "") print "P\t" pname "\t" pbeh "\t" ppath "\t" pfmt
		pname = ""; pbeh = ""; ppath = ""; pfmt = ""
	}
	function prop(k, v) {
		if (k == "behavior") pbeh = v
		else if (k == "path") ppath = v
		else if (k == "format") pfmt = v
	}
	# a provider written as { type: http, behavior: domain, ... } on one line
	function inline(s,   n, i, parts, c) {
		gsub(/^[ \t]*\{|\}[ \t]*$/, "", s)
		n = split(s, parts, ",")
		for (i = 1; i <= n; i++) {
			c = index(parts[i], ":")
			if (c) prop(unq(substr(parts[i], 1, c - 1)), unq(substr(parts[i], c + 1)))
		}
	}
	{ sub(/\r$/, "") }
	/^[A-Za-z0-9_-]+:/ {
		if (sec == "rule-providers") flush_p()
		sec = $0; sub(/:.*/, "", sec)
		next
	}
	/^[ \t]*(#|$)/ { next }
	sec == "rule-providers" {
		match($0, /^[ \t]*/); ind = RLENGTH
		line = $0; sub(/^[ \t]+/, "", line); sub(/[ \t]+#.*/, "", line)
		c = index(line, ":")
		if (pind == 0 || ind <= pind) {
			flush_p(); pind = ind
			pname = unq(substr(line, 1, c - 1))
			if (substr(line, c + 1) ~ /\{/) inline(substr(line, c + 1))
			next
		}
		prop(unq(substr(line, 1, c - 1)), unq(substr(line, c + 1)))
		next
	}
	sec == "dns" && /^[ \t]+(enhanced-mode|fake-ip-range):/ {
		line = $0; sub(/^[ \t]+/, "", line); sub(/[ \t]+#.*/, "", line)
		c = index(line, ":")
		if (substr(line, 1, c - 1) == "enhanced-mode") emode = unq(substr(line, c + 1))
		else frange = unq(substr(line, c + 1))
		next
	}
	sec == "rules" && /^[ \t]*-/ {
		line = $0; sub(/^[ \t]*-[ \t]*/, "", line); sub(/[ \t]+#.*/, "", line)
		line = unq(line)
		# a compound rule cannot go in the set, but where it sends traffic
		# still matters to which later rules may (see pick_rules)
		if (line ~ /^(AND|OR|NOT|SUB-RULE),/) {
			t = line; sub(/.*,/, "", t)
			print "R\tCOMPOUND\t\t" unq(t)
			next
		}
		n = split(line, f, ",")
		if (unq(f[1]) == "MATCH" && n >= 2) { print "R\tMATCH\t\t" unq(f[2]); next }
		if (n >= 3) print "R\t" unq(f[1]) "\t" unq(f[2]) "\t" unq(f[3])
	}
	END {
		if (sec == "rule-providers") flush_p()
		if (emode == "fake-ip") print "F\t" (frange == "" ? "198.18.0.1/16" : frange)
	}
	' "$MIHOMO_CONF"
}

# Domains, one per line, as dnsmasq wants them: "+.x", ".x" and "*.x" all
# become "x", which dnsmasq matches together with every subdomain. Anything
# with a wildcard elsewhere, or that is not a host name, is dropped.
parse_domains() {
	sed -e 's/#.*//' -e 's/^[[:space:]]*-[[:space:]]*//' -e 's/[[:space:]]//g' \
		-e "s/['\"]//g" -e 's/^+\.//' -e 's/^\*\.//' -e 's/^\.//' \
	| tr 'A-Z' 'a-z' \
	| grep -E '^[a-z0-9]([a-z0-9-]*[a-z0-9])?(\.[a-z0-9]([a-z0-9-]*[a-z0-9])?)+$'
}

# Duplicates and every name whose parent is also listed go: dnsmasq matches
# a domain with all its subdomains, so each would only cost it memory (about
# 7 % of Re-filter's list). Order is kept, as max_domains keeps the first.
drop_covered() {
	awk '
		{ d[NR] = $0; have[$0] = 1 }
		END {
			for (i = 1; i <= NR; i++) {
				x = d[i]
				if (seen[x]++) continue
				p = x; up = 0
				while ((j = index(p, ".")) > 0) {
					p = substr(p, j + 1)
					if (p in have) { up = 1; break }
				}
				if (!up) print x
			}
		}'
}

# An .mrs provider as text, through mihomo's own converter, into $3. mrs
# holds only domain and ipcidr sets, so classical is not asked for.
mrs_to_text() {
	local beh="$1" file="$2" out="$3"
	case "$beh" in domain|ipcidr) ;; *) return 1 ;; esac
	command -v mihomo >/dev/null 2>&1 || return 1
	rm -f "$out"
	mihomo convert-ruleset "$beh" mrs "$file" "$out" >/dev/null 2>&1
	[ -s "$out" ]
}

# One provider file by its behavior: addresses appended to $3, domains to $4.
read_provider() {
	local beh="$1" file="$2" ips="$3" doms="$4"
	case "$beh" in
		ipcidr) parse_list < "$file" >> "$ips" ;;
		domain) parse_domains < "$file" >> "$doms" ;;
		classical)
			sed -e 's/#.*//' -e 's/^[[:space:]]*-[[:space:]]*//' -e "s/['\"]//g" -e 's/[[:space:]]//g' "$file" |
				awk -F, -v ips="$ips" -v doms="$doms" '
					$1 == "IP-CIDR" { print $2 >> ips }
					$1 == "DOMAIN" || $1 == "DOMAIN-SUFFIX" { print $2 >> doms }
				'
			;;
	esac
}

# The rules the direction allows (see above), as "IP <cidr>", "DOMAIN <name>",
# "SET <provider> [ip-only]" or "SKIP <type>" for rule types that name traffic
# but cannot become addresses.
pick_rules() {
	awk -F '\t' -v dir="$set_mode" '
		$1 != "R" || $2 == "MATCH" { next }
		$2 == "COMPOUND" { if ($4 != "DIRECT") closed = 1; next }
		dir == "exclude" {
			if ($4 != "DIRECT") { closed = 1; next }
			if (closed) next
			if ($2 == "IP-CIDR") print "IP\t" $3
			else if ($2 == "RULE-SET") print "SET\t" $3 "\tip-only"
			next
		}
		$4 == "DIRECT" { next }
		$2 == "IP-CIDR" { print "IP\t" $3; next }
		$2 == "DOMAIN" || $2 == "DOMAIN-SUFFIX" { print "DOMAIN\t" $3; next }
		$2 == "RULE-SET" { print "SET\t" $3; next }
		$2 ~ /^(DOMAIN-KEYWORD|DOMAIN-REGEX|DOMAIN-WILDCARD|GEOSITE|GEOIP|IP-ASN)$/ { print "SKIP\t" $2 }
	' "$1"
}

# Fills CONF_LIST, CONF_DOMAINS and CONF_NOTES from config.yaml for the
# current direction. The notes say what could not be used and why.
# What do_from_config's result depends on, as one line: the direction, the
# config itself, and the size and age of every provider file it names. The
# provider files are the slow part to read (tens of thousands of lines each),
# and they change only when mihomo refreshes them, so a matching signature
# means the last result still holds. Cheap: config.yaml is read once and the
# providers are only stat'ed.
config_sig() {
	{
		echo "$set_mode $mihomo_dir $(command -v mihomo)"
		[ -f "$MIHOMO_CONF" ] || { echo none; return; }
		cat "$MIHOMO_CONF"
		config_records | awk -F '\t' '$1 == "P" { print $4 }' | while read -r path; do
			case "$path" in /*) ;; *) path="$mihomo_dir/${path#./}" ;; esac
			ls -ln --full-time "$path" 2>/dev/null || ls -ln "$path" 2>/dev/null || echo "missing $path"
		done
	} | md5sum | cut -d' ' -f1
}

do_from_config() {
	local recs="$STATE_DIR/.recs.$$" ips="$STATE_DIR/.ips.$$" doms="$STATE_DIR/.doms.$$" notes="$STATE_DIR/.notes.$$"
	local kind val extra line beh path fmt file tab sig
	tab="$(printf '\t')"
	mkdir -p "$STATE_DIR"

	sig="$(config_sig)"
	if [ "${CLASHWRT_NO_CACHE:-}" != 1 ] && [ -f "$CONF_LIST" ] && [ -f "$CONF_DOMAINS" ] && [ -f "$CONF_NOTES" ] &&
		[ "$(cat "$STATE_DIR/config.sig" 2>/dev/null)" = "$sig" ]; then
		return 0
	fi

	: > "$ips"; : > "$doms"; : > "$notes"

	if [ -f "$MIHOMO_CONF" ]; then
		config_records > "$recs"
	else
		echo "no $MIHOMO_CONF yet" >> "$notes"
		: > "$recs"
	fi

	pick_rules "$recs" > "$recs.pick"
	while IFS="$tab" read -r kind val extra; do
		case "$kind" in
		IP)     echo "$val" | parse_list >> "$ips" ;;
		DOMAIN) echo "$val" | parse_domains >> "$doms" ;;
		SKIP)   echo "skipped: $val rules have no fixed addresses or domains" >> "$notes" ;;
		SET)
			line="$(awk -F '\t' -v n="$val" '$1 == "P" && $2 == n' "$recs" | head -n1)"
			[ -n "$line" ] || { echo "skipped: rule-set $val has no rule-providers entry" >> "$notes"; continue; }
			beh="$(echo "$line" | cut -f3)"
			path="$(echo "$line" | cut -f4)"
			fmt="$(echo "$line" | cut -f5)"
			[ "$extra" = "ip-only" ] && [ "$beh" != "ipcidr" ] && continue
			# mihomo keeps providers under its own directory; so does this
			case "$path" in
				""|*..*) echo "skipped: rule-set $val has no usable path" >> "$notes"; continue ;;
				"$mihomo_dir"/*) file="$path" ;;
				/*) echo "skipped: rule-set $val is outside $mihomo_dir" >> "$notes"; continue ;;
				*)  file="$mihomo_dir/${path#./}" ;;
			esac
			[ -f "$file" ] && [ ! -L "$file" ] && [ -s "$file" ] || { echo "skipped: rule-set $val is not downloaded yet ($file)" >> "$notes"; continue; }
			if [ "$fmt" = "mrs" ]; then
				mrs_to_text "$beh" "$file" "$recs.mrs" ||
					{ echo "skipped: rule-set $val is in the binary mrs format and mihomo could not convert it" >> "$notes"; continue; }
				file="$recs.mrs"
			fi
			read_provider "$beh" "$file" "$ips" "$doms"
			;;
		esac
	done < "$recs.pick"

	# with fake-ip, every name mihomo answers for resolves into this range,
	# so with 'include' it must reach mihomo whatever else the set holds
	[ "$set_mode" = "include" ] && awk -F '\t' '$1 == "F" { print $2 }' "$recs" | parse_list >> "$ips"

	# written aside and renamed: status runs this too, and a load reading
	# the files at the same moment must see a whole list, old or new
	parse_list < "$ips" > "$CONF_LIST.$$"
	if [ "$set_mode" = "include" ]; then
		parse_domains < "$doms" | drop_covered > "$CONF_DOMAINS.$$"
	else
		: > "$CONF_DOMAINS.$$"
	fi
	sort -u "$notes" > "$CONF_NOTES.$$"
	mv -f "$CONF_LIST.$$" "$CONF_LIST"
	mv -f "$CONF_DOMAINS.$$" "$CONF_DOMAINS"
	mv -f "$CONF_NOTES.$$" "$CONF_NOTES"
	echo "$sig" > "$STATE_DIR/config.sig.$$" && mv -f "$STATE_DIR/config.sig.$$" "$STATE_DIR/config.sig"
	rm -f "$recs" "$recs.pick" "$recs.mrs" "$ips" "$doms" "$notes"
}

# ---------------------------------------------------------------------------
# domains through dnsmasq
# ---------------------------------------------------------------------------

# Each domain costs dnsmasq some memory for as long as it runs. Lists like
# Re-filter's run past 80000 names, which a router with a few GB takes in its
# stride and one with 128 MB does not, so the default follows the RAM: about
# one domain per 4 KB, between 20000 and 300000. bypass_set_max_domains
# overrides it. Past the limit the first ones are kept and status says so.
max_domains() {
	local m
	m="$(num_or "$max_domains_cfg" "")"
	if [ -z "$m" ]; then
		m="$(awk '/^MemTotal:/ { print int($2 / 4) }' /proc/meminfo 2>/dev/null)"
		m="$(num_or "$m" 20000)"
		[ "$m" -ge 20000 ] || m=20000
		[ "$m" -le 300000 ] || m=300000
	fi
	echo "$m"
}

num_or() {
	case "$1" in ''|*[!0-9]*) echo "$2" ;; *) echo "$1" ;; esac
}
DNSMASQ_FILE="clashwrt-nftset.conf"

dnsmasq_has_nftset() {
	dnsmasq --version 2>/dev/null | grep -qw 'nftset' &&
		! dnsmasq --version 2>/dev/null | grep -qw 'no-nftset'
}

# Where the running dnsmasq reads extra files from: the conf-dir in the config
# procd generated for it, else the UCI confdir, else OpenWrt's default.
dnsmasq_confdir() {
	local d
	d="$(sed -n 's/^conf-dir=\([^,]*\).*/\1/p' /var/etc/dnsmasq.conf.* 2>/dev/null | head -n1)"
	[ -n "$d" ] || d="$(uci -q get 'dhcp.@dnsmasq[0].confdir')"
	echo "${d:-/tmp/dnsmasq.d}"
}

# Whether LAN clients are actually answered by this router's dnsmasq for the
# domains to be seen. With dns_hijack, port 53 goes to mihomo instead.
domains_usable() {
	[ "$set_mode" = "include" ] && [ "$from_config" = 1 ] &&
		[ "$dns_hijack" != 1 ] && dnsmasq_has_nftset
}

# Writes nftset= lines for CONF_DOMAINS into dnsmasq's conf dir, or removes
# them when there is nothing to write. dnsmasq reads them only on start, so
# it is restarted, and only when the file actually changed.
dns_sync_domains() {
	local dir file tmp
	dir="$(dnsmasq_confdir)"
	file="$dir/$DNSMASQ_FILE"

	if ! domains_usable || [ ! -s "$CONF_DOMAINS" ]; then
		[ -e "$file" ] || return 0
		rm -f "$file"
		/etc/init.d/dnsmasq restart >/dev/null 2>&1
		log "removed the dnsmasq domain rules"
		return 0
	fi

	mkdir -p "$dir"
	tmp="$file.$$"
	head -n "$(max_domains)" "$CONF_DOMAINS" |
		awk -v set="4#inet#clashwrt#$SET4_DNS" '{ print "nftset=/" $0 "/" set }' > "$tmp"
	if cmp -s "$tmp" "$file"; then
		rm -f "$tmp"
		return 0
	fi
	mv -f "$tmp" "$file"
	/etc/init.d/dnsmasq restart >/dev/null 2>&1
	log "dnsmasq adds the addresses of $(grep -c . "$file") config domains to $SET4_DNS"
}

# ---------------------------------------------------------------------------
# DoH resolvers (block_doh)
# ---------------------------------------------------------------------------
#
# Addresses of public DoH resolvers, from dibdot's DoH-IP-blocklists (GPL-3),
# plus doh_extra from UCI, into the doh4 set that fw.sh rejects HTTPS to.
# Refreshed once a day by the same cron run as the bypass list.

do_doh_update() {
	local tmp n now
	[ "$(uci -q get clashwrt.config.block_doh)" = 1 ] || return 0
	if [ "${1:-}" != force ] && [ -s "$DOH_LIST" ] && [ -f "$DOH_STAMP" ]; then
		now="$(date +%s)"
		[ $((now - $(cat "$DOH_STAMP" 2>/dev/null || echo 0))) -lt 86400 ] && { do_doh_load; return 0; }
	fi
	mkdir -p "$STATE_DIR"
	tmp="$(mktemp /tmp/clashwrt-doh.XXXXXX)" || return 1
	if cw_curl -sSL --fail --proto '=https' -m 120 --max-filesize 4194304 -o "$tmp" "$DOH_URL"; then
		parse_list < "$tmp" > "$tmp.parsed"
		n="$(grep -c . "$tmp.parsed" 2>/dev/null || echo 0)"
		if [ "$n" -ge 10 ]; then
			mv "$tmp.parsed" "$DOH_LIST"
			date +%s > "$DOH_STAMP"
			log "stored $n DoH resolver addresses"
		else
			log "only $n DoH addresses parsed, keeping the previous list"
		fi
	else
		log "DoH list download failed, keeping the previous list"
	fi
	rm -f "$tmp" "$tmp.parsed"
	do_doh_load
}

do_doh_load() {
	local f extra
	[ "$(uci -q get clashwrt.config.block_doh)" = 1 ] || return 0
	nft list set $TABLE doh4 >/dev/null 2>&1 || return 0
	f="$(mktemp /tmp/clashwrt-doh-load.XXXXXX)" || return 1
	extra="$(uci -q get clashwrt.config.doh_extra | tr ' ' '\n' | parse_list)"
	{ cat "$DOH_LIST" 2>/dev/null; [ -n "$extra" ] && echo "$extra"; } | awk '!seen[$0]++' > "$f.all"
	{
		echo "flush set $TABLE doh4"
		if [ -s "$f.all" ]; then
			echo "add element $TABLE doh4 {"
			awk 'NR>1{printf ",\n"} {printf "  %s", $0}' "$f.all"
			echo ""
			echo "}"
		fi
	} > "$f"
	nft -f "$f" 2>/dev/null && log "loaded $(grep -c . "$f.all") DoH addresses into doh4"
	rm -f "$f" "$f.all"
	return 0
}

do_update() {
	# the daily run: providers into or out of RAM as the room now allows
	"${CLASHWRT_LIBEXEC:-/usr/libexec/clashwrt}/provctl.sh" place >/dev/null 2>&1
	# the DoH list is independent of the bypass set and refreshed regardless
	do_doh_update "${1:-}"
	load_cfg
	[ "$set_mode_raw" = "off" ] && { log "bypass set disabled"; return 0; }
	require_direction

	# nothing to download: the config is the list
	if [ "$set_source" = "config" ]; then
		do_load
		# what the set could cover may have changed with the providers
		# mihomo has downloaded since; if so, the firewall rule must follow
		local want have
		want="$(do_direction 2>/dev/null)"
		have="$(cat "${CLASHWRT_RUNDIR:-/var/run/clashwrt}/bypass.applied" 2>/dev/null)"
		[ -n "$want" ] && [ "$want" != "$have" ] && /usr/libexec/clashwrt/fw.sh apply >/dev/null 2>&1
		return 0
	fi

	check_pairing
	check_against_routing

	local url
	url="$(source_url "$set_source")" || die "unknown source '$set_source'"
	[ -n "$url" ] || die "source 'custom' selected but bypass_set_url is empty"

	if [ "${1:-}" != "force" ] && [ -f "$STAMP" ] && [ -s "$LIST" ]; then
		local age now
		now="$(date +%s)"
		age=$((now - $(cat "$STAMP" 2>/dev/null || echo 0)))
		if [ "$age" -lt "$set_interval" ]; then
			log "list is ${age}s old, below the ${set_interval}s interval; not refetching"
			return 0
		fi
	fi

	mkdir -p "$STATE_DIR"
	local tmp
	tmp="$(mktemp /tmp/clashwrt-set.XXXXXX)" || die "cannot create a temporary file"
	log "fetching $url"
	# Bounded twice over: a list host serving gigabytes would otherwise fill
	# the RAM /tmp lives in, and millions of entries would follow it into
	# flash and into the kernel set on every apply.
	# A custom list may be plain http on purpose (a box on the LAN), but a
	# redirect is only followed to https, and never to file:// or the like.
	if ! cw_curl -sSL --fail --proto '=http,https' --proto-redir '=https' -m 180 \
		--max-filesize "$MAX_LIST_BYTES" -o "$tmp" "$url"; then
		rm -f "$tmp"
		# keep whatever we had: an empty set would silently proxy everything
		[ -s "$LIST" ] && { log "download failed, keeping the previous list"; return 0; }
		die "download failed and no previous list exists"
	fi

	parse_list < "$tmp" | head -n "$((MAX_LIST_ENTRIES + 1))" > "$tmp.parsed"
	rm -f "$tmp"

	local n
	n="$(grep -c . "$tmp.parsed" 2>/dev/null || echo 0)"
	if [ "$n" -gt "$MAX_LIST_ENTRIES" ]; then
		rm -f "$tmp.parsed"
		[ -s "$LIST" ] && { log "more than $MAX_LIST_ENTRIES networks in $url, keeping the previous list"; return 0; }
		die "more than $MAX_LIST_ENTRIES networks in $url -- not a list this router should load"
	fi
	if [ "$n" -lt 10 ]; then
		rm -f "$tmp.parsed"
		[ -s "$LIST" ] && { log "only $n networks parsed, keeping the previous list"; return 0; }
		die "only $n networks parsed from $url -- wrong format?"
	fi

	mv "$tmp.parsed" "$LIST"
	date +%s > "$STAMP"
	log "stored $n networks in $LIST"
	do_load
}

# Elements are loaded from one generated script rather than a call per entry:
# these lists run to tens of thousands of networks and per-element nft calls
# take minutes.
#
# The set is the downloaded list (unless the source is 'config') plus what the
# config's own rules name, read afresh on every load so that a changed
# config.yaml is picked up by the next apply.
do_load() {
	load_cfg
	# off leaves no domain rules behind in dnsmasq (set_mode is "off" here,
	# so dns_sync_domains removes them)
	[ "$set_mode_raw" = "off" ] && { dns_sync_domains; return 0; }
	require_direction

	if [ "$from_config" = 1 ]; then
		do_from_config
	else
		: > "$CONF_LIST"; : > "$CONF_DOMAINS"; : > "$CONF_NOTES"
	fi
	dns_sync_domains

	nft list table $TABLE >/dev/null 2>&1 || { log "table not present yet; nothing to load into"; return 0; }

	local all="$STATE_DIR/.load.$$" f="$STATE_DIR/.load.$$.nft"
	{
		[ "$set_source" = "config" ] || cat "$LIST" 2>/dev/null
		cat "$CONF_LIST" 2>/dev/null
	} | awk '!seen[$0]++' > "$all"

	{
		echo "flush set $TABLE $SET4"
		if [ -s "$all" ]; then
			echo "add element $TABLE $SET4 {"
			awk 'NR>1{printf ",\n"} {printf "  %s", $0}' "$all"
			echo ""
			echo "}"
		fi
	} > "$f"

	# With 'include' an empty set sends every connection direct. A list that
	# came out empty -- a config that did not parse, a provider not yet
	# downloaded -- is a fault, not an instruction, so the old set stays.
	if [ "$set_mode" = "include" ] && [ ! -s "$all" ]; then
		rm -f "$f" "$all"
		log "WARNING: nothing to load into $SET4; keeping what it holds rather than sending all traffic direct"
		return 1
	fi

	if nft -f "$f" 2>/dev/null; then
		log "loaded $(grep -c . "$all") networks into $SET4 ($(grep -c . "$CONF_LIST") from config.yaml)"
		rm -f "$f" "$all"
		return 0
	fi
	rm -f "$f" "$all"
	log "WARNING: could not load the set"
	return 1
}

do_status() {
	load_cfg
	if [ "$set_mode_raw" != "auto" ]; then
		echo "mode:     $set_mode"
	elif [ -n "$set_mode" ]; then
		echo "mode:     auto -> $set_mode ($set_mode_why)"
	else
		echo "mode:     auto -> undecided"
		echo "WARNING:  $(detect_failure_message)"
	fi
	echo "source:   $set_source"
	if [ "$set_mode" != "off" ] && [ -n "$set_mode" ]; then
		want="$(intended_mode "$set_source")"
		if [ "$want" != "any" ] && [ "$want" != "$set_mode" ]; then
			echo "WARNING:  this list is meant for mode '$want' -- the current pairing sends the wrong traffic through the proxy"
		fi
		if detect_direction && [ "$DETECT_DIR" != "$set_mode" ]; then
			echo "WARNING:  $DETECT_WHY says the direction should be '$DETECT_DIR', not '$set_mode'"
		fi
	fi
	if [ "$set_source" != "config" ]; then
		echo "url:      $(source_url "$set_source" 2>/dev/null)"
		echo "list:     $([ -s "$LIST" ] && grep -c . "$LIST" || echo 0) networks"
		if [ -f "$STAMP" ]; then
			echo "updated:  $(( ( $(date +%s) - $(cat "$STAMP") ) / 60 )) minutes ago"
		else
			echo "updated:  never"
		fi
	fi
	if [ -n "$set_mode" ]; then
		local gap
		gap="$(hold_reason)"
		[ -n "$gap" ] && echo "HELD BACK: the set is not used, everything goes to mihomo: $gap"
	fi
	if [ "$from_config" = 1 ] && [ -n "$set_mode" ]; then
		# read afresh: the files are only as new as the last load
		echo "config:   $([ -s "$CONF_LIST" ] && grep -c . "$CONF_LIST" || echo 0) networks from config.yaml rules"
		if [ "$set_mode" = "include" ]; then
			local nd
			nd="$([ -s "$CONF_DOMAINS" ] && grep -c . "$CONF_DOMAINS" || echo 0)"
			if [ "$dns_hijack" = 1 ]; then
				echo "domains:  $nd in config.yaml, NOT used: DNS hijack sends LAN lookups to mihomo, not dnsmasq"
			elif ! dnsmasq_has_nftset; then
				echo "domains:  $nd in config.yaml, NOT used: this dnsmasq has no nftset support (install dnsmasq-full)"
			else
				echo "domains:  $nd in config.yaml, resolved addresses added by dnsmasq"
				[ "$nd" -gt "$(max_domains)" ] && echo "WARNING:  only the first $(max_domains) domains are used (bypass_set_max_domains)"
			fi
		fi
		[ -s "$CONF_NOTES" ] && sed 's/^/note:     /' "$CONF_NOTES"
	fi
	echo -n "in_kernel: "
	nft list set $TABLE $SET4 2>/dev/null | grep -c "elements" >/dev/null 2>&1 \
		&& nft list set $TABLE $SET4 2>/dev/null | tr -cd ',' | wc -c | awk '{print $1+1" entries"}' \
		|| echo "set not present"
}

# Just the answer, for fw.sh, which builds the nft rule from it and has no
# use for the reasoning.
do_direction() {
	load_cfg
	[ "$set_mode_raw" = "off" ] && { echo "off"; return 0; }
	require_direction
	if [ "$(hold_reason)" ]; then
		echo "off"
		return 0
	fi
	echo "$set_mode"
}

# Why the set must not be used right now, or nothing.
#
# With fake-ip, mihomo answers every name with an address from its own range,
# direct names included, so the kernel only ever sees that range: matching it
# against real networks would decide nothing, and the set is left out.
hold_reason() {
	if [ -f "$MIHOMO_CONF" ] && config_records | grep -q '^F'; then
		echo "config.yaml uses fake-ip DNS, so the kernel never sees the real addresses"
		return 0
	fi
	coverage_gap
}

# Why a set built from config.yaml alone cannot stand in for it, or nothing.
#
# With 'include' and source 'config', the set is the whole list of what
# reaches mihomo, so whatever a rule proxies that the set cannot hold goes
# out direct instead. Better to leave the set out (everything reaches mihomo,
# which only costs speed) than to leak: so it is held back when a proxying
# rule could not be read, or when there are domains and nothing to resolve
# them into the set. A downloaded list is a list on purpose and is not judged.
coverage_gap() {
	[ "$set_source" = "config" ] && [ "$set_mode" = "include" ] || return 0
	do_from_config
	if [ -s "$CONF_DOMAINS" ]; then
		if [ "$dns_hijack" = 1 ]; then
			echo "DNS hijack is on, so dnsmasq never sees the lookups that would fill in the config's domains"
			return 0
		elif ! dnsmasq_has_nftset; then
			echo "config.yaml proxies domains, and this dnsmasq cannot add their addresses to the set (install dnsmasq-full)"
			return 0
		fi
	fi
	grep -m1 '^skipped' "$CONF_NOTES" 2>/dev/null
}

# The answer with its evidence, for the settings page. Reports on 'auto'
# whether or not it is what is configured, so the page can show what would
# happen before anyone commits to it.
do_detect() {
	load_cfg
	if detect_direction; then
		echo "direction: $DETECT_DIR"
		echo "from:      $DETECT_WHY"
	else
		echo "direction: unknown"
		echo "from:      $(detect_failure_message)"
	fi
	echo "configured: $set_mode_raw"
}

do_clear() {
	rm -f "$LIST" "$STAMP" "$CONF_LIST" "$CONF_DOMAINS" "$CONF_NOTES" "$STATE_DIR/config.sig"
	nft flush set $TABLE $SET4 2>/dev/null
	nft flush set $TABLE $SET4_DNS 2>/dev/null
	# set_mode is unset here, so this takes the dnsmasq rules away
	dns_sync_domains
	log "cleared"
}

# What the config contributes, without loading anything: for the settings
# page, and for checking a config before switching to it.
do_show_config() {
	load_cfg
	require_direction
	do_from_config
	echo "direction: $set_mode"
	echo "networks:  $(grep -c . "$CONF_LIST")"
	[ "$set_mode" = "include" ] && echo "domains:   $(grep -c . "$CONF_DOMAINS")"
	[ -s "$CONF_NOTES" ] && sed 's/^/note:      /' "$CONF_NOTES"
	return 0
}

# Swap the stock dnsmasq for dnsmasq-full, which has the nftset support the
# config's domains need. Both packages provide the same service and config,
# so /etc/config/dhcp carries over; DNS for the LAN pauses while dnsmasq is
# replaced and restarted. The Bypass tab offers this when the set is held
# back for want of it.
do_install_dnsmasq_full() {
	if dnsmasq_has_nftset; then
		echo "dnsmasq already has nftset support"
		return 0
	fi
	# OpenWrt 25.12 and later use apk, 24.10 and older opkg. Either way the
	# package is fetched before the stock one goes, so a failed download
	# leaves DNS alone, and a failed install puts the stock one back.
	if command -v apk >/dev/null 2>&1; then
		apk update >/dev/null 2>&1 || die "apk update failed, so dnsmasq-full cannot be found"
		rm -f /tmp/dnsmasq-full-*.apk
		apk fetch -o /tmp dnsmasq-full >/dev/null 2>&1 ||
			die "could not download dnsmasq-full; dnsmasq is unchanged"
		apk del dnsmasq >/dev/null 2>&1
		apk add /tmp/dnsmasq-full-*.apk || {
			rm -f /tmp/dnsmasq-full-*.apk
			apk add dnsmasq >/dev/null 2>&1
			die "could not install dnsmasq-full; put the stock dnsmasq back"
		}
		rm -f /tmp/dnsmasq-full-*.apk
	elif command -v opkg >/dev/null 2>&1; then
		opkg update >/dev/null 2>&1 || die "opkg update failed, so dnsmasq-full cannot be found"
		# fetched before the stock one goes, so a failed download leaves DNS alone
		( cd /tmp && opkg download dnsmasq-full >/dev/null 2>&1 ) ||
			die "could not download dnsmasq-full; dnsmasq is unchanged"
		opkg remove dnsmasq >/dev/null 2>&1
		opkg install /tmp/dnsmasq-full_*.ipk || {
			rm -f /tmp/dnsmasq-full_*.ipk
			opkg install dnsmasq >/dev/null 2>&1
			die "could not install dnsmasq-full; put the stock dnsmasq back"
		}
		rm -f /tmp/dnsmasq-full_*.ipk
	else
		die "neither apk nor opkg found"
	fi
	/etc/init.d/dnsmasq restart >/dev/null 2>&1
	dnsmasq_has_nftset || die "dnsmasq-full is installed but reports no nftset support"
	echo "dnsmasq-full installed"
	# the set can stop being held back now; the firewall follows
	/usr/libexec/clashwrt/fw.sh apply >/dev/null 2>&1
	return 0
}

[ -n "${CLASHWRT_TEST:-}" ] && return 0 2>/dev/null

case "${1:-}" in
	update)  do_update "${2:-}" ;;
	load)    do_load ;;
	status)  do_status ;;
	clear)   do_clear ;;
	sources) do_sources ;;
	direction) do_direction ;;
	detect)  do_detect ;;
	from-config) do_show_config ;;
	install-dnsmasq-full) do_install_dnsmasq_full ;;
	doh-update) do_doh_update force ;;
	doh-load)   do_doh_load ;;
	*) echo "usage: $0 update [force] | load | status | clear | sources | direction | detect | from-config | install-dnsmasq-full | doh-update | doh-load" >&2; exit 1 ;;
esac
