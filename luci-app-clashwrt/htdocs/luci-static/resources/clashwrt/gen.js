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

function geosite(name) {
	return {
		behavior: 'domain', format: 'yaml',
		url: 'https://raw.githubusercontent.com/MetaCubeX/meta-rules-dat/refs/heads/meta/geo/geosite/' + name + '.yaml',
		path: './geo/geosite/' + name + '.yaml'
	};
}

function geoip(name) {
	return {
		behavior: 'ipcidr', format: 'yaml',
		url: 'https://raw.githubusercontent.com/MetaCubeX/meta-rules-dat/refs/heads/meta/geo/geoip/' + name + '.yaml',
		path: './geo/geoip/' + name + '.yaml'
	};
}

var DNS_PRESETS = {
	'local-agh':   { title: 'Local resolver (AdGuard Home etc.)', servers: ['127.0.0.1:5335'] },
	'quad9':       { title: 'Quad9', servers: ['9.9.9.9', '149.112.112.112'] },
	'quad9-doh':   { title: 'Quad9 (DoH)', servers: ['https://dns.quad9.net/dns-query'] },
	'cloudflare':  { title: 'Cloudflare', servers: ['1.1.1.1', '1.0.0.1'] },
	'cloudflare-doh': { title: 'Cloudflare (DoH)', servers: ['https://cloudflare-dns.com/dns-query'] },
	'google':      { title: 'Google', servers: ['8.8.8.8', '8.8.4.4'] },
	'google-doh':  { title: 'Google (DoH)', servers: ['https://8.8.8.8/dns-query'] },
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
	var s = String(v);
	if (s === '') return "''";
	if (/^[A-Za-z0-9_.\/@-]+$/.test(s)) return s;
	return "'" + s.replace(/'/g, "''") + "'";
}

function inlineMap(obj) {
	var parts = [];
	for (var k in obj) {
		if (obj[k] === undefined || obj[k] === null || obj[k] === '') continue;
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

function indentOf(line) {
	var m = line.match(/^(\s*)/);
	return m ? m[1].length : 0;
}

/* Find the block of a named proxy-group: [startLine, endLineExclusive].
 *
 * Indentation is what separates a new group from a nested list entry -- both
 * begin with "- ", and the entries under `use:` or `proxies:` would otherwise
 * look like the start of the next group and cut the block short. */
function findGroup(lines, name) {
	var i, gi = -1;
	for (i = 0; i < lines.length; i++) {
		if (/^proxy-groups:\s*$/.test(lines[i])) { gi = i; break; }
	}
	if (gi < 0) return null;

	/* the indent of the first list item defines the level groups live at */
	var baseIndent = -1;
	for (i = gi + 1; i < lines.length; i++) {
		if (!lines[i].trim()) continue;
		var mm = lines[i].match(/^(\s*)-\s/);
		if (mm) { baseIndent = mm[1].length; break; }
		if (indentOf(lines[i]) === 0) return null;   /* section is empty */
	}
	if (baseIndent < 0) return null;

	var isGroupStart = function (ln) {
		var m = ln.match(/^(\s*)-\s/);
		return !!m && m[1].length === baseIndent;
	};

	var start = -1;
	for (i = gi + 1; i < lines.length; i++) {
		var ln = lines[i];
		if (!ln.trim()) continue;

		/* a non-indented key that is not a list item ends the section */
		if (indentOf(ln) === 0 && !/^\s*-/.test(ln)) {
			if (start >= 0) return { start: start, end: i };
			break;
		}

		if (isGroupStart(ln)) {
			if (start >= 0) return { start: start, end: i };
			if (new RegExp('^\\s*-\\s*(\\{\\s*)?name:\\s*[\'"]?' + name + '[\'"]?\\s*(,|$|\\})').test(ln))
				start = i;
		}
	}
	return start >= 0 ? { start: start, end: lines.length } : null;
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

return baseclass.extend({
	UDP_NATIVE: UDP_NATIVE,
	RULESETS: RULESETS,
	DNS_PRESETS: DNS_PRESETS,
	UDP_GROUP: UDP_GROUP,

	/* Is the split currently in effect? */
	detectSplit: function (text) {
		var lines = (text || '').split('\n');
		var hasGroup = !!findGroup(lines, UDP_GROUP);
		var hasRules = lines.some(function (l) {
			return l.indexOf(UDP_GROUP) >= 0 && /^\s*-/.test(l);
		});
		return { group: hasGroup, rules: hasRules, on: hasGroup && hasRules };
	},

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

		lines.splice(src.end, 0, ...clone);

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
		L.push('log-level: info');
		L.push('ipv6: false');
		L.push('allow-lan: false');
		L.push('unified-delay: true');
		L.push('tcp-concurrent: true');
		L.push('external-controller: 0.0.0.0:' + (o.apiPort || 9090));
		if (o.externalUi) L.push('external-ui: ' + o.externalUi);
		L.push('');

		/* Inbounds must match the firewall mode, which is the whole reason
		 * this generator lives inside the package that owns the firewall. */
		L.push('# inbounds for firewall mode: ' + o.mode);
		if (o.mode === 'tproxy' || o.mode === 'tproxy_tun')
			L.push('tproxy-port: ' + (o.tproxyPort || 7894));
		if (o.mode === 'redirect_tun')
			L.push('redir-port: ' + (o.redirPort || 7893));
		L.push('routing-mark: ' + (o.selfMark || 2));

		if (o.mode !== 'tproxy') {
			L.push('tun:');
			L.push('  enable: true');
			L.push('  device: ' + (o.tunDevice || 'clash-tun'));
			L.push('  stack: system');
			L.push('  auto-route: false');
			L.push('  auto-redirect: false');
			L.push('  auto-detect-interface: false');
		}
		L.push('');

		/* DNS */
		var dnsServers = (o.dnsServers && o.dnsServers.length)
			? o.dnsServers
			: (DNS_PRESETS[o.dnsPreset] || DNS_PRESETS['quad9']).servers;
		L.push('dns:');
		L.push('  enable: true');
		L.push('  ipv6: false');
		L.push('  listen: 0.0.0.0:' + (o.dnsPort || 1053));
		L.push('  enhanced-mode: redir-host');
		L.push('  default-nameserver:');
		dnsServers.forEach(function (s) { L.push('    - ' + yamlScalar(s)); });
		L.push('  nameserver:');
		dnsServers.forEach(function (s) { L.push('    - ' + yamlScalar(s)); });
		if (o.directDns && o.directDns.length) {
			L.push('  direct-nameserver:');
			o.directDns.forEach(function (s) { L.push('    - ' + yamlScalar(s)); });
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

		/* proxy groups */
		var names = proxies.map(function (p) { return p.name; });
		L.push('proxy-groups:');
		L.push('  - name: Proxy');
		L.push('    type: select');
		if (names.length) {
			L.push('    proxies:');
			names.forEach(function (n) { L.push('      - ' + yamlScalar(n)); });
		}
		if (providerNames.length) {
			L.push('    use: [' + providerNames.join(', ') + ']');
			if (o.tcpFilter) L.push('    filter: ' + yamlScalar(o.tcpFilter));
		}

		if (udpSplit) {
			var udpNames = names.filter(function (n, i) {
				return UDP_NATIVE.indexOf(proxies[i].type) >= 0;
			});
			L.push('  - name: ProxyUDP');
			L.push('    type: select');
			if (udpNames.length) {
				L.push('    proxies:');
				udpNames.forEach(function (n) { L.push('      - ' + yamlScalar(n)); });
			}
			if (providerNames.length) {
				L.push('    use: [' + providerNames.join(', ') + ']');
				L.push('    filter: ' + yamlScalar(o.udpFilter || '(?i)(hysteria|hy2|tuic)'));
			}
		}
		L.push('');

		/* rule providers */
		var provs = {};
		sets.forEach(function (k) {
			var rs = RULESETS[k];
			if (!rs) return;
			for (var pn in rs.providers) provs[pn] = rs.providers[pn];
		});
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
		if (o.routing === 'proxy_except_ru') {
			L.push('  - RULE-SET,ru_domains,DIRECT');
			L.push('  - RULE-SET,ru_ips,DIRECT');
			L.push('  - GEOIP,private,DIRECT,no-resolve');
			/* the catch-all cannot be an AND rule, so UDP is split off just
			 * before it */
			if (udpSplit) L.push('  - NETWORK,udp,ProxyUDP');
			L.push('  - MATCH,Proxy');
		} else {
			var order = Object.keys(provs);
			if (udpSplit) {
				order.forEach(function (pn3) {
					L.push('  - AND,((NETWORK,udp),(RULE-SET,' + pn3 + ')),ProxyUDP');
				});
			}
			order.forEach(function (pn4) {
				L.push('  - RULE-SET,' + pn4 + ',Proxy');
			});
			(o.extraDomains || []).forEach(function (d) {
				if (udpSplit) L.push('  - AND,((NETWORK,udp),(DOMAIN-SUFFIX,' + d + ')),ProxyUDP');
				L.push('  - DOMAIN-SUFFIX,' + d + ',Proxy');
			});
			L.push('  - MATCH,DIRECT');
		}

		return L.join('\n') + '\n';
	}
});
