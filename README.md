<div align="center">

# ClashWrt

**Transparent proxy for OpenWrt, built on [mihomo](https://github.com/MetaCubeX/mihomo)**<br>
LuCI interface · setup wizard · four interception modes · fits small routers

[![Release](https://img.shields.io/github/v/release/mrFrok/clashwrt?style=flat-square&color=2ea44f)](https://github.com/mrFrok/clashwrt/releases/latest)
[![CI](https://img.shields.io/github/actions/workflow/status/mrFrok/clashwrt/ci.yml?branch=main&style=flat-square&label=CI)](https://github.com/mrFrok/clashwrt/actions/workflows/ci.yml)
[![OpenWrt](https://img.shields.io/badge/OpenWrt-22.03%2B%20(fw4)-00B5E2?style=flat-square&logo=openwrt&logoColor=white)](https://openwrt.org)
[![License](https://img.shields.io/badge/license-GPL--3.0-blue?style=flat-square)](LICENSE)

**English** · [Русский](README.ru.md)

</div>

```sh
wget -qO- https://raw.githubusercontent.com/mrFrok/clashwrt/main/install.sh | sh
```

An alternative to ssclash, written because transparent proxying fails in ways that are hard to see: the rules look right, the counters go up, and the traffic quietly goes nowhere. ClashWrt makes those failures visible and gives you a mode that works on every kernel.

<p align="center">
<a href="#highlights">Highlights</a> ·
<a href="#requirements">Requirements</a> ·
<a href="#install">Install</a> ·
<a href="#storage-and-memory">Storage and memory</a> ·
<a href="#why-four-modes">Four modes</a> ·
<a href="#using-it">Using it</a> ·
<a href="#configuration">Configuration</a> ·
<a href="#how-it-works">How it works</a> ·
<a href="#troubleshooting">Troubleshooting</a> ·
<a href="#building-from-source">Building</a>
</p>

---

## Highlights

| | |
|---|---|
| 🧭 **Four interception modes** | TPROXY is not usable on every kernel, so there is a working fallback for each combination of what your kernel honours — and a **test that tells you which one to use**. |
| 🪄 **Setup wizard** | Paste a subscription URL or node links, pick DNS and a routing strategy, get a working `config.yaml` with inbounds matched to the mode. |
| 💾 **Fits small routers** | The 55 MB core can be kept **packed on flash** (22 MB) or **only in RAM**; the dashboard too. The installer works out what fits. |
| 🔐 **Checked downloads** | The core and ClashWrt's own updates must match the SHA-256 GitHub lists for them. |
| 🚀 **Kernel bypass** | What goes direct anyway skips mihomo in the kernel, so **flow offloading** and **SQM** work for it. |
| 🛡️ **Leak protection** | IPv6, DNS-over-TLS and (optionally) DNS-over-HTTPS are refused while the proxy is on. |
| 🔀 **TCP/UDP split** | UDP through Hysteria2/TUIC, the rest through Reality/VLESS — one button, on any config. |
| 🧯 **Kill switches & watchdog** | Proxy, core or both off in one click; an opt-in watchdog goes direct — or blocks — when the VPN dies. |
| 📝 **Editors that validate** | Config and rule lists are checked with `mihomo -t` before anything is installed, with backups. |
| 🌐 **English and Russian** | The whole interface. |

ClashWrt owns the firewall and routing layer only. Your `config.yaml`, your proxies and your rules stay yours: the wizard writes one if you ask it to, the editors validate before touching it, and nothing is rewritten behind your back.

## Requirements

- **OpenWrt 22.03 or newer** with the **fw4/nftables** firewall; `apk` (25.12+) and `opkg` (23.05/24.10) both work. On 21.02 and older (fw3/iptables) the installer refuses rather than installing rules the firewall would silently ignore.
- `nftables`, `ip-full`, `kmod-nft-nat`, `kmod-tun`, `curl` — added by the installer if missing. `kmod-nft-tproxy` only for the TPROXY modes; `socat` only for the TPROXY self-test.
- The mihomo core, downloaded for your CPU: arm64, armv5/6/7, x86_64, i386, mips/mipsel, mips64/mips64el, riscv64.

**Room.** mihomo itself uses 60–90 MB of RAM while running. Where its 55 MB binary lives is up to you:

| Core kept | Flash | Extra RAM | Needs |
|---|---|---|---|
| on flash | ~60 MB | — | any RAM |
| packed on flash | ~22 MB | ~55 MB | 256 MB RAM or more |
| only in RAM | — | ~55 MB | 256 MB RAM, GitHub reachable at boot |

A router with 128 MB of RAM *and* little flash cannot run mihomo at all — give it the flash with [extroot](https://openwrt.org/docs/guide-user/additional-software/extroot_configuration) on a USB stick.

Developed and tested on OpenWrt 25.12 on a BananaPi BPI-R4 (`mediatek/filogic`). The 23.05 and 24.10 feeds and LuCI APIs were checked for compatibility; if something breaks there, please open an issue.

## Install

```sh
wget -qO- https://raw.githubusercontent.com/mrFrok/clashwrt/main/install.sh | sh
```

The installer shows the router's RAM and free flash, then asks — **Enter takes the recommended answer** worked out from those numbers:

1. **Version** — the latest release (checked against its SHA-256) or the development branch.
2. **Where to keep the core** — on flash, packed on flash, or only in RAM. Only what fits is offered.
3. **Dashboard** — metacubexd, zashboard, Yacd-meta or none, and where to keep it.
4. **dnsmasq-full** — lets the bypass set take your config's domains.

It sums up and asks before changing anything. Then it installs, and stops: **nothing is intercepted until you enable it**, so a bad install cannot take the network down. Re-running upgrades in place and keeps your configuration.

Then open **Services → ClashWrt**, run the setup wizard, and switch the proxy on from the Overview page.

> [!NOTE]
> The questions are read from the terminal even when the script comes through a pipe. Without a terminal — the **Update** button in LuCI — nothing is asked and the earlier answers are kept. If the CPU cannot be recognised, the installer asks for the mihomo build by name (`uname -m` says `mips` on both endiannesses, so OpenWrt's own `DISTRIB_ARCH` is read first).

### Updating

Overview → Maintenance has a button for each of the two things that update on their own: it shows the installed mihomo version against the latest release, and ClashWrt's version against the latest one.

- **Update core** downloads the mihomo build for this CPU, keeps it where Settings → Storage says, and restarts the daemon if it was running.
- **Update ClashWrt** re-runs the installer, which keeps `/etc/config/clashwrt`, `config.yaml` and the core. Whether the core was on or off at boot is kept too. It runs detached, with the log on the page, because it replaces the LuCI pages and restarts `rpcd` — expect to log in again at the end.

**Every download is checked.** GitHub records a SHA-256 for every file attached to a release. A core whose `.gz` does not match is not installed (`core_verify '0'` allows releases GitHub gives no digest for); a ClashWrt release ships its own tarball and installer, and both must match too. This catches a download corrupted, cut short or swapped on the way — through a proxy node, say. It does not protect against a release that was bad at its source: neither mihomo nor ClashWrt signs its releases. The development branch has nothing to check against and says so.

**Downloads go through the proxy first**, directly only if that fails, so a blocked or throttled GitHub does not stop an update. The wizard's config has a listener for this, `clashwrt-fetch` on `127.0.0.1:7899`, that sends everything to the `Proxy` group whatever the rules say; a hand-written config without it falls back to its own `mixed-port` or `socks-port`. `fetch_via_proxy '0'` fetches directly. The watchdog's checks stay direct on purpose: they test the VPN from outside it.

```sh
/usr/libexec/clashwrt/updctl.sh core-status          # installed vs. latest, and where it is
/usr/libexec/clashwrt/updctl.sh core-install         # latest release
/usr/libexec/clashwrt/updctl.sh core-install v1.19.30
/usr/libexec/clashwrt/updctl.sh self-status
```

<details>
<summary><b>Spare cores</b></summary>

A mihomo binary is ~55 MB, because Go links its whole runtime into the file. Two copies kept by hand before an upgrade are most of a typical overlay — and keeping one is the obvious thing to do, so they accumulate.

Updating the core removes the spares afterwards, once the new one is installed and known good. What it removes is deliberately narrow: a file in `/usr/bin`, named `mihomo`-something, that is not the live `/usr/bin/mihomo`, is not running, and says it is Mihomo when asked. A differently named core next to it — `sing-box`, say — is never touched. Every deletion is printed.

```sh
/usr/libexec/clashwrt/updctl.sh cores        # what is there, and what is live
/usr/libexec/clashwrt/updctl.sh prune-cores  # remove the spares now
KEEP_OLD_CORES=1 ... core-install            # update without removing anything
```

</details>

### Uninstall

```sh
wget -qO- https://raw.githubusercontent.com/mrFrok/clashwrt/main/uninstall.sh | sh

KEEP_CORE=1 sh uninstall.sh        # leave mihomo installed
KEEP_CONFIG=1 sh uninstall.sh      # leave /etc/mihomo and the UCI config
ASSUME_YES=1 sh uninstall.sh       # do not ask
```

It takes the ruleset down *before* deleting the scripts that know how, and removes the fw4 zone it created.

## Storage and memory

**Settings → Storage and memory.** The core and the dashboard are the only big things ClashWrt puts on a router — about 60 of its 65 MB — so each can be kept three ways:

| `core_store` / `ui_store` | On flash | At boot |
|---|---|---|
| `flash` | the binary / the dashboard directory | nothing to do |
| `gz` | the release's own `.gz` (22 MB) / the dashboard archive (2–10 MB) | unpacked into RAM, offline |
| `ram` | a one-line note of the version | downloaded into RAM |

In the RAM modes `/usr/bin/mihomo` and `/etc/mihomo/ui` become symlinks into `/tmp`, so everything that runs `mihomo` by name still finds it. Moving between modes copies first and deletes last — there is never a moment without a core — and nothing moves into RAM unless there is clearly room: the router has 256 MB or more, free RAM stays above max(32 MB, 15 %), and `/tmp` keeps a quarter free. A packed core is checked against its recorded SHA-256 before every unpack.

> [!WARNING]
> **Only in RAM** means a download at every boot. Until GitHub answers there is no core, and LAN traffic gets whatever **When the VPN fails** says; the download is retried every minute in the background, and mihomo starts as soon as it is there. **Packed on flash** has no such gap and is what the installer recommends when flash is short.

**Memory.** ClashWrt keeps mihomo's footprint down where it can:

- **A soft memory ceiling** for mihomo's Go runtime (`core_mem_limit`): `auto` sets 48 MB under 256 MB of RAM and 96 MB under 512 MB, so the collector works harder instead of the heap growing. Nothing is killed past it.
- **No GeoIP database.** Private networks are matched by `IP-CIDR` rules, not `GEOIP,private`, which would make mihomo download an 8 MB `geoip.metadb` — and fail its config check while GitHub is out of reach.
- **Binary rule sets.** The wizard fetches geosite/geoip lists as `.mrs`, a fifth of the YAML's size and loaded without parsing.
- **No process lookups** (`find-process-mode: off`): the processes behind LAN connections are not on the router.
- **Fewer dnsmasq domains.** A name whose parent is also listed is dropped — dnsmasq matches subdomains anyway (−7 % on Re-filter).
- **Providers in RAM**, only while RAM can spare it — see [below](#providers-in-ram).

```sh
/usr/libexec/clashwrt/updctl.sh core-store flash|gz|ram
/usr/libexec/clashwrt/uictl.sh store flash|gz|ram
/usr/libexec/clashwrt/updctl.sh core-where           # where it is, flash and RAM free
```

## Why four modes

Transparent proxying has three usable mechanisms, and none of them works everywhere:

| Mechanism | TCP | UDP | Notes |
|---|:-:|:-:|---|
| **TPROXY** | ✅ | ✅ | The correct one. Keeps the original destination for both protocols without a tun device. Broken on some kernels. |
| **NAT redirect** | ✅ | ❌ | Always works, but there is no `SO_ORIGINAL_DST` for datagrams. |
| **TUN device** | ✅ | ✅ | Works everywhere, but every packet crosses userspace. |

TPROXY being "broken" is not hypothetical. On MediaTek's `mtk-openwrt-feeds` kernel the nft rule matches, the packet is marked and routed to the local table, the counter goes up — and the kernel never hands it to the `IP_TRANSPARENT` socket. Conntrack sits at `SYN_SENT [UNREPLIED]`, the client hangs. The same config works on stock OpenWrt. So the mode is a knob, not an assumption:

| `mode` | TCP path | UDP path | When to use |
|---|---|---|---|
| `tproxy` | TPROXY → `tproxy-port` | TPROXY → `tproxy-port` | Your kernel honours TPROXY. Fastest and most correct. |
| `tproxy_tun` | TPROXY → `tproxy-port` | fwmark → tun | TPROXY works for TCP but not UDP. |
| `tun` | fwmark → tun | fwmark → tun | Works everywhere. Simplest. |
| `redirect_tun` | NAT → `redir-port` | fwmark → tun | TPROXY unusable. TCP stays on the fast in-kernel path. |

Do not guess — press **Test TPROXY support**:

```
tproxy rule matched : 4 packets
socket received     : 0
client result       : rc=000

FAIL -- the rule matches but the socket never receives the connection.
This kernel cannot be used with TPROXY, no matter how it is configured.
Recommended mode: redirect_tun (or tun)
```

In the tun modes the wizard turns on **GSO** for the kernel stacks (`system`, `mixed`): mihomo gets whole 64 KB segments instead of single packets, which is most of what a fast link costs in TUN mode.

## Using it

Everything is under **Services → ClashWrt**:

| Page | What it is for |
|---|---|
| **Overview** | State at a glance, current node and delay, bypass state, kill switches, Maintenance (status, updates, split, dashboard, backup) |
| **Setup wizard** | Builds a `config.yaml` |
| **Configuration** | Editor, Backups, Rule files |
| **Settings** | Basic, Bypass, Storage and memory, Advanced |
| **Logs** | Live mihomo log and the system log |

### Overview and the kill switches

The Overview refreshes every 5 seconds. Under the status pill it shows the node `Proxy` is using right now — following `Auto` down to the node, with its last delay — and the state of the kernel bypass set. **Open dashboard** passes the API secret to the panel, so a dashboard that has never seen it still connects.

**Proxy** is the switch on display; the others are under **More switches**:

| Switch | When off |
|---|---|
| Proxy | Removes the rules that steer the LAN into mihomo. The router forwards directly, as if ClashWrt were not installed. |
| Core | Stops mihomo and disables it at boot. |
| Everything | Both, in the safe order: rules first when switching off, core first when switching on. |

Switching the core off while the proxy is on asks first, since the LAN would be steered into a core that is not there; switching the proxy on is refused while the core is down.

```sh
/usr/libexec/clashwrt/powerctl.sh status
/usr/libexec/clashwrt/powerctl.sh proxy|core|all on|off
```

### Fail-open watchdog

Off by default (Settings → Basic). A procd daemon asks mihomo to time a request through the proxy group. After `watchdog_fail` failures in a row (3) it checks that the WAN itself works, and only then **bypasses** the proxy. If the WAN is down too, nothing changes — bypassing would not help.

A bypass is held for at least `watchdog_hold` seconds (120) and lifted after `watchdog_ok` good probes (3). If it flaps again within 10 minutes the hold doubles, up to `watchdog_hold_max` (900). For `watchdog_grace` seconds after start (90) it only watches, so a slow boot is not mistaken for an outage. Your switch always wins.

**When the VPN fails** (`watchdog_action`) chooses what happens: `direct` (default) lets traffic out past the proxy; `block` is a **kill switch** — LAN traffic to anywhere but the LAN is refused until the path is back, and the Overview says **Blocked** in red.

```sh
/usr/libexec/clashwrt/watchdog.sh status|probe|reset
```

<details>
<summary><b>DNS during a bypass</b></summary>

If the router's dnsmasq forwards to mihomo's DNS port, a bypass takes that forward out of dnsmasq (the original server list is kept in `/etc/clashwrt-dns.bak` and put back afterwards), so the LAN keeps resolving through the normal upstream. If dnsmasq has no other upstream, DNS stays on mihomo and the Overview warns about it. The probe needs mihomo's `external-controller` and a group; leave `watchdog_group` empty for the group named by the config's final `MATCH` rule.

</details>

### Leak protection

While the proxy is on (Settings → Basic):

| Option | Default | Refuses |
|---|:-:|---|
| `block_ipv6` | on | LAN IPv6 leaving the LAN. Interception is IPv4 only, so IPv6 would show your real address; devices fall back to IPv4. |
| `block_dot` | on | DNS-over-TLS (port 853), e.g. Android Private DNS. |
| `block_doh` | off | HTTPS to public DoH resolvers ([dibdot's list](https://github.com/dibdot/DoH-IP-blocklists), refreshed daily, plus `doh_extra`). |

All are rejected rather than dropped, so devices fall back at once. **Several LAN networks:** `lan_device` is a list — add `guest`, `iot` or a device name, and each is intercepted and protected.

### Setup wizard

Builds a `config.yaml` from a subscription URL or node links (`vless://`, `vmess://`, `trojan://`, `ss://`, `hysteria2://`, `tuic://`). Choose DNS and a routing strategy — *everything direct except the selected lists*, or *everything through the proxy except Russia* — tick the rule sets, apply. Inbounds always match the interception mode.

Bundled lists: `ru-bundle` and `re:filter` ([legiz-ru](https://github.com/legiz-ru/mihomo-rule-sets)), and per-service sets for YouTube, Telegram, Discord, X, Instagram, ChatGPT and Gemini ([meta-rules-dat](https://github.com/MetaCubeX/meta-rules-dat)).

The form opens pre-filled — from the last answers, or read back from the installed `config.yaml`. Node links cannot be recovered from a config, so it warns before dropping inline nodes or replacing a hand-edited file.

**Adding a site.** Type a URL, a hostname or a service name (`youtube`, `claude`, `netflix`, …) and press *Add*: it becomes `DOMAIN-SUFFIX` rules ahead of the lists, sent to the group you pick. Known services expand to their handful of domains, so no big geosite list is loaded for one website. **Add to current config only** inserts just those rules into a hand-written config.

- **DNS.** Quad9 over DoH by default: with `redir-host` mihomo resolves every name itself, and over plain UDP the ISP would see — and could rewrite — each lookup. **Fake-IP** is optional: connections start sooner, but the bypass set is held back.
- **TUN stack.** `system` (fastest, default), `gvisor` or `mixed` for kernels where it misbehaves, `mips` for slow MIPS routers.
- **Fastest node.** A `url-test` group `Auto` follows the fastest node with a 50 ms tolerance; it is the first member of `Proxy`, which stays a `select` group.

### TCP/UDP protocol split

Hysteria2 and TUIC carry datagrams natively; Reality, VLESS and Trojan tunnel them over TCP. One button in Maintenance sends UDP to the former and the rest to the latter — on **whatever config is installed**, the wizard's or your own. The file is edited line by line, so comments survive, and validated before it replaces anything.

```yaml
proxy-groups:
  - {name: Proxy,    type: select, use: [sub1], filter: '(?i)(reality|vless|trojan)'}
  - {name: ProxyUDP, type: select, use: [sub1], filter: '(?i)(hysteria|hy2|tuic)'}
rules:
  - AND,((NETWORK,udp),(RULE-SET,ru_bundle)),ProxyUDP
  - RULE-SET,ru_bundle,Proxy
  - MATCH,DIRECT
```

`filter:` is Go's RE2, which has **no lookahead** — write exclusions as positive patterns.

### Kernel bypass set

A set of destinations that skip mihomo, matched in the kernel before any marking. A connection mihomo never touches stays an ordinary routed one, so **flow offloading** can take it over after the first packets and **SQM** sees each device on its own. A `DIRECT` rule inside mihomo is not the same: that connection still ends on the router and is relayed through userspace.

> [!TIP]
> Traffic that goes *through* mihomo can never be offloaded — it is relayed by the CPU. Hardware offloading (e.g. MediaTek PPE) speeds up only what the bypass lets past. The **Flow offloading** switch on the Bypass tab sets fw4's own option and shows whether the flowtable is active in software or hardware. SQM does not work together with hardware offloading.

What skips depends on mihomo's default — read from your config, not guessed:

| mihomo's last rule | meaning | what skips the proxy |
|---|---|---|
| `MATCH,DIRECT` | direct unless a rule says otherwise | everything except the list |
| `MATCH,<group>` | proxied unless a rule says otherwise | the list |

If neither the config nor the wizard's answers say, the list is refused rather than loaded backwards.

**Your own rules go in too** (`bypass_set_from_config`, the default since 1.2.2): `IP-CIDR`, `DOMAIN`, `DOMAIN-SUFFIX` and `RULE-SET` rules, by direction. Domains go through dnsmasq (`nftset=`), which needs **dnsmasq-full** — the installer offers it, so does the Bypass tab. The set is held back by itself — everything then goes to mihomo, which only costs speed — whenever the config proxies something it cannot hold (domains without dnsmasq-full, DNS hijack on, `GEOSITE`, `DOMAIN-KEYWORD`…). The status block says which.

```sh
/usr/libexec/clashwrt/setctl.sh detect        # the direction, and where it came from
/usr/libexec/clashwrt/setctl.sh status        # list age, what is in the kernel
/usr/libexec/clashwrt/setctl.sh from-config   # what config.yaml adds, and what it could not
/usr/libexec/clashwrt/setctl.sh offload [off|sw|hw]
```

### Providers in RAM

mihomo rewrites its providers on every refresh — tens of MB a day with Re-filter — and on NAND each rewrite is wear. With `providers_in_ram` (on by default) they move to `/tmp` **only while RAM can spare it** (same rules as above, routers under 256 MB never move), and back to flash as soon as that stops holding. A flash copy is kept, so a reboot refills RAM without downloading anything.

### Configuration, backups, logs, dashboard

- **Configuration** edits `config.yaml` with syntax checks, backups and one-click restore; *Rule files* manages the lists file-backed providers point at. Nothing is installed until `mihomo -t` accepts it.
- **Settings backup** (Maintenance) downloads one archive with `/etc/config/clashwrt`, `config.yaml` and your rule files, and restores it — after checking it. Restoring a different storage mode moves the core and the dashboard, with the same room checks.
- **Logs**: mihomo's own log streamed from its API (which rule matched, which node carried it), and the system log around it.
- **Web dashboard**: metacubexd, zashboard, Yacd, or any `.tar.gz` with an `index.html`. The API listens on every interface, so every config the wizard writes has a random `secret:` — enter it in the panel.

## Configuration

**Services → ClashWrt → Settings**, or `/etc/config/clashwrt` — every option has a safe default and a one-line reason next to it.

```
config clashwrt 'config'
	option enabled '1'            # owned by the Proxy switch on the Overview
	option mode 'redirect_tun'
	option lan_device 'auto'       # or a list: lan, guest, iot …
	option wan_device 'auto'
	option tun_device 'clash-tun'
	option mihomo_dir '/etc/mihomo'
	option self_mark '2'
	option block_ipv6 '1'
	option watchdog '0'
	option core_store 'flash'     # flash | gz | ram
	option ui_store 'flash'
	option core_mem_limit 'auto'  # auto | off | MB
	option core_verify '1'
```

`auto` asks netifd which device backs `lan`/`wan`, so renamed bridges, PPPoE and DSA ports work as they are. Listening ports are **read from `config.yaml`**, so the firewall cannot drift from the daemon.

Your mihomo config needs, depending on mode:

```yaml
routing-mark: 2          # every mode
tproxy-port: 7894        # tproxy, tproxy_tun
redir-port: 7893         # redirect_tun
tun:                     # every mode except plain tproxy
  enable: true
  device: clash-tun
  stack: system
  auto-route: false      # ClashWrt does the routing
  auto-redirect: false
```

`routing-mark` matters more than it looks: mihomo tags its own sockets with it and the marking chain returns early on it. Without it, mihomo's connection to your server is intercepted and fed back into mihomo.

## How it works

ClashWrt creates one nftables table, `inet clashwrt`, with a marking chain on `prerouting` and (in `redirect_tun`) a NAT chain ahead of fw4's. It adds `ip rule`s and routing tables 100 (tproxy local delivery) and 151 (tun default route), an fw4 **zone** for the tun device, and `route_localnet=1`. All of it comes down again on `stop`.

<details>
<summary><b>Why a zone rather than an nft rule</b></summary>

Forwarded traffic to and from the tun device is judged by fw4's `forward` chain, `policy drop`. An accept in another table does **not** save the packet: every base chain on a hook is evaluated in priority order, and one chain's accept does not stop a later one from rejecting. The symptom is confusing — your own chain's counter goes up, yet `tcpdump -i <tun>` sees nothing. Declaring a zone in UCI puts the fix inside fw4, which regenerates it on every reload.

</details>

<details>
<summary><b>The stale-route trap</b></summary>

The tun policy route (`default dev clash-tun table 151`) is interface-scoped, so the kernel deletes it whenever the tun device is recreated — on **every mihomo restart**. Nothing reports an error: marked packets fall through to the main table and leave unproxied, which looks exactly like working. A hotplug hook repairs the route the moment the device reappears.

</details>

<details>
<summary><b>Command reference</b></summary>

```sh
/etc/init.d/clashwrt start|stop|reload|status
/usr/libexec/clashwrt/fw.sh status|check|detect|selftest
/usr/libexec/clashwrt/setctl.sh detect|status|from-config|offload
/usr/libexec/clashwrt/powerctl.sh status | proxy|core|all on|off
/usr/libexec/clashwrt/watchdog.sh status|probe|reset
/etc/init.d/mihomo start|stop|restart
/usr/libexec/clashwrt/updctl.sh core-status|core-install [version]|core-store flash|gz|ram|core-where
/usr/libexec/clashwrt/updctl.sh cores|prune-cores|self-status|self-update|log
/usr/libexec/clashwrt/uictl.sh install <name>|store flash|gz|ram|status
```

Stopping mihomo by hand leaves the ruleset up, and in the TPROXY and NAT modes intercepted traffic then fails outright. Use the **Everything** switch (or `powerctl.sh all off`): it takes the rules away first.

</details>

## Troubleshooting

<details>
<summary><b>Everything looks configured, but traffic is not proxied</b></summary>

Test with a real forwarded client, not from the router's shell — the marking chain hooks `prerouting`, which the router's own packets never pass:

```sh
ip netns add test
ip link add veth-c type veth peer name veth-s
ip link set veth-s master br-lan; ip link set veth-s up
ip link set veth-c netns test
ip netns exec test ip addr add 192.168.1.211/24 dev veth-c
ip netns exec test ip link set veth-c up
ip netns exec test ip route add default via 192.168.1.1
ip netns exec test curl -s -o /dev/null -w '%{http_code}\n' https://1.1.1.1/
```

Then see what mihomo did with it, on the Logs page or with `wget -q -O- 'http://127.0.0.1:9090/logs?level=info'`:

```
[TCP] 192.168.1.211:45178 --> 104.21.32.39:443 match RuleSet(refilter_ipsum) using Proxy[XHTTP Reality]
```

> [!IMPORTANT]
> `traceroute` showing real hops means the traffic is **bypassing** the proxy. Genuinely proxied UDP shows `*` — the proxy does not generate ICMP TTL-exceeded.

</details>

<details>
<summary><b>A newly installed dashboard still looks like the old one</b></summary>

Dashboards ship a service worker that keeps serving the old app. ClashWrt replaces it with one that unregisters itself, but an already-registered worker only picks that up on the next navigation: reload the panel tab once.

</details>

<details>
<summary><b>The core is missing after a reboot</b></summary>

With **Only in RAM**, the core is downloaded at boot and retried every minute in the background; `logread | grep clashwrt` shows the attempts. If GitHub is often out of reach from your WAN, switch to **Packed on flash**.

</details>

<details>
<summary><b>The system log looks empty / a LuCI button does nothing</b></summary>

`logread` only reads logd's buffer; with rsyslog or syslog-ng the log is in `/var/log/messages` — the Logs page detects this. For a silent button, reproduce what the page does and look for an ACL denial:

```sh
ubus call file exec '{"command":"/usr/libexec/clashwrt/fw.sh","params":["status"]}'
logread | grep rpcd
```

</details>

## Building from source

```sh
echo "src-git clashwrt https://github.com/mrFrok/clashwrt.git" >> feeds.conf.default
./scripts/feeds update clashwrt && ./scripts/feeds install -a -p clashwrt
make package/clashwrt/compile package/luci-app-clashwrt/compile
```

```
clashwrt/                base package — firewall engine, init script, UCI config
  files/usr/libexec/clashwrt/
    fw.sh                the engine: ruleset and policy routing
    setctl.sh            kernel bypass set, DoH list, flow offloading
    updctl.sh            core builds, storage and updates; self-update
    uictl.sh             dashboards and where they are kept
    provctl.sh           providers in RAM
    powerctl.sh          the kill switches
    watchdog.sh          fail-open watchdog (procd daemon)
    confctl.sh           validated config writes, settings backup
    net.sh               downloads through the proxy, SHA-256 checks
luci-app-clashwrt/       LuCI pages (client-side JS), menu, ACL, translations
tests/                   shell and node tests, run in busybox by CI
tools/po2lmo.py          dependency-free .po → .lmo compiler
install.sh · uninstall.sh
```

## Translating

Strings live in `luci-app-clashwrt/po/`. Copy `templates/clashwrt.pot` to `<lang>/clashwrt.po`, translate, and compile with `python3 tools/po2lmo.py <po> <lmo>` — a dependency-free reimplementation of LuCI's `po2lmo`. Compiled `.lmo` files are committed, since the installer runs on routers without Python.

## Credits

- [mihomo](https://github.com/MetaCubeX/mihomo) — the proxy core.
- [ssclash](https://github.com/zerolabnet/ssclash) — the project this one set out to replace.
- [legiz-ru/mihomo-rule-sets](https://github.com/legiz-ru/mihomo-rule-sets), [MetaCubeX/meta-rules-dat](https://github.com/MetaCubeX/meta-rules-dat), [dibdot/DoH-IP-blocklists](https://github.com/dibdot/DoH-IP-blocklists) — the lists.

## License

[GPL-3.0-or-later](LICENSE).
