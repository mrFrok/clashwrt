/* SPDX-License-Identifier: GPL-3.0-or-later
 *
 * Config generator shared by the wizard and the protocol-split toggle.
 *
 * Both need to produce exactly the same config.yaml from the same answers,
 * so the generator lives here rather than in either page: flipping the split
 * is just "regenerate with one answer changed", not YAML surgery on a file
 * somebody may have hand-edited since.
 */
'use strict';
'require baseclass';

/* Protocols that carry UDP natively. Splitting traffic by protocol only makes
 * sense because these exist: QUIC-based transports handle datagrams as a
 * first-class case, while the TCP-stream ones have to tunnel them. */
var UDP_NATIVE = ['hysteria', 'hysteria2', 'hy2', 'tuic', 'wireguard'];

var RULESETS = {
	'ru-bundle': {
		title: 'ru-bundle (legiz-ru)',
		descr: 'Domains blocked in Russia, plus what typically needs a proxy there.',
		providers: {
			'ru_bundle': { behavior: 'domain', format: 'mrs', url: 'https://github.com/legiz-ru/mihomo-rule-sets/raw/main/ru-bundle/rule.mrs', path: './ru-bundle/rule.mrs' },
			'rknasnblock': { behavior: 'ipcidr', format: 'mrs', url: 'https://github.com/legiz-ru/mihomo-rule-sets/raw/main/ru-bundle/rknasnblock.mrs', path: './ru-bundle/rknasnblock.mrs' }
		}
	},
	're-filter': {
		title: 're:filter',
		descr: 'The re:filter domain and IP lists.',
		providers: {
			'refilter_domains': { behavior: 'domain', format: 'mrs', url: 'https://github.com/legiz-ru/mihomo-rule-sets/raw/main/re-filter/domain-rule.mrs', path: './re-filter/domain-rule.mrs' },
			'refilter_ipsum': { behavior: 'ipcidr', format: 'mrs', url: 'https://github.com/legiz-ru/mihomo-rule-sets/raw/main/re-filter/ip-rule.mrs', path: './re-filter/ip-rule.mrs' }
		}
	},
	'youtube':   { title: 'YouTube',   providers: { 'geosite_youtube':   geosite('youtube') } },
	'telegram':  { title: 'Telegram',  providers: { 'geosite_telegram':  geosite('telegram'), 'geoip_telegram': geoip('telegram') } },
	'discord':   { title: 'Discord',   providers: { 'geosite_discord':   geosite('discord') } },
	'twitter':   { title: 'X / Twitter', providers: { 'geosite_twitter': geosite('twitter') } },
	'instagram': { title: 'Instagram', providers: { 'geosite_instagram': geosite('instagram') } },
	'openai':    { title: 'ChatGPT / OpenAI', providers: { 'geosite_openai': geosite('openai') } },
	'gemini':    { title: 'Google Gemini', providers: { 'geosite_gemini': geosite('google-gemini') } }
};

/* mrs rather than yaml: the same sets in a binary form mihomo loads without
 * parsing, a fifth of the size on flash (geoip/ru: 120 KB against 600 KB)
 * and without the garbage a YAML parse leaves behind on a small router. */
function geosite(name) {
	return {
		behavior: 'domain', format: 'mrs',
		url: 'https://raw.githubusercontent.com/MetaCubeX/meta-rules-dat/refs/heads/meta/geo/geosite/' + name + '.mrs',
		path: './geo/geosite/' + name + '.mrs'
	};
}

function geoip(name) {
	return {
		behavior: 'ipcidr', format: 'mrs',
		url: 'https://raw.githubusercontent.com/MetaCubeX/meta-rules-dat/refs/heads/meta/geo/geoip/' + name + '.mrs',
		path: './geo/geoip/' + name + '.mrs'
	};
}

/* Private and special ranges, kept off the proxy. GEOIP,private would do the
 * same, but makes mihomo download geoip.metadb (8 MB on flash, and a config
 * test that fails while GitHub is out of reach) to answer it. */
var PRIVATE_NETS = [
	'0.0.0.0/8', '10.0.0.0/8', '100.64.0.0/10', '127.0.0.0/8', '169.254.0.0/16',
	'172.16.0.0/12', '192.168.0.0/16', '224.0.0.0/4', '255.255.255.255/32'
];

var DNS_PRESETS = {
	'local-agh':   { title: 'Local resolver (AdGuard Home etc.)', servers: ['127.0.0.1:5335'] },
	/* bootstrap: plain addresses that resolve a DoH server's own name;
	 * that one lookup is all that goes out unencrypted */
	'quad9':       { title: 'Quad9', servers: ['9.9.9.9', '149.112.112.112'] },
	'quad9-doh':   { title: 'Quad9 (DoH)', servers: ['https://dns.quad9.net/dns-query'], bootstrap: ['9.9.9.9', '149.112.112.112'] },
	'cloudflare':  { title: 'Cloudflare', servers: ['1.1.1.1', '1.0.0.1'] },
	'cloudflare-doh': { title: 'Cloudflare (DoH)', servers: ['https://cloudflare-dns.com/dns-query'], bootstrap: ['1.1.1.1', '1.0.0.1'] },
	'google':      { title: 'Google', servers: ['8.8.8.8', '8.8.4.4'] },
	'google-doh':  { title: 'Google (DoH)', servers: ['https://8.8.8.8/dns-query'], bootstrap: ['8.8.8.8', '8.8.4.4'] },
	'custom':      { title: 'Custom', servers: [] }
};

/* ------------------------------------------------------------------ */
/* share-link parsing                                                  */
/* ------------------------------------------------------------------ */

function b64decode(s) {
	s = String(s).replace(/-/g, '+').replace(/_/g, '/');
	while (s.length % 4) s += '=';
	try { return decodeURIComponent(escape(atob(s))); }
	catch (e) { try { return atob(s); } catch (e2) { return ''; } }
}

function qs(search) {
	var out = {};
	(search || '').replace(/^\?/, '').split('&').forEach(function (kv) {
		if (!kv) return;
		var i = kv.indexOf('=');
		var k = i < 0 ? kv : kv.slice(0, i);
		var v = i < 0 ? '' : kv.slice(i + 1);
		try { out[decodeURIComponent(k)] = decodeURIComponent(v); }
		catch (e) { out[k] = v; }
	});
	return out;
}

function tagOf(link, fallback) {
	var h = link.indexOf('#');
	if (h < 0) return fallback;
	try { return decodeURIComponent(link.slice(h + 1)) || fallback; }
	catch (e) { return link.slice(h + 1) || fallback; }
}

/* host:port from a userinfo@host:port authority, IPv6-safe */
function splitAuthority(auth) {
	var at = auth.lastIndexOf('@');
	var userinfo = at >= 0 ? auth.slice(0, at) : '';
	var hostport = at >= 0 ? auth.slice(at + 1) : auth;
	var host, port;
	if (hostport.charAt(0) === '[') {
		var close = hostport.indexOf(']');
		host = hostport.slice(1, close);
		port = hostport.slice(close + 2);
	} else {
		var c = hostport.lastIndexOf(':');
		host = c < 0 ? hostport : hostport.slice(0, c);
		port = c < 0 ? '' : hostport.slice(c + 1);
	}
	return { userinfo: userinfo, host: host, port: parseInt(port, 10) || 0 };
}

function applyTransport(p, q) {
	var net = q.type || q.net || 'tcp';
	if (net === 'h2') net = 'h2';
	p.network = net;

	if (net === 'ws') {
		p['ws-opts'] = { path: q.path || '/' };
		if (q.host) p['ws-opts'].headers = { Host: q.host };
	} else if (net === 'grpc') {
		p['grpc-opts'] = { 'grpc-service-name': q.serviceName || q.path || '' };
	} else if (net === 'h2' || net === 'http') {
		p['h2-opts'] = { path: q.path || '/' };
		if (q.host) p['h2-opts'].host = [q.host];
	}

	var sec = q.security || '';
	if (sec === 'tls' || sec === 'reality' || q.tls === 'tls') p.tls = true;
	if (q.sni || q.peer) p.servername = q.sni || q.peer;
	if (q.fp) p['client-fingerprint'] = q.fp;
	if (q.alpn) p.alpn = q.alpn.split(',');
	if (sec === 'reality') {
		p['reality-opts'] = { 'public-key': q.pbk || '' };
		if (q.sid) p['reality-opts']['short-id'] = q.sid;
	}
	if (q.allowInsecure === '1' || q.insecure === '1') p['skip-cert-verify'] = true;
}

function parseLink(link) {
	link = String(link).trim();
	if (!link) return null;

	var scheme = (link.split('://')[0] || '').toLowerCase();
	var rest = link.slice(scheme.length + 3);
	var hash = rest.indexOf('#');
	var beforeHash = hash < 0 ? rest : rest.slice(0, hash);
	var qmark = beforeHash.indexOf('?');
	var authority = qmark < 0 ? beforeHash : beforeHash.slice(0, qmark);
	var q = qs(qmark < 0 ? '' : beforeHash.slice(qmark));
	var a = splitAuthority(authority);
	var name = tagOf(link, scheme + '-' + a.host);

	var p = { name: name, server: a.host, port: a.port };

	switch (scheme) {
	case 'vless':
		p.type = 'vless';
		p.uuid = a.userinfo;
		p.udp = true;
		if (q.flow) p.flow = q.flow;
		applyTransport(p, q);
		break;

	case 'trojan':
		p.type = 'trojan';
		p.password = a.userinfo;
		p.udp = true;
		applyTransport(p, q);
		p.tls = true;
		break;

	case 'hysteria2':
	case 'hy2':
		p.type = 'hysteria2';
		p.password = a.userinfo;
		if (q.sni) p.sni = q.sni;
		if (q.obfs) { p.obfs = q.obfs; if (q['obfs-password']) p['obfs-password'] = q['obfs-password']; }
		if (q.insecure === '1') p['skip-cert-verify'] = true;
		break;

	case 'tuic':
		p.type = 'tuic';
		var ui = a.userinfo.split(':');
		p.uuid = ui[0] || '';
		p.password = ui[1] || '';
		if (q.sni) p.sni = q.sni;
		if (q.congestion_control) p['congestion-controller'] = q.congestion_control;
		if (q.alpn) p.alpn = q.alpn.split(',');
		if (q.allow_insecure === '1') p['skip-cert-verify'] = true;
		break;

	case 'ss': {
		p.type = 'ss';
		p.udp = true;
		var userinfo = a.userinfo;
		/* ss:// comes in two shapes: base64 of "method:password" in the
		 * userinfo, or base64 of the whole "method:password@host:port". */
		if (!userinfo) {
			var whole = b64decode(authority);
			var w = splitAuthority(whole);
			var mp = w.userinfo.split(':');
			p.cipher = mp[0]; p.password = mp.slice(1).join(':');
			p.server = w.host; p.port = w.port;
		} else {
			var dec = userinfo.indexOf(':') >= 0 ? userinfo : b64decode(userinfo);
			var parts = dec.split(':');
			p.cipher = parts[0];
			p.password = parts.slice(1).join(':');
		}
		break;
	}

	case 'vmess': {
		/* vmess:// is base64 of a JSON blob, not a URL */
		var raw = link.slice('vmess://'.length);
		var h2 = raw.indexOf('#');
		if (h2 >= 0) raw = raw.slice(0, h2);
		var j;
		try { j = JSON.parse(b64decode(raw)); } catch (e) { return null; }
		if (!j || typeof j !== 'object') return null;
		/* The blob is somebody else's JSON: a field that is an object or an
		 * array instead of a string would otherwise reach inlineMap as a
		 * nested map, whose keys are written out as they come. */
		for (var jk in j)
			if (j[jk] !== null && typeof j[jk] === 'object') return null;
		p = {
			name: j.ps || ('vmess-' + j.add),
			type: 'vmess',
			server: j.add,
			port: parseInt(j.port, 10) || 0,
			uuid: j.id,
			alterId: parseInt(j.aid, 10) || 0,
			cipher: j.scy || 'auto',
			udp: true
		};
		applyTransport(p, {
			type: j.net, security: (j.tls === 'tls' || j.tls === true) ? 'tls' : '',
			sni: j.sni || j.host, host: j.host, path: j.path, serviceName: j.path
		});
		break;
	}

	default:
		return null;
	}

	if (!p.server || !p.port) return null;
	return p;
}

/* ------------------------------------------------------------------ */
/* YAML emitting                                                       */
/* ------------------------------------------------------------------ */

function yamlScalar(v) {
	if (typeof v === 'boolean' || typeof v === 'number') return String(v);
	/* a line break inside a quoted scalar is folded by YAML, but has no
	 * business in a node name, a host or a password either */
	var s = String(v).replace(/[\r\n]+/g, ' ');
	if (s === '') return "''";
	if (/^[A-Za-z0-9_.\/@-]+$/.test(s)) return s;
	return "'" + s.replace(/'/g, "''") + "'";
}

/* Keys are the generator's own (type, ws-opts, Host...), so anything else is
 * refused rather than quoted: a key that came out of a pasted link could
 * otherwise close the flow map and start new top-level config keys. */
/* Settings values that are written into config.yaml outside a quoted
 * scalar: a port or mark must be a number, a device name a plain word,
 * a directory an absolute path without anything YAML would read. */
function portOf(v, d) {
	var n = parseInt(v, 10);
	return (String(v).match(/^\d+$/) && n > 0 && n < 65536) ? n : d;
}
function wordOf(v, d) {
	return /^[A-Za-z0-9_.-]{1,15}$/.test(String(v)) ? String(v) : d;
}
function pathOf(v) {
	return /^\/[A-Za-z0-9_.\/-]*$/.test(String(v)) ? String(v) : '';
}

function yamlKey(k) {
	if (!/^[A-Za-z0-9_.-]+$/.test(k))
		throw new Error('refusing to write the key "' + String(k).slice(0, 40) + '"');
	return k;
}

function inlineMap(obj) {
	var parts = [];
	for (var k in obj) {
		if (obj[k] === undefined || obj[k] === null || obj[k] === '') continue;
		yamlKey(k);
		var v = obj[k];
		if (Array.isArray(v)) parts.push(k + ': [' + v.map(yamlScalar).join(', ') + ']');
		else if (typeof v === 'object') parts.push(k + ': {' + inlineMap(v) + '}');
		else parts.push(k + ': ' + yamlScalar(v));
	}
	return parts.join(', ');
}

function proxyToYaml(p) {
	return '  - {' + inlineMap(p) + '}';
}

/* ------------------------------------------------------------------ */
/* editing an existing config in place                                 */
/* ------------------------------------------------------------------ */
/*
 * The wizard can always regenerate, but a config that was written by hand
 * (or by something else entirely) has no answers to regenerate from -- and
 * throwing it away to turn one feature on would be a poor trade. So the
 * split can also be applied as a transformation of whatever is already
 * there.
 *
 * This is deliberately line-based rather than a real YAML round-trip: a
 * parse-and-reserialise would reformat the whole file and lose comments,
 * which matters a lot in a config people maintain by hand. The safety net
 * is that nothing is installed until `mihomo -t` has accepted the result,
 * and the previous version is kept as a backup.
 */

var UDP_GROUP = 'ProxyUDP';
var DEFAULT_DNS = 'quad9-doh';
var FETCH_LISTENER = 'clashwrt-fetch';
var TUN_STACKS = ['system', 'gvisor', 'mixed', 'mips'];
var FAKE_IP_RANGE = '198.18.0.1/16';
var FAKE_IP_FILTER = [
	'*.lan', '*.local', '*.localdomain', '*.home.arpa', 'localhost.ptlink.net',
	'+.pool.ntp.org', 'time.*.com', 'time.*.gov', 'ntp.*.com', '+.time.edu.cn',
	'+.msftconnecttest.com', '+.msftncsi.com', 'connectivitycheck.gstatic.com',
	'+.connectivitycheck.android.com', 'captive.apple.com', 'detectportal.firefox.com',
	'+.stun.*.*', '+.stun.*.*.*'
];
/* url-test groups the wizard adds when it picks the fastest node itself */
var AUTO_GROUP = 'Auto';
var AUTO_UDP_GROUP = 'Auto UDP';

/* Yandex public DNS over HTTPS. Used only for the RU domain set, never as
 * the default resolver. */
var YANDEX_DOH = 'https://common.dot.dns.yandex.net/dns-query';

function indentOf(line) {
	var m = line.match(/^(\s*)/);
	return m ? m[1].length : 0;
}

/* One YAML scalar from the start of `s`: 'single', "double" or plain.
 * A plain scalar ends at "," or "}" inside a {flow} mapping, and only at
 * " #" or the end of the line in block style, so "Auto Select" and
 * "HK, JP" survive intact. Returns null when there is nothing to read. */
function readScalar(s, flow) {
	var m;
	s = String(s).replace(/^\s+/, '');
	if (s.charAt(0) === "'") {
		m = s.match(/^'((?:[^']|'')*)'/);
		return m ? m[1].replace(/''/g, "'") : null;
	}
	if (s.charAt(0) === '"') {
		m = s.match(/^"((?:[^"\\]|\\.)*)"/);
		return m ? m[1].replace(/\\(.)/g, '$1') : null;
	}
	if (flow) s = s.split(/[,}]/)[0];
	s = s.replace(/\s+#.*$/, '').replace(/\s+$/, '');
	return s ? s : null;
}

/* Every proxy-group as { name, start, end } (end exclusive), in file order.
 *
 * Indentation is what separates a new group from a nested list entry -- both
 * begin with "- ", and the entries under `use:` or `proxies:` would otherwise
 * look like the start of the next group and cut the block short. */
function groupEntries(lines) {
	var out = [];
	var r = sectionRange(lines, 'proxy-groups');
	if (!r) return out;
	var base = -1, i, m;
	for (i = r.start; i < r.end; i++) {
		m = lines[i].match(/^(\s*)-\s/);
		if (m) { base = m[1].length; break; }
	}
	if (base < 0) return out;

	var startsHere = function (ln) {
		var mm = ln.match(/^(\s*)-\s/);
		return !!mm && mm[1].length === base;
	};

	var starts = [];
	for (i = r.start; i < r.end; i++)
		if (startsHere(lines[i])) starts.push(i);

	starts.forEach(function (s, k) {
		var end = k + 1 < starts.length ? starts[k + 1] : r.end;
		var name = null, n;
		n = lines[s].match(/^\s*-\s*\{([\s\S]*)$/);
		if (n) {
			m = n[1].match(/(?:^|[{,])\s*name:\s*([\s\S]*)$/);
			if (m) name = readScalar(m[1], true);
		} else {
			m = lines[s].match(/^\s*-\s+name:\s*([\s\S]*)$/);
			if (m) name = readScalar(m[1], false);
		}
		for (var j = s + 1; name === null && j < end; j++) {
			m = lines[j].match(/^(\s+)name:\s*([\s\S]*)$/);
			if (m && m[1].length > base) name = readScalar(m[2], false);
		}
		if (name !== null) out.push({ name: name, start: s, end: end });
	});
	return out;
}

/* [startLine, endLineExclusive] of a named proxy-group, or null. */
function findGroup(lines, name) {
	var all = groupEntries(lines);
	for (var i = 0; i < all.length; i++)
		if (all[i].name === name) return { start: all[i].start, end: all[i].end };
	return null;
}

function rulesRange(lines) {
	var i, start = -1;
	for (i = 0; i < lines.length; i++) {
		if (/^rules:\s*$/.test(lines[i])) { start = i + 1; break; }
	}
	if (start < 0) return null;
	var end = lines.length;
	for (i = start; i < lines.length; i++) {
		var ln = lines[i];
		if (!ln.trim()) continue;
		if (!/^\s*-/.test(ln) && indentOf(ln) === 0) { end = i; break; }
	}
	return { start: start, end: end };
}

/* Split "- IP-CIDR,1.2.3.0/24,Proxy" into its parts, or null if it is not a
 * plain rule ending in the given target. */
function parseRule(line, target) {
	var m = line.match(/^(\s*)-\s*(.+?)\s*$/);
	if (!m) return null;
	var body = m[2];
	if (/^AND,/.test(body) || /^NOT,/.test(body) || /^OR,/.test(body)) return null;
	var parts = body.split(',');
	if (parts.length < 2) return null;
	if (parts[parts.length - 1].trim() !== target) return null;
	return { indent: m[1], parts: parts.slice(0, -1).map(function (s) { return s.trim(); }) };
}

/* ------------------------------------------------------------------ */
/* sites: "add this website" -> DOMAIN-SUFFIX rules                    */
/* ------------------------------------------------------------------ */
/*
 * Domain lists for a few services are inlined here instead of referencing
 * the geosite rule-sets: those are hundreds of thousands of entries that
 * mihomo would load into memory on a router just to route one website. A
 * handful of suffixes does the same job for the service the user named.
 *
 * `keys` are what a user may type instead of a URL, `hosts` are hostnames
 * that identify the service when a URL is pasted (matched as equal-or-
 * subdomain), `suffixes` is what gets emitted.
 */
var SITE_PRESETS = {
	youtube: {
		title: 'YouTube', keys: ['youtube', 'yt'],
		hosts: ['youtube.com', 'youtu.be', 'youtube-nocookie.com', 'youtubekids.com', 'yt.be'],
		suffixes: ['youtube.com', 'youtu.be', 'youtube-nocookie.com', 'youtubekids.com', 'yt.be',
			'googlevideo.com', 'ytimg.com', 'ggpht.com', 'youtubei.googleapis.com']
	},
	instagram: {
		title: 'Instagram', keys: ['instagram', 'insta'],
		hosts: ['instagram.com', 'instagr.am', 'ig.me', 'cdninstagram.com'],
		suffixes: ['instagram.com', 'cdninstagram.com', 'instagr.am', 'ig.me', 'fbcdn.net']
	},
	x: {
		title: 'X / Twitter', keys: ['x', 'twitter'],
		hosts: ['x.com', 'twitter.com', 't.co', 'twimg.com', 'twttr.com'],
		suffixes: ['x.com', 'twitter.com', 't.co', 'twimg.com', 'twttr.com']
	},
	openai: {
		title: 'ChatGPT / OpenAI', keys: ['openai', 'chatgpt'],
		hosts: ['openai.com', 'chatgpt.com', 'oaistatic.com', 'oaiusercontent.com', 'sora.com'],
		suffixes: ['openai.com', 'chatgpt.com', 'oaistatic.com', 'oaiusercontent.com', 'sora.com']
	},
	claude: {
		title: 'Claude / Anthropic', keys: ['claude', 'anthropic'],
		hosts: ['claude.ai', 'claude.com', 'anthropic.com', 'claudeusercontent.com'],
		suffixes: ['claude.ai', 'claude.com', 'anthropic.com', 'claudeusercontent.com']
	},
	discord: {
		title: 'Discord', keys: ['discord'],
		hosts: ['discord.com', 'discord.gg', 'discordapp.com', 'discordapp.net', 'discord.media'],
		suffixes: ['discord.com', 'discord.gg', 'discordapp.com', 'discordapp.net', 'discord.media',
			'discordcdn.com', 'discord.gift', 'discord.new', 'discordstatus.com']
	},
	netflix: {
		title: 'Netflix', keys: ['netflix'],
		hosts: ['netflix.com', 'netflix.net', 'nflxvideo.net', 'nflximg.net', 'nflxext.com'],
		suffixes: ['netflix.com', 'netflix.net', 'nflximg.com', 'nflximg.net', 'nflxvideo.net',
			'nflxext.com', 'nflxso.net']
	},
	spotify: {
		title: 'Spotify', keys: ['spotify'],
		hosts: ['spotify.com', 'scdn.co', 'spoti.fi'],
		suffixes: ['spotify.com', 'scdn.co', 'spotifycdn.com', 'spotifycdn.net', 'spoti.fi',
			'spotilocal.com', 'pscdn.co']
	},
	telegram: {
		title: 'Telegram', keys: ['telegram', 'tg'],
		hosts: ['telegram.org', 'telegram.me', 't.me', 'telegra.ph', 'telesco.pe'],
		suffixes: ['telegram.org', 'telegram.me', 'telegram.dog', 't.me', 'telegra.ph', 'telesco.pe',
			'tdesktop.com', 'cdn-telegram.org', 'tg.dev']
	},
	gemini: {
		title: 'Google Gemini', keys: ['gemini'],
		hosts: ['gemini.google.com', 'bard.google.com', 'aistudio.google.com', 'ai.google.dev',
			'makersuite.google.com', 'generativelanguage.googleapis.com'],
		suffixes: ['gemini.google.com', 'bard.google.com', 'aistudio.google.com', 'ai.google.dev',
			'makersuite.google.com', 'generativelanguage.googleapis.com']
	}
};

function normDomains(list) {
	var seen = {}, out = [];
	(list || []).forEach(function (d) {
		d = String(d).trim().toLowerCase();
		if (d && !seen[d]) { seen[d] = true; out.push(d); }
	});
	return out.sort();
}

function validHost(h) {
	if (!h || h.length > 253) return false;
	if (/^\d+(\.\d+){3}$/.test(h)) return false;          /* IPv4 */
	var labels = h.split('.');
	if (labels.length < 2) return false;
	for (var i = 0; i < labels.length; i++)
		if (!/^[a-z0-9]([a-z0-9-]{0,61}[a-z0-9])?$/.test(labels[i])) return false;
	return !/^\d+$/.test(labels[labels.length - 1]);
}

function presetOf(token, host) {
	for (var k in SITE_PRESETS) {
		var p = SITE_PRESETS[k];
		if (token !== null && (k === token || p.keys.indexOf(token) >= 0)) return p;
		if (host) {
			for (var i = 0; i < p.hosts.length; i++)
				if (host === p.hosts[i] || host.slice(-p.hosts[i].length - 1) === '.' + p.hosts[i])
					return p;
		}
	}
	return null;
}

/* URL, bare host or service name -> list of DOMAIN-SUFFIX values.
 * A host that matches no preset is kept exactly as typed: trimming it to a
 * guessed registrable domain would turn foo.github.io into github.io and
 * proxy every site hosted there. Empty list means the input was rejected. */
function siteDomains(input) {
	var s = String(input === undefined || input === null ? '' : input).trim().toLowerCase();
	if (!s || /\s/.test(s)) return [];

	if (/^[a-z0-9-]+$/.test(s)) {
		var byKey = presetOf(s, null);
		return byKey ? byKey.suffixes.slice() : [];
	}

	s = s.replace(/^[a-z][a-z0-9+.-]*:\/\//, '');
	s = s.replace(/^\/\//, '');
	s = s.split(/[\/?#]/)[0];
	s = s.replace(/^[^@]*@/, '');
	if (s.charAt(0) === '[') return [];                    /* IPv6 literal */
	s = s.replace(/:\d*$/, '').replace(/\.+$/, '').replace(/^www\./, '');

	if (!validHost(s)) return [];

	var p = presetOf(null, s);
	if (p) return p.suffixes.slice();
	return [s];
}

function detectSplit(text) {
	var lines = (text || '').split('\n');
	var hasGroup = !!findGroup(lines, UDP_GROUP);
	var hasRules = lines.some(function (l) {
		return l.indexOf(UDP_GROUP) >= 0 && /^\s*-/.test(l);
	});
	return { group: hasGroup, rules: hasRules, on: hasGroup && hasRules };
}

/* ------------------------------------------------------------------ */
/* reading an installed config (read-only)                             */
/* ------------------------------------------------------------------ */

function unq(v) {
	v = String(v).replace(/\s+#.*$/, '').trim();
	if (v.length > 1 && v.charAt(0) === "'" && v.charAt(v.length - 1) === "'")
		return v.slice(1, -1).replace(/''/g, "'");
	if (v.length > 1 && v.charAt(0) === '"' && v.charAt(v.length - 1) === '"')
		return v.slice(1, -1);
	return v;
}

/* [start, end) of a top-level section's body. Comments and blank lines do
 * not end it; a non-list line at column 0 does. */
function sectionRange(lines, key) {
	var re = new RegExp('^' + key + ':\\s*(#.*)?$');
	var i, start = -1;
	for (i = 0; i < lines.length; i++) {
		if (re.test(lines[i])) { start = i + 1; break; }
	}
	if (start < 0) return null;
	var end = lines.length;
	for (i = start; i < lines.length; i++) {
		var ln = lines[i];
		if (!ln.trim() || /^\s*#/.test(ln)) continue;
		if (indentOf(ln) === 0 && !/^-/.test(ln)) { end = i; break; }
	}
	return { start: start, end: end };
}

/* Items of `key:` inside a range, block list or [a, b] flow list. */
function listUnder(lines, range, key) {
	var out = [];
	if (!range) return out;
	var re = new RegExp('^(\\s+)' + key + ':\\s*(.*)$');
	for (var i = range.start; i < range.end; i++) {
		var m = lines[i].match(re);
		if (!m) continue;
		var rest = m[2].replace(/\s+#.*$/, '').trim();
		if (rest.charAt(0) === '[') {
			rest.replace(/^\[|\]$/g, '').split(',').forEach(function (x) {
				if (x.trim()) out.push(unq(x));
			});
			return out;
		}
		for (var j = i + 1; j < range.end; j++) {
			var it = lines[j].match(/^(\s*)-\s+(.+?)\s*$/);
			if (!lines[j].trim() || /^\s*#/.test(lines[j])) continue;
			if (!it || it[1].length <= m[1].length) break;
			out.push(unq(it[2]));
		}
		return out;
	}
	return out;
}

function groupNames(lines) {
	return groupEntries(lines).map(function (g) { return g.name; });
}

function filterOf(lines, group) {
	var g = findGroup(lines, group);
	if (!g) return '';
	for (var i = g.start; i < g.end; i++) {
		var m = lines[i].match(/filter:\s*('(?:[^']|'')*'|"[^"]*"|[^,}]+)/);
		if (m) return unq(m[1]);
	}
	return '';
}

/* body of a plain "- A,b,c" rule line, or null (AND/OR/NOT, comments) */
function plainRule(line) {
	var m = line.match(/^(\s*)-\s*(.+?)\s*$/);
	if (!m) return null;
	var body = m[2].replace(/\s+#.*$/, '');
	if (/^(AND|OR|NOT|SUB-RULE),/.test(body)) return null;
	return { indent: m[1], parts: body.split(',').map(function (s) { return s.trim(); }) };
}

function parseConfig(text) {
	text = text || '';
	var lines = text.split('\n');
	var res = {
		subs: [], links: 0, dnsServers: [], routing: '', ruleSets: [],
		udpSplit: false, udpFilter: '', tcpFilter: '', yandexDns: false,
		extraDomains: [], extraGroup: 'Proxy', groups: [], generatedByUs: false, secret: '',
		autoBest: false, fakeIp: false, tunStack: ''
	};
	var i, r, m;

	for (i = 0; i < lines.length; i++) {
		if (lines[i].trim()) { res.generatedByUs = /^#\s*Generated by clashwrt/.test(lines[i]); break; }
	}
	for (i = 0; i < lines.length; i++) {
		m = lines[i].match(/^secret:\s*(.*)$/);
		if (m) { res.secret = unq(m[1]); break; }
	}

	r = sectionRange(lines, 'proxy-providers');
	if (r) for (i = r.start; i < r.end; i++) {
		m = lines[i].match(/^\s+url:\s*(.+?)\s*$/);
		if (m) { res.subs.push(unq(m[1])); continue; }
		m = lines[i].match(/^\s+(?!health-check)[^\s:#]+:\s*\{.*?[{,]\s*url:\s*('(?:[^']|'')*'|"[^"]*"|[^,}\s]+)/);
		if (m) res.subs.push(unq(m[1]));
	}

	r = sectionRange(lines, 'proxies');
	if (r) {
		var base = -1;
		for (i = r.start; i < r.end; i++) {
			m = lines[i].match(/^(\s*)-\s/);
			if (!m) continue;
			if (base < 0) base = m[1].length;
			if (m[1].length === base) res.links++;
		}
	}

	r = sectionRange(lines, 'dns');
	res.dnsServers = listUnder(lines, r, 'nameserver');
	if (!res.dnsServers.length) res.dnsServers = listUnder(lines, r, 'default-nameserver');
	if (r) for (i = r.start; i < r.end; i++) {
		if (lines[i].indexOf('rule-set:ru_domains') >= 0) res.yandexDns = true;
		if (/^\s+enhanced-mode:\s*fake-ip\b/.test(lines[i])) res.fakeIp = true;
	}
	r = sectionRange(lines, 'tun');
	if (r) for (i = r.start; i < r.end; i++) {
		m = lines[i].match(/^\s+stack:\s*([a-z]+)/);
		if (m) res.tunStack = m[1];
	}

	/* rule-provider names -> which bundled lists are wholly present */
	var provNames = {};
	r = sectionRange(lines, 'rule-providers');
	if (r) {
		var pbase = -1;
		for (i = r.start; i < r.end; i++) {
			m = lines[i].match(/^(\s+)([^\s:#-][^\s:#]*):/);
			if (!m) continue;
			if (pbase < 0) pbase = m[1].length;
			if (m[1].length === pbase) provNames[m[2]] = true;
		}
	}
	Object.keys(RULESETS).forEach(function (k) {
		var pn = Object.keys(RULESETS[k].providers);
		if (pn.every(function (n) { return provNames[n]; })) res.ruleSets.push(k);
	});

	var sp = detectSplit(text);
	res.udpSplit = sp.on;
	res.udpFilter = filterOf(lines, UDP_GROUP);
	res.tcpFilter = filterOf(lines, 'Proxy');
	res.groups = groupNames(lines);
	res.autoBest = res.groups.indexOf(AUTO_GROUP) >= 0;

	r = sectionRange(lines, 'rules');
	if (r) {
		var lastMatch = null, suffixRules = [];
		for (i = r.start; i < r.end; i++) {
			var pr = plainRule(lines[i]);
			if (!pr) continue;
			if (pr.parts[0] === 'MATCH' && pr.parts.length >= 2) lastMatch = pr.parts[1];
			else if (pr.parts[0] === 'DOMAIN-SUFFIX' && pr.parts.length >= 3)
				suffixRules.push({ d: pr.parts[1].toLowerCase(), g: pr.parts[2] });
		}
		if (lastMatch !== null)
			res.routing = lastMatch === 'DIRECT' ? 'direct_except_list' : 'proxy_except_ru';
		/* Only rules that send a real site to a proxy-group count. System and
		 * service entries (DOMAIN-SUFFIX,local,DIRECT and the like) name no
		 * proxy-group or are not a hostname, so they cannot pick the target. */
		var mine = suffixRules.filter(function (x) {
			return x.g !== UDP_GROUP && res.groups.indexOf(x.g) >= 0 && validHost(x.d);
		});
		if (mine.length) {
			res.extraGroup = mine[0].g;
			res.extraDomains = normDomains(mine
				.filter(function (x) { return x.g === res.extraGroup; })
				.map(function (x) { return x.d; }));
		}
	}

	return res;
}

/* Insert DOMAIN-SUFFIX rules into an existing config without regenerating
 * it: the new rules go in front of the first catch-all-ish rule (a RULE-SET
 * sending to DIRECT, a GEOIP, or MATCH), so they win over the list that
 * would otherwise send the site direct. Everything else is left byte-for-
 * byte as it was. */
function addSiteRules(text, domains, opts) {
	opts = opts || {};
	var group = opts.group || 'Proxy';
	var lines = String(text || '').split('\n');
	var doms = normDomains(domains);

	var rr = sectionRange(lines, 'rules');
	if (!rr) throw new Error('no rules: section found');

	if (/[,\r\n]/.test(group))
		throw new Error('group name "' + group + '" cannot be used in a rule');
	if (group !== 'DIRECT' && group !== 'REJECT' && groupNames(lines).indexOf(group) < 0)
		throw new Error('no proxy-group named "' + group + '"');
	doms.forEach(function (d) {
		if (!validHost(d)) throw new Error('not a valid domain: "' + d + '"');
	});

	var split = group === 'Proxy' && detectSplit(text).on;

	var have = {};
	var anchor = -1, last = -1, i;
	for (i = rr.start; i < rr.end; i++) {
		var pr = plainRule(lines[i]);
		if (!pr) { if (/^\s*-\s/.test(lines[i])) last = i; continue; }
		last = i;
		var t = pr.parts[0];
		if (t === 'DOMAIN-SUFFIX' && pr.parts.length >= 3)
			have[pr.parts[1].toLowerCase() + ',' + pr.parts[2]] = true;
		if (anchor < 0 && (t === 'GEOIP' || t === 'MATCH' ||
			(t === 'RULE-SET' && pr.parts[pr.parts.length - 1] === 'DIRECT')))
			anchor = i;
	}

	var fresh = doms.filter(function (d) { return !have[d + ',' + group]; });
	if (!fresh.length) return text;

	var at = anchor >= 0 ? anchor : last + 1;
	var ref = anchor >= 0 ? lines[anchor] : (last >= 0 ? lines[last] : '');
	var indent = (ref.match(/^(\s*)-/) || [null, '  '])[1];
	var cr = /\r$/.test(ref) ? '\r' : '';
	if (anchor < 0 && last < 0) at = rr.start;

	var add = [];
	fresh.forEach(function (d) {
		if (split) add.push(indent + '- AND,((NETWORK,udp),(DOMAIN-SUFFIX,' + d + ')),' + UDP_GROUP + cr);
		add.push(indent + '- DOMAIN-SUFFIX,' + d + ',' + group + cr);
	});

	var out = lines.slice(0, at).concat(add, lines.slice(at));
	return out.join('\n');
}

return baseclass.extend({
	UDP_NATIVE: UDP_NATIVE,
	RULESETS: RULESETS,
	DNS_PRESETS: DNS_PRESETS,
	UDP_GROUP: UDP_GROUP,
	DEFAULT_DNS: DEFAULT_DNS,
	TUN_STACKS: TUN_STACKS,
	AUTO_GROUP: AUTO_GROUP,
	AUTO_UDP_GROUP: AUTO_UDP_GROUP,
	SITE_PRESETS: SITE_PRESETS,

	siteDomains: siteDomains,
	normDomains: normDomains,
	parseConfig: parseConfig,
	groupNames: groupNames,
	addSiteRules: addSiteRules,

	/* Is the split currently in effect? */
	detectSplit: detectSplit,

	/* Names of nodes declared inline whose protocol carries UDP natively. */
	udpNativeNames: function (text) {
		var names = [];
		(text || '').split('\n').forEach(function (l) {
			if (!/^\s*-\s*\{?.*type:/.test(l)) return;
			var t = l.match(/type:\s*['"]?([a-z0-9_-]+)/i);
			if (!t || UDP_NATIVE.indexOf(t[1].toLowerCase()) < 0) return;
			var n = l.match(/name:\s*(?:'([^']*)'|"([^"]*)"|([^,}]+))/);
			if (n) names.push((n[1] || n[2] || n[3] || '').trim());
		});
		return names;
	},

	enableSplit: function (text, opts) {
		opts = opts || {};
		var tcpGroup = opts.tcpGroup || 'Proxy';
		var udpFilter = opts.udpFilter || '(?i)(hysteria|hy2|tuic)';
		var lines = (text || '').split('\n');

		if (findGroup(lines, UDP_GROUP))
			throw new Error('a group named ' + UDP_GROUP + ' already exists');

		var src = findGroup(lines, tcpGroup);
		if (!src)
			throw new Error('no proxy-group named "' + tcpGroup + '" to base the UDP group on');

		/* Clone the TCP group, rename it, and point it at UDP-capable nodes:
		 * a name filter for provider-sourced groups, explicit names for
		 * inline ones (filter: does not apply to an inline proxies list). */
		var block = lines.slice(src.start, src.end);
		var clone = [];
		var seenFilter = false;
		var inlineNames = this.udpNativeNames(text);
		var usesProvider = block.some(function (l) { return /^\s*(use:|-\s*\{.*use:)/.test(l); });
		var skipProxiesList = false;

		block.forEach(function (l) {
			var renamed = l.replace(
				new RegExp('(name:\\s*[\'"]?)' + tcpGroup + '([\'"]?)'), '$1' + UDP_GROUP + '$2');

			if (/^\s*filter:/.test(renamed)) {
				seenFilter = true;
				clone.push(renamed.replace(/filter:.*$/, "filter: '" + udpFilter + "'"));
				return;
			}

			/* replace an inline proxies list with just the UDP-capable names */
			if (/^\s*proxies:\s*$/.test(renamed) && inlineNames.length) {
				skipProxiesList = true;
				clone.push(renamed);
				var pad = new Array(indentOf(renamed) + 3).join(' ');
				inlineNames.forEach(function (n) { clone.push(pad + '- ' + yamlScalar(n)); });
				return;
			}
			if (skipProxiesList) {
				if (/^\s*-\s/.test(renamed) && indentOf(renamed) > 0) return;   /* old entry */
				skipProxiesList = false;
			}

			clone.push(renamed);
		});

		if (usesProvider && !seenFilter) {
			/* put the filter next to the use: line so it reads naturally */
			for (var i = clone.length - 1; i >= 0; i--) {
				if (/^\s*use:/.test(clone[i])) {
					clone.splice(i + 1, 0,
						new Array(indentOf(clone[i]) + 1).join(' ') + "filter: '" + udpFilter + "'");
					break;
				}
			}
		}

		Array.prototype.splice.apply(lines, [src.end, 0].concat(clone));

		/* now the rules: every rule that sends something to the TCP group
		 * gets a UDP-scoped twin in front of it */
		var rr = rulesRange(lines);
		if (!rr) throw new Error('no rules: section found');

		var out = lines.slice(0, rr.start);
		for (var j = rr.start; j < rr.end; j++) {
			var line = lines[j];
			var r = parseRule(line, tcpGroup);
			if (r) {
				if (r.parts.length === 1 && r.parts[0] === 'MATCH') {
					/* a catch-all cannot be an AND condition */
					out.push(r.indent + '- NETWORK,udp,' + UDP_GROUP);
				} else {
					out.push(r.indent + '- AND,((NETWORK,udp),(' + r.parts.join(',') + ')),' + UDP_GROUP);
				}
			}
			out.push(line);
		}
		out = out.concat(lines.slice(rr.end));

		return out.join('\n');
	},

	disableSplit: function (text) {
		var lines = (text || '').split('\n');

		var kept = lines.filter(function (l) {
			return !(/^\s*-\s/.test(l) && new RegExp(',' + UDP_GROUP + '\\s*$').test(l));
		});

		var g = findGroup(kept, UDP_GROUP);
		if (g) kept.splice(g.start, g.end - g.start);

		return kept.join('\n');
	},


	parseLink: parseLink,

	/* 24 random characters for the controller secret. */
	newSecret: function () {
		var abc = 'ABCDEFGHJKLMNPQRSTUVWXYZabcdefghijkmnopqrstuvwxyz23456789', out = '';
		var buf = new Uint8Array(24);
		window.crypto.getRandomValues(buf);
		for (var i = 0; i < buf.length; i++) out += abc.charAt(buf[i] % abc.length);
		return out;
	},

	/* Split on newlines only, never on whitespace: the #fragment of a share
	 * link is the node name and routinely contains spaces. */
	parseLinks: function (text) {
		var out = [], bad = 0;
		(text || '').split(/[\r\n]+/).forEach(function (line) {
			line = line.trim();
			if (!line || line.indexOf('://') < 0) return;
			if (/^https?:\/\//i.test(line)) return;   /* that is a subscription */
			var p = parseLink(line);
			if (p) out.push(p); else bad++;
		});
		/* names must be unique or mihomo rejects the config */
		var seen = {};
		out.forEach(function (p) {
			var base = p.name, n = 1;
			while (seen[p.name]) p.name = base + ' ' + (++n);
			seen[p.name] = true;
		});
		return { proxies: out, failed: bad };
	},

	/* The wizard has one box for everything a person may paste: subscription
	 * URLs and node links, in any order. http(s) lines are subscriptions,
	 * other scheme://... lines are node links, and anything else is counted
	 * so the page can say it was ignored. */
	splitNodeLines: function (text) {
		var r = { subs: [], links: [], other: 0 };
		(text || '').split(/[\r\n]+/).forEach(function (l) {
			l = l.trim();
			if (!l) return;
			if (/^https?:\/\//i.test(l)) r.subs.push(l);
			else if (/^[a-z][a-z0-9+.-]*:\/\//i.test(l)) r.links.push(l);
			else r.other++;
		});
		return r;
	},

	subscriptionsOf: function (text) {
		return (text || '').split(/[\r\n]+/)
			.map(function (s) { return s.trim(); })
			.filter(function (s) { return /^https?:\/\//i.test(s); });
	},

	/* Does this set of parsed nodes actually contain both families? Only
	 * then is a protocol split meaningful; with subscriptions we cannot
	 * know without fetching, so the caller falls back to offering it. */
	families: function (proxies) {
		var tcp = [], udp = [];
		(proxies || []).forEach(function (p) {
			if (UDP_NATIVE.indexOf(p.type) >= 0) udp.push(p.name);
			else tcp.push(p.name);
		});
		return { tcp: tcp, udp: udp };
	},

	generate: function (o) {
		var L = [];
		var udpSplit = !!o.udpSplit;
		var proxies = o.proxies || [];
		var subs = o.subscriptions || [];
		var sets = o.ruleSets || [];

		L.push('# Generated by clashwrt. Regenerating overwrites hand edits.');
		L.push('mode: rule');
		/* info logs every connection; on a router that is a busy syslog
		 * for nothing. The Logs page can still stream any level. */
		L.push('log-level: warning');
		L.push('ipv6: false');
		L.push('allow-lan: false');
		L.push('unified-delay: true');
		L.push('tcp-concurrent: true');
		/* the processes behind a connection are on the LAN, out of sight of
		 * the router's /proc, so looking them up is work for nothing */
		L.push('find-process-mode: off');
		L.push('external-controller: 0.0.0.0:' + portOf(o.apiPort, 9090));
		/* The controller listens on every interface so the dashboard works
		 * from the LAN, and without a secret anyone there could switch the
		 * proxy or read every device's connections. */
		if (o.secret) L.push('secret: ' + yamlScalar(o.secret));
		if (pathOf(o.externalUi)) L.push('external-ui: ' + pathOf(o.externalUi));
		L.push('');

		/* Inbounds must match the firewall mode, which is the whole reason
		 * this generator lives inside the package that owns the firewall. */
		L.push('# inbounds for firewall mode: ' + o.mode);
		if (o.mode === 'tproxy' || o.mode === 'tproxy_tun')
			L.push('tproxy-port: ' + portOf(o.tproxyPort, 7894));
		if (o.mode === 'redirect_tun')
			L.push('redir-port: ' + portOf(o.redirPort, 7893));
		L.push('routing-mark: ' + (/^\d+$/.test(String(o.selfMark)) ? o.selfMark : 2));

		if (o.mode !== 'tproxy') {
			L.push('tun:');
			L.push('  enable: true');
			L.push('  device: ' + wordOf(o.tunDevice, 'clash-tun'));
			/* system is the kernel's own stack and the fastest; gvisor and
			 * mixed are userspace for kernels that misbehave; mips is
			 * mihomo's userspace stack built for slow MIPS cores */
			var stack = TUN_STACKS.indexOf(o.tunStack) >= 0 ? o.tunStack : 'system';
			L.push('  stack: ' + stack);
			L.push('  auto-route: false');
			L.push('  auto-redirect: false');
			L.push('  auto-detect-interface: false');
			/* GSO hands mihomo whole 64K segments instead of single packets,
			 * which is most of the CPU a fast link costs in TUN mode; the
			 * kernel's stack (system, and mixed for TCP) is what supports it */
			if (stack === 'system' || stack === 'mixed') {
				L.push('  gso: true');
				L.push('  gso-max-size: 65536');
			}
		}
		L.push('');

		/* The router's own downloads (core, updates, dashboards, bypass lists)
		 * come in here, on loopback only, and go to the Proxy group whatever
		 * the rules say: under "direct except the lists" a plain mixed-port
		 * would send github.com DIRECT, which is the one route that may be
		 * blocked. See net.sh. */
		L.push('listeners:');
		L.push('  - name: ' + FETCH_LISTENER);
		L.push('    type: mixed');
		L.push('    port: ' + portOf(o.fetchPort, 7899));
		L.push('    listen: 127.0.0.1');
		L.push('    proxy: Proxy');
		L.push('');

		/* DNS */
		var preset = DNS_PRESETS[o.dnsPreset] || DNS_PRESETS[DEFAULT_DNS];
		var dnsServers = (o.dnsServers && o.dnsServers.length) ? o.dnsServers : preset.servers;
		/* default-nameserver must be plain addresses: it is what resolves
		 * the names of the DoH servers above, and cannot itself need one */
		var boot = dnsServers.filter(function (s) { return /^[0-9.]+(:\d+)?$/.test(s); });
		if (!boot.length) boot = preset.bootstrap || DNS_PRESETS[DEFAULT_DNS].bootstrap;
		L.push('dns:');
		L.push('  enable: true');
		L.push('  ipv6: false');
		L.push('  listen: 0.0.0.0:' + portOf(o.dnsPort, 1053));
		if (o.fakeIp) {
			/* Every name gets an address from this range and mihomo maps it
			 * back. Names that must resolve for real are filtered out: the
			 * LAN itself, time servers (a router whose clock is off cannot
			 * check TLS), and the probes OSes use to detect a captive portal. */
			L.push('  enhanced-mode: fake-ip');
			L.push('  fake-ip-range: ' + FAKE_IP_RANGE);
			L.push('  fake-ip-filter:');
			FAKE_IP_FILTER.forEach(function (f) { L.push('    - ' + yamlScalar(f)); });
		} else {
			L.push('  enhanced-mode: redir-host');
		}
		L.push('  default-nameserver:');
		boot.forEach(function (s) { L.push('    - ' + yamlScalar(s)); });
		L.push('  nameserver:');
		dnsServers.forEach(function (s) { L.push('    - ' + yamlScalar(s)); });
		if (o.directDns && o.directDns.length) {
			L.push('  direct-nameserver:');
			o.directDns.forEach(function (s) { L.push('    - ' + yamlScalar(s)); });
		}

		/* Russian domains resolved by a Russian resolver over DoH. Worth
		 * separating: a resolver abroad hands back whichever CDN node is
		 * closest to *it*, so RU sites end up pointed at distant edges, and
		 * the answers for them are the ones least in need of hiding. */
		if (o.yandexDns) {
			L.push('  nameserver-policy:');
			L.push("    'rule-set:ru_domains': " + yamlScalar(YANDEX_DOH));
		}
		L.push('');

		/* Sniffer: without it, traffic that arrives as a bare IP cannot be
		 * matched against domain rules at all. */
		L.push('sniffer:');
		L.push('  enable: true');
		L.push('  force-dns-mapping: true');
		L.push('  parse-pure-ip: true');
		L.push('  sniff:');
		L.push('    HTTP:');
		L.push('      ports: [80, 8080-8880]');
		L.push('      override-destination: true');
		L.push('    TLS:');
		L.push('      ports: [443, 8443]');
		L.push('    QUIC:');
		L.push('      ports: [443, 8443]');
		L.push("  skip-domain: ['+.lan', '+.local', '+.msftconnecttest.com', '+.apple.com']");
		L.push('');

		/* proxies / providers */
		if (proxies.length) {
			L.push('proxies:');
			proxies.forEach(function (p) { L.push(proxyToYaml(p)); });
			L.push('');
		}

		var providerNames = [];
		if (subs.length) {
			L.push('proxy-providers:');
			subs.forEach(function (u, i) {
				var pn = 'sub' + (i + 1);
				providerNames.push(pn);
				L.push('  ' + pn + ':');
				L.push('    type: http');
				L.push('    url: ' + yamlScalar(u));
				L.push('    interval: 3600');
				L.push('    path: ./providers/' + pn + '.yaml');
				L.push('    health-check: {enable: true, url: "https://www.gstatic.com/generate_204", interval: 300}');
			});
			L.push('');
		}

		/* proxy groups
		 *
		 * With autoBest the rules still point at the select groups, Proxy
		 * and ProxyUDP, but their first member is a url-test group over the
		 * same nodes: mihomo then times every node itself and follows the
		 * fastest, while a node can still be picked by hand in the
		 * dashboard. url-test times through the node, so it works for the
		 * QUIC protocols in the UDP group as much as for vless. */
		var names = proxies.map(function (p) { return p.name; });
		var autoBest = o.autoBest !== false;
		var members = function (list, filter) {
			if (list.length) {
				L.push('    proxies:');
				list.forEach(function (n) { L.push('      - ' + yamlScalar(n)); });
			}
			if (providerNames.length) {
				L.push('    use: [' + providerNames.join(', ') + ']');
				if (filter) L.push('    filter: ' + yamlScalar(filter));
			}
		};
		var urlTest = function (name, list, filter) {
			L.push('  - name: ' + name);
			L.push('    type: url-test');
			L.push('    url: https://www.gstatic.com/generate_204');
			L.push('    interval: 300');
			L.push('    tolerance: 50');
			L.push('    lazy: true');
			members(list, filter);
		};
		var udpNames = names.filter(function (n, i) {
			return UDP_NATIVE.indexOf(proxies[i].type) >= 0;
		});
		var udpFilter = o.udpFilter || '(?i)(hysteria|hy2|tuic)';

		L.push('proxy-groups:');
		L.push('  - name: Proxy');
		L.push('    type: select');
		members(autoBest ? [AUTO_GROUP].concat(names) : names, o.tcpFilter);
		if (udpSplit) {
			L.push('  - name: ' + UDP_GROUP);
			L.push('    type: select');
			members(autoBest ? [AUTO_UDP_GROUP].concat(udpNames) : udpNames, udpFilter);
		}
		if (autoBest) {
			urlTest(AUTO_GROUP, names, o.tcpFilter);
			if (udpSplit) urlTest(AUTO_UDP_GROUP, udpNames, udpFilter);
		}
		L.push('');

		/* rule providers */
		var provs = {};
		/* the lists the user picked, and only those, become proxy rules:
		 * a provider added below for DNS alone must never route anything */
		var listed = [];
		sets.forEach(function (k) {
			var rs = RULESETS[k];
			if (!rs) return;
			for (var pn in rs.providers) {
				provs[pn] = rs.providers[pn];
				if (listed.indexOf(pn) < 0) listed.push(pn);
			}
		});
		/* nameserver-policy names this set, so it has to exist even when the
		 * routing strategy would not have pulled it in. */
		if (o.yandexDns)
			provs['ru_domains'] = geosite('category-ru');

		if (o.routing === 'proxy_except_ru') {
			provs['ru_domains'] = geosite('category-ru');
			provs['ru_ips'] = geoip('ru');
		}

		if (Object.keys(provs).length) {
			L.push('rule-providers:');
			for (var pn2 in provs) {
				var pr = provs[pn2];
				L.push('  ' + pn2 + ':');
				L.push('    type: http');
				L.push('    behavior: ' + pr.behavior);
				L.push('    format: ' + pr.format);
				L.push('    url: ' + yamlScalar(pr.url));
				L.push('    path: ' + yamlScalar(pr.path));
				L.push('    interval: 86400');
			}
			L.push('');
		}

		/* rules */
		L.push('rules:');
		var extra = normDomains(o.extraDomains);
		var extraGroup = o.extraGroup || 'Proxy';
		var emitExtra = function () {
			extra.forEach(function (d) {
				if (udpSplit && extraGroup === 'Proxy')
					L.push('  - AND,((NETWORK,udp),(DOMAIN-SUFFIX,' + d + ')),ProxyUDP');
				L.push('  - DOMAIN-SUFFIX,' + d + ',' + extraGroup);
			});
		};
		if (o.routing === 'proxy_except_ru') {
			/* before the RU sets, so a site the user named is not claimed
			 * by them */
			emitExtra();
			L.push('  - RULE-SET,ru_domains,DIRECT');
			L.push('  - RULE-SET,ru_ips,DIRECT');
			PRIVATE_NETS.forEach(function (n) { L.push('  - IP-CIDR,' + n + ',DIRECT,no-resolve'); });
			/* the catch-all cannot be an AND rule, so UDP is split off just
			 * before it */
			if (udpSplit) L.push('  - NETWORK,udp,ProxyUDP');
			L.push('  - MATCH,Proxy');
		} else {
			var order = listed;
			if (udpSplit) {
				order.forEach(function (pn3) {
					L.push('  - AND,((NETWORK,udp),(RULE-SET,' + pn3 + ')),ProxyUDP');
				});
			}
			order.forEach(function (pn4) {
				L.push('  - RULE-SET,' + pn4 + ',Proxy');
			});
			emitExtra();
			L.push('  - MATCH,DIRECT');
		}

		return L.join('\n') + '\n';
	}
});
