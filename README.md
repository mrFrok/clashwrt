# ClashWrt

Transparent proxy for OpenWrt built on [mihomo](https://github.com/MetaCubeX/mihomo), with a LuCI interface, a setup wizard and **four selectable interception modes**.

An alternative to ssclash, written because transparent proxying fails in ways that are hard to see: the rules look right, the counters increment, and the traffic quietly goes nowhere. ClashWrt makes those failures visible and gives you a mode that works on every kernel.

```sh
wget -qO- https://raw.githubusercontent.com/mrFrok/clashwrt/main/install.sh | sh
```

---

**Contents** — [Features](#features) · [Requirements](#requirements) · [Install](#install) · [Four modes](#why-four-modes) · [Using it](#using-it) · [Configuration](#configuration) · [How it works](#how-it-works) · [Troubleshooting](#troubleshooting) · [Building](#building-from-source) · [Translating](#translating)

---

## Features

- **Four interception modes.** TPROXY is not usable on every kernel, so there is a working fallback for each combination of what your kernel honours.
- **A test that tells you which mode to use** instead of leaving you to guess — it runs a real transparent listener behind a real nft rule and reports whether the kernel delivers.
- **Setup wizard.** Paste a subscription URL or node links, pick DNS and a routing strategy, get a working `config.yaml` with inbounds matched to the selected mode.
- **TCP/UDP protocol split.** Send UDP through Hysteria2/TUIC and everything else through Reality/VLESS, with one button — on the wizard's config or your own hand-written one.
- **Config and rule-list editors** that validate with `mihomo -t` before installing anything, and keep backups.
- **Live logs**, streamed from mihomo's API, plus the system log around it.
- **Swappable dashboards** — metacubexd, zashboard, Yacd, or any URL.
- **WAN/LAN autodetection**, so renamed bridges, PPPoE and DSA ports work without editing anything.
- **English and Russian** interface.

ClashWrt owns the firewall and routing layer only. Your `config.yaml`, your proxies and your rules stay yours: the wizard writes one if you ask for it, the editors validate before touching it, and nothing is rewritten behind your back.

## Requirements

- **OpenWrt 22.03 or newer**, because ClashWrt needs the **fw4/nftables** firewall. Both package managers are supported: `apk` on 25.12+ and `opkg` on 23.05/24.10.
  On 21.02 and older, which use fw3/iptables, the installer refuses rather than installing rules the firewall would silently ignore.
- `nftables`, `ip-full`, `kmod-nft-nat`, `kmod-tun`, `curl` — the installer adds whatever is missing. Most stock images already have them, pulled in by `firewall4`.
- `kmod-nft-tproxy`, only for the two TPROXY modes; the other two work without it.
- `socat`, optional, only for the TPROXY selftest.
- The mihomo core, which the installer downloads for your architecture (arm64, armv5/6/7, x86_64, i386, mips/mipsel, mips64/mips64el, riscv64).

Developed and tested on OpenWrt 25.12 on a BananaPi BPI-R4 (`mediatek/filogic`). The 23.05 and 24.10 package feeds and LuCI APIs were checked for compatibility, but if you hit something on those releases, please open an issue.

## Install

```sh
wget -qO- https://raw.githubusercontent.com/mrFrok/clashwrt/main/install.sh | sh
```

This installs the mihomo core, ClashWrt, the LuCI pages and a dashboard, then stops. **Nothing is intercepted until you enable it**, so a bad install cannot take the network down. Re-running upgrades in place and keeps your configuration.

```sh
SKIP_CORE=1 sh install.sh                 # keep an existing mihomo binary
MIHOMO_VERSION=v1.19.30 sh install.sh     # pin a core version
SKIP_UI=1 sh install.sh                   # skip the dashboard
MIHOMO_ARCH=mipsle-softfloat sh install.sh  # force a core build
```

The architecture is taken from OpenWrt's own `DISTRIB_ARCH`, because `uname -m`
reports plain `mips` on both big- and little-endian MIPS and cannot tell
`mips-softfloat` from `mipsle-softfloat`. If that ever picks wrong, name the
build yourself with `MIHOMO_ARCH`.

Then open **Services → ClashWrt**, run the setup wizard, and enable the proxy on the Settings page.

### Uninstall

```sh
wget -qO- https://raw.githubusercontent.com/mrFrok/clashwrt/main/uninstall.sh | sh

KEEP_CORE=1 sh uninstall.sh        # leave mihomo installed
KEEP_CONFIG=1 sh uninstall.sh      # leave /etc/mihomo and the UCI config
ASSUME_YES=1 sh uninstall.sh       # do not ask
```

It tears the ruleset down *before* deleting the scripts that know how to tear it down, and removes the fw4 zone it created — a leftover zone points at a device that will never exist again and fw4 complains on every reload.

## Why four modes

Transparent proxying has three usable mechanisms, and none of them works everywhere:

| Mechanism | TCP | UDP | Notes |
|---|---|---|---|
| **TPROXY** | yes | yes | The correct one. Preserves the original destination for both protocols without a tun device. Broken on some kernels. |
| **NAT redirect** | yes | **no** | Always works, but there is no `SO_ORIGINAL_DST` for datagrams, so UDP cannot be recovered at all. |
| **TUN device** | yes | yes | Works everywhere, but every packet crosses userspace, which costs throughput. |

TPROXY being "broken" is not hypothetical. On MediaTek's `mtk-openwrt-feeds` kernel build the nft rule matches, the packet is marked and routed to the local table, and the counter increments — but the kernel never hands it to the `IP_TRANSPARENT` socket. Conntrack sits at `SYN_SENT [UNREPLIED]`, the listener sees nothing, the client hangs. The same config works on stock OpenWrt.

So the mode is a knob, not an assumption:

| `mode` | TCP path | UDP path | When to use |
|---|---|---|---|
| `tproxy` | TPROXY → `tproxy-port` | TPROXY → `tproxy-port` | Your kernel honours TPROXY. Fastest and most correct. |
| `tproxy_tun` | TPROXY → `tproxy-port` | fwmark → tun | TPROXY works for TCP but not UDP. |
| `tun` | fwmark → tun | fwmark → tun | Works everywhere. Simplest. Costs throughput. |
| `redirect_tun` | NAT DNAT → `redir-port` | fwmark → tun | TPROXY unusable. Keeps TCP on the fast in-kernel path and puts only UDP through the tun. |

Do not guess — press **Test TPROXY support** on the Settings page:

```
tproxy rule matched : 4 packets
socket received     : 0
client result       : rc=000

FAIL -- the rule matches but the socket never receives the connection.
This kernel cannot be used with TPROXY, no matter how it is configured.
Recommended mode: redirect_tun (or tun)
```

## Using it

Everything lives under **Services → ClashWrt**.

### Setup wizard

Builds a `config.yaml` from a subscription URL or pasted node links (`vless://`, `vmess://`, `trojan://`, `ss://`, `hysteria2://`, `tuic://`). Choose DNS, choose a routing strategy — *everything direct except the selected lists*, or *everything through the proxy except Russia* — tick the rule sets you want, and apply.

Inbounds are generated to match the interception mode selected on the Settings page, so the firewall and mihomo cannot disagree about which port to use.

Bundled lists: `ru-bundle` and `re:filter` (both from [legiz-ru](https://github.com/legiz-ru/mihomo-rule-sets)), plus per-service sets for YouTube, Telegram, Discord, X, Instagram, ChatGPT and Gemini, from [meta-rules-dat](https://github.com/MetaCubeX/meta-rules-dat).

### TCP/UDP protocol split

Hysteria2 and TUIC are QUIC-based and carry datagrams natively; Reality, VLESS and Trojan tunnel them over a TCP stream. If your subscription has both, it is worth sending UDP to the former and everything else to the latter.

One button on the Settings page turns this on and off, and it works on **whatever config is installed now** — the wizard's or your own. It edits the existing file rather than regenerating from stored answers, because plenty of configs are written by hand and have no stored answers; the transformation is line-based so comments and formatting survive, and the result is validated before it replaces anything.

```yaml
proxy-groups:
  - {name: Proxy,    type: select, use: [sub1], filter: '(?i)(reality|vless|trojan)'}
  - {name: ProxyUDP, type: select, use: [sub1], filter: '(?i)(hysteria|hy2|tuic)'}

rules:
  - AND,((NETWORK,udp),(RULE-SET,ru_bundle)),ProxyUDP
  - RULE-SET,ru_bundle,Proxy
  - MATCH,DIRECT
```

`filter:` uses Go's RE2, which has **no lookahead** — write exclusions as positive-inclusion patterns.

### Configuration and rule files

**Configuration** is a direct editor for `config.yaml`, with syntax checking, backups and one-click restore. **Rule files** manages the hand-maintained lists that file-backed rule providers point at:

```yaml
rule-providers:
  mylist: { behavior: classical, type: file, format: text, path: ./lst/mylist.txt }
```

Neither installs anything until `mihomo -t` has accepted it.

### Logs

Two views. The live one is mihomo's own log, streamed straight from its API into the browser — this is where you see which rule matched a connection and which node carried it, with a level selector, text filter, pause and copy. The system view covers everything around mihomo: the firewall engine, hotplug, and the daemon being restarted.

### Web dashboard

Installs metacubexd, zashboard or Yacd, or any `.tar.gz` containing an `index.html` (not `.zip` — OpenWrt images routinely ship without `unzip`). The page links straight to the panel and has a button to restart mihomo, which is needed when `external-ui` has just changed.

## Configuration

**Services → ClashWrt → Settings**, or `/etc/config/clashwrt`:

```
config clashwrt 'config'
	option enabled '1'
	option mode 'redirect_tun'
	option lan_device 'auto'
	option wan_device 'auto'
	option tun_device 'clash-tun'
	option mihomo_dir '/etc/mihomo'
	option self_mark '2'
	option manage_zone '1'
	option block_quic '0'
	option dns_hijack '0'
```

`auto` asks netifd which device currently backs `lan`/`wan`, so a renamed bridge, a PPPoE WAN or a DSA port all work without editing anything.

Listening ports are **read out of mihomo's `config.yaml`**, so the firewall cannot drift from the daemon. Set `tproxy_port` / `redir_port` in UCI only to override that.

Your mihomo config needs, depending on mode:

```yaml
routing-mark: 2          # every mode — see below
tproxy-port: 7894        # tproxy, tproxy_tun
redir-port: 7893         # redirect_tun
tun:                     # every mode except plain tproxy
  enable: true
  device: clash-tun
  stack: system
  auto-route: false      # ClashWrt does the routing
  auto-redirect: false
```

`routing-mark` matters more than it looks. mihomo tags its own outbound sockets with it, and the marking chain returns early on that mark. Without it, mihomo's own connection to your proxy server gets intercepted and fed back into mihomo.

`allow-lan: false` is worth knowing about too: with it set, mihomo binds `redir-port` on loopback only, which is why `redirect_tun` uses an explicit `dnat ip to 127.0.0.1:<port>` rather than a plain `redirect to :<port>` — the latter targets the inbound interface's own address, where nothing is listening.

## How it works

ClashWrt creates one nftables table, `inet clashwrt`, with a marking chain on `prerouting` and (in `redirect_tun`) a NAT chain ahead of fw4's own. It adds `ip rule`s and populates routing tables 100 (tproxy local delivery) and 151 (tun default route), creates an fw4 **zone** for the tun device, and sets `net.ipv4.conf.*.route_localnet=1`. All of it comes down again on `stop`.

### Why a zone rather than an nft rule

Forwarded traffic to and from the tun device is judged by fw4's own `forward` chain, which is `policy drop` with an explicit reject at the end. An accept in a different table does **not** save the packet: nftables evaluates every base chain registered on a hook in priority order, and one chain's accept does not stop a later chain on the same hook from rejecting the same packet.

That produces a genuinely confusing symptom — your own chain's `oifname <tun> counter` increments, so the rule is clearly matching, yet `tcpdump -i <tun>` sees nothing. The fix has to live inside fw4, and declaring a zone in UCI is the clean way: fw4 regenerates the rules itself on every reload, so nothing has to re-insert them afterwards.

### The stale-route trap

The tun policy route (`default dev clash-tun table 151`) is interface-scoped, so the kernel deletes it whenever the tun device is destroyed and recreated — which is **every mihomo restart**.

Nothing reports an error when that happens. Marked packets simply fall through to the main routing table and leave the router unproxied, which from the client side is indistinguishable from working. A hotplug hook repairs the route the moment the device reappears.

## Operating

```sh
/etc/init.d/clashwrt start|stop|reload|status
/usr/libexec/clashwrt/fw.sh status      # mode + live firewall/routing state
/usr/libexec/clashwrt/fw.sh check       # repair routing that went stale
/usr/libexec/clashwrt/fw.sh detect      # what "auto" resolved lan/wan to
/usr/libexec/clashwrt/fw.sh selftest    # does this kernel honour TPROXY?
```

## Troubleshooting

**Everything looks configured, but traffic is not proxied.** Test with a real forwarded client, not from the router's shell. The marking chain hooks `prerouting`, which only sees forwarded traffic; packets the router originates itself enter at `output` and skip the chain entirely, so a local test proves nothing:

```sh
ip netns add test
ip link add veth-c type veth peer name veth-s
ip link set veth-s master br-lan; ip link set veth-s up
ip link set veth-c netns test
ip netns exec test ip addr add 192.168.1.211/24 dev veth-c
ip netns exec test ip link set veth-c up
ip netns exec test ip link set lo up
ip netns exec test ip route add default via 192.168.1.1

ip netns exec test curl -s -o /dev/null -w '%{http_code}\n' https://1.1.1.1/
ip netns exec test traceroute -n -q2 -f5 -m6 -w2 8.8.4.4
```

Then check what mihomo actually did with it, on the Logs page or directly:

```sh
wget -q -O- 'http://127.0.0.1:9090/logs?level=info'
```

A working run logs both, naming the rule and the outbound:

```
[TCP] 192.168.1.211:45178 --> 104.21.32.39:443 match RuleSet(refilter_ipsum) using Proxy[XHTTP Reality]
[UDP] 192.168.1.211:40758 --> dns.google.com:33435 match AND(((Network,udp) && (RuleSet,refilter_ipsum))) using ProxyUDP[Hysteria2]
```

> **`traceroute` showing real hops means the traffic is bypassing the proxy.** When UDP is genuinely proxied, traceroute shows `*` — the proxy does not generate ICMP TTL-exceeded. This is the opposite of the usual intuition and it costs people hours.

**A newly installed dashboard still looks like the old one.** Every one of these dashboards ships a service worker that caches the whole app in the browser, and it keeps serving the old app after the files change — so the install truthfully reports success while you look at the previous panel. ClashWrt replaces that worker with one that unregisters itself, but an already-registered worker only picks that up on the next navigation: reload the panel tab once.

**The system log looks empty.** `logread` only reads logd's ring buffer. If rsyslog or syslog-ng is installed it takes over `/dev/log`, and from then on `logger` output never reaches that buffer — the log is perfectly healthy in `/var/log/messages` instead. The Logs page detects this and shows which source it is reading. (Also worth knowing: `logread -e` does not understand alternation, so `-e 'a|b'` matches nothing even when both match alone.)

**A LuCI button appears to do nothing.** Reproduce what the page does, then look for an ACL denial:

```sh
ubus call file exec '{"command":"/usr/libexec/clashwrt/fw.sh","params":["status"]}'
logread | grep rpcd
```

Every helper the UI calls must be listed in `/usr/share/rpcd/acl.d/luci-app-clashwrt.json`.

## Building from source

As an OpenWrt feed:

```sh
echo "src-git clashwrt https://github.com/mrFrok/clashwrt.git" >> feeds.conf.default
./scripts/feeds update clashwrt && ./scripts/feeds install -a -p clashwrt
make package/clashwrt/compile package/luci-app-clashwrt/compile
```

Repository layout:

```
clashwrt/              base package — firewall engine, init script, UCI config
  files/usr/libexec/clashwrt/
    fw.sh              the engine: builds the ruleset and policy routing
    selftest.sh        TPROXY capability test
    confctl.sh         validated read/write of mihomo's config
    filectl.sh         rule-list file manager (sandboxed)
    uictl.sh           dashboard installer
    logctl.sh          system log access
luci-app-clashwrt/     LuCI pages (client-side JS), menu, ACL, translations
tools/po2lmo.py        dependency-free .po → .lmo compiler
install.sh
uninstall.sh
```

## Translating

Strings live in `luci-app-clashwrt/po/`. To add a language, copy `templates/clashwrt.pot` to `<lang>/clashwrt.po`, translate it, and compile:

```sh
python3 tools/po2lmo.py luci-app-clashwrt/po/ru/clashwrt.po \
                        luci-app-clashwrt/po/ru/clashwrt.ru.lmo
```

`tools/po2lmo.py` is a dependency-free reimplementation of LuCI's `po2lmo`, so catalogues can be built without the luci-base source tree or the lemon parser generator. Compiled `.lmo` files are committed, because the script installer runs on routers that have no Python.

## Credits

- [mihomo](https://github.com/MetaCubeX/mihomo) — the proxy core.
- [ssclash](https://github.com/zerolabnet/ssclash) — the project this one set out to replace.
- [legiz-ru/mihomo-rule-sets](https://github.com/legiz-ru/mihomo-rule-sets) and [MetaCubeX/meta-rules-dat](https://github.com/MetaCubeX/meta-rules-dat) — the bundled rule sets.

## License

[GPL-3.0-or-later](LICENSE).
