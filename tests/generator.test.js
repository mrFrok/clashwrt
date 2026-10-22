'use strict';
var assert = require('assert');
var gen = require('./loadjs').gen();

var n = 0;
function t(name, fn) { fn(); n++; console.log('ok - ' + name); }

var BASE = [
	'proxy-groups:',
	'  - name: Proxy',
	'    type: select',
	'    use:',
	'      - sub1',
	'  - name: Auto Select',
	'    type: url-test',
	'    proxies:',
	'      - n1',
	'  - { name: "HK Fast", type: select, proxies: [a, b] }',
	"  - {name: 'It''s mine', type: select}",
	'  - name: "Quoted: yes" # comment',
	'    type: select',
	'  - { name: Flow Plain, type: select }',
	'rules:',
	'  - DOMAIN-SUFFIX,local,DIRECT',
	'  - RULE-SET,ru,DIRECT',
	'  - MATCH,Proxy',
	''
].join('\n');

t('groupNames reads multiword, quoted and flow names', function () {
	assert.deepStrictEqual(gen.groupNames(BASE.split('\n')),
		['Proxy', 'Auto Select', 'HK Fast', "It's mine", 'Quoted: yes', 'Flow Plain']);
});

t('groupNames with CRLF line endings', function () {
	assert.deepStrictEqual(gen.groupNames(BASE.replace(/\n/g, '\r\n').split('\n')).slice(0, 2),
		['Proxy', 'Auto Select']);
});

t('addSiteRules targets a multiword group', function () {
	var out = gen.addSiteRules(BASE, ['example.com'], { group: 'Auto Select' });
	assert.ok(out.indexOf('  - DOMAIN-SUFFIX,example.com,Auto Select\n') >= 0);
	assert.ok(out.indexOf('example.com') < out.indexOf('RULE-SET,ru,DIRECT'));
});

t('addSiteRules rejects an unknown group and an unusable one', function () {
	assert.throws(function () { gen.addSiteRules(BASE, ['example.com'], { group: 'Auto' }); }, /no proxy-group/);
	assert.throws(function () { gen.addSiteRules(BASE, ['example.com'], { group: 'a,b' }); }, /cannot be used/);
});

t('addSiteRules rejects a bad domain', function () {
	assert.throws(function () { gen.addSiteRules(BASE, ['bad host'], { group: 'Proxy' }); }, /not a valid domain/);
	assert.throws(function () { gen.addSiteRules(BASE, ['x\n  - MATCH,DIRECT'], { group: 'Proxy' }); }, /not a valid domain/);
});

t('addSiteRules is idempotent', function () {
	var once = gen.addSiteRules(BASE, ['example.com'], { group: 'Proxy' });
	assert.strictEqual(gen.addSiteRules(once, ['example.com'], { group: 'Proxy' }), once);
});

t('parseConfig ignores DOMAIN-SUFFIX,local,DIRECT', function () {
	var c = gen.parseConfig(BASE);
	assert.strictEqual(c.extraGroup, 'Proxy');
	assert.deepStrictEqual(c.extraDomains, []);
});

t('parseConfig picks the first rule that names a proxy-group', function () {
	var txt = BASE.replace('  - RULE-SET,ru,DIRECT',
		'  - DOMAIN-SUFFIX,corp.lan,DIRECT\n  - DOMAIN-SUFFIX,Example.com,Auto Select\n  - DOMAIN-SUFFIX,other.org,Proxy\n  - RULE-SET,ru,DIRECT');
	var c = gen.parseConfig(txt);
	assert.strictEqual(c.extraGroup, 'Auto Select');
	assert.deepStrictEqual(c.extraDomains, ['example.com']);
	assert.ok(c.groups.indexOf('Auto Select') >= 0);
});

t('siteDomains keeps an unlisted host as typed', function () {
	assert.deepStrictEqual(gen.siteDomains('https://foo.github.io/x'), ['foo.github.io']);
	assert.deepStrictEqual(gen.siteDomains('news.bbc.co.uk'), ['news.bbc.co.uk']);
	assert.deepStrictEqual(gen.siteDomains('www.example.com'), ['example.com']);
});

t('siteDomains expands presets and rejects junk', function () {
	assert.ok(gen.siteDomains('youtube').length > 1);
	assert.ok(gen.siteDomains('https://music.youtube.com/watch').indexOf('youtube.com') >= 0);
	['', 'a b', '1.2.3.4', '[::1]', 'localhost', '<script>', 'http://'].forEach(function (x) {
		assert.deepStrictEqual(gen.siteDomains(x), [], x);
	});
});

t('every preset suffix is a valid host', function () {
	Object.keys(gen.SITE_PRESETS).forEach(function (k) {
		gen.SITE_PRESETS[k].suffixes.forEach(function (s) {
			gen.addSiteRules(BASE, [s], { group: 'Proxy' });
		});
	});
});

t('enableSplit/disableSplit round-trip on a multiword base group', function () {
	var on = gen.enableSplit(BASE, { tcpGroup: 'Auto Select' });
	assert.ok(gen.detectSplit(on).group);
	assert.ok(gen.groupNames(on.split('\n')).indexOf(gen.UDP_GROUP) >= 0);
	assert.ok(gen.groupNames(on.split('\n')).indexOf('HK Fast') >= 0);
	assert.deepStrictEqual(gen.groupNames(gen.disableSplit(on).split('\n')),
		gen.groupNames(BASE.split('\n')));
});

/* A vmess link is base64 JSON from somebody else. */
function vmess(o) { return 'vmess://' + Buffer.from(JSON.stringify(o)).toString('base64'); }
var NODE = { ps: 'n', add: 'h.example', port: 443, net: 'tcp' };
function topKeys(y) {
	return y.split('\n').filter(function (l) { return /^[A-Za-z]/.test(l); })
		.map(function (l) { return l.split(':')[0]; });
}

t('a vmess field that is an object is refused, not written as a nested map', function () {
	var evil = Object.assign({}, NODE,
		{ id: { 'x: 1}\nsecret: attacker\nlisteners: [{port: 1080}]\nz: #': 1 } });
	var r = gen.parseLinks(vmess(evil));
	assert.strictEqual(r.proxies.length, 0);
	assert.strictEqual(r.failed, 1);
});

t('line breaks in a node name stay inside its quoted scalar', function () {
	var r = gen.parseLinks(vmess(Object.assign({}, NODE, { id: 'u', ps: "a'\nsecret: x\n" })));
	var y = gen.generate({ proxies: r.proxies, mode: 'tproxy', routing: 'direct_except_list' });
	assert.strictEqual(topKeys(y).indexOf('secret'), -1);
});

t('inlineMap refuses a key that is not the generator\'s own', function () {
	assert.throws(function () {
		gen.generate({ proxies: [{ name: 'n', type: 'ss', server: 's', port: 1, 'a\nb': 1 }],
			mode: 'tproxy', routing: 'direct_except_list' });
	});
});

t('the controller gets the secret it is given, and parseConfig reads it back', function () {
	var y = gen.generate({ proxies: [], mode: 'tproxy', routing: 'direct_except_list', secret: 'S3cret' });
	assert.ok(/^secret: S3cret$/m.test(y));
	assert.strictEqual(gen.parseConfig(y).secret, 'S3cret');
	var none = gen.generate({ proxies: [], mode: 'tproxy', routing: 'direct_except_list' });
	assert.strictEqual(topKeys(none).indexOf('secret'), -1);
});

t('autoBest adds url-test groups first in Proxy and ProxyUDP', function () {
	var proxies = gen.parseLinks([
		'vless://u@a.example:443?security=tls#V1',
		'hysteria2://p@b.example:443#H1'
	].join('\n')).proxies;
	var y = gen.generate({ proxies: proxies, mode: 'tproxy', routing: 'direct_except_list', udpSplit: true });
	var groups = gen.groupNames(y.split('\n'));
	assert.deepStrictEqual(groups, ['Proxy', 'ProxyUDP', 'Auto', 'Auto UDP']);
	assert.ok(/- name: Auto\n    type: url-test/.test(y));
	assert.ok(/- name: Proxy\n    type: select\n    proxies:\n      - Auto\n/.test(y));
	assert.ok(/- name: ProxyUDP\n    type: select\n    proxies:\n      - 'Auto UDP'\n      - H1\n/.test(y));
	assert.ok(/- name: Auto UDP\n    type: url-test[\s\S]*?proxies:\n      - H1\n/.test(y));
	assert.strictEqual(gen.parseConfig(y).autoBest, true);
	var off = gen.generate({ proxies: proxies, mode: 'tproxy', routing: 'direct_except_list', autoBest: false });
	assert.deepStrictEqual(gen.groupNames(off.split('\n')), ['Proxy']);
});

t('DNS defaults to DoH, with plain-address bootstrap', function () {
	var y = gen.generate({ proxies: [], mode: 'tproxy', routing: 'direct_except_list' });
	assert.ok(/  enhanced-mode: redir-host\n/.test(y));
	assert.ok(/  default-nameserver:\n    - 9\.9\.9\.9\n    - 149\.112\.112\.112\n  nameserver:\n    - 'https:\/\/dns\.quad9\.net\/dns-query'\n/.test(y));
	var custom = gen.generate({ proxies: [], mode: 'tproxy', routing: 'direct_except_list',
		dnsServers: ['https://dns.example/dns-query', '1.1.1.1'] });
	assert.ok(/  default-nameserver:\n    - 1\.1\.1\.1\n  nameserver:/.test(custom));
});

t('fakeIp writes fake-ip with a filter, and parseConfig reads it back', function () {
	var y = gen.generate({ proxies: [], mode: 'tproxy', routing: 'direct_except_list', fakeIp: true });
	assert.ok(/  enhanced-mode: fake-ip\n  fake-ip-range: 198\.18\.0\.1\/16\n  fake-ip-filter:\n/.test(y));
	assert.ok(/    - '\*\.lan'\n/.test(y));
	assert.strictEqual(gen.parseConfig(y).fakeIp, true);
	assert.strictEqual(gen.parseConfig(gen.generate({ proxies: [], mode: 'tproxy', routing: 'direct_except_list' })).fakeIp, false);
});

t('the Yandex DNS set is used for DNS only, never as a proxy rule', function () {
	[false, true].forEach(function (split) {
		var y = gen.generate({ proxies: [], mode: 'tproxy', routing: 'direct_except_list',
			ruleSets: Object.keys(gen.RULESETS).slice(0, 1), yandexDns: true, udpSplit: split });
		var rules = y.slice(y.indexOf('\nrules:'));
		assert.ok(/\n  ru_domains:\n/.test(y), 'provider present');
		assert.ok(/'rule-set:ru_domains'/.test(y), 'nameserver-policy present');
		assert.strictEqual(rules.indexOf('ru_domains'), -1, 'not in rules (split=' + split + ')');
	});
});

t('mihomo logs at warning by default', function () {
	assert.ok(/^log-level: warning$/m.test(gen.generate({ proxies: [], mode: 'tproxy', routing: 'direct_except_list' })));
});

t('the fetch listener sends the router downloads to Proxy, on loopback', function () {
	var y = gen.generate({ proxies: [], mode: 'tproxy', routing: 'direct_except_list', fetchPort: '7899' });
	assert.ok(/\nlisteners:\n  - name: clashwrt-fetch\n    type: mixed\n    port: 7899\n    listen: 127\.0\.0\.1\n    proxy: Proxy\n/.test(y));
});

t('the TUN stack is written as chosen, read back, and anything else is system', function () {
	gen.TUN_STACKS.forEach(function (k) {
		var y = gen.generate({ proxies: [], mode: 'tun', routing: 'direct_except_list', tunStack: k });
		assert.ok(new RegExp('\n  stack: ' + k + '\n').test(y), k);
		assert.strictEqual(gen.parseConfig(y).tunStack, k);
	});
	var bad = gen.generate({ proxies: [], mode: 'tun', routing: 'direct_except_list', tunStack: 'x\ny: 1' });
	assert.ok(/\n  stack: system\n/.test(bad));
});

t('TUN gets GSO on the kernel stacks only', function () {
	['system', 'mixed', 'gvisor', 'mips'].forEach(function (k) {
		var y = gen.generate({ proxies: [], mode: 'tun', routing: 'direct_except_list', tunStack: k });
		assert.strictEqual(/\n  gso: true\n  gso-max-size: 65536\n/.test(y), k === 'system' || k === 'mixed', k);
	});
	assert.ok(!/gso:/.test(gen.generate({ proxies: [], mode: 'tproxy', routing: 'direct_except_list' })));
});

t('no process lookups, and no GEOIP that would pull geoip.metadb', function () {
	var y = gen.generate({ proxies: [], mode: 'tproxy', routing: 'proxy_except_ru' });
	assert.ok(/\nfind-process-mode: off\n/.test(y));
	assert.ok(!/GEOIP/.test(y));
	assert.ok(/\n  - IP-CIDR,192\.168\.0\.0\/16,DIRECT,no-resolve\n/.test(y));
	assert.ok(/\n  - IP-CIDR,10\.0\.0\.0\/8,DIRECT,no-resolve\n/.test(y));
});

t('geosite and geoip rule-sets are fetched as mrs', function () {
	var y = gen.generate({ proxies: [], mode: 'tproxy', routing: 'proxy_except_ru' });
	assert.ok(/geo\/geosite\/category-ru\.mrs/.test(y));
	assert.ok(/geo\/geoip\/ru\.mrs/.test(y));
	assert.ok(!/meta-rules-dat.*\.yaml/.test(y));
});

t('one box: subscriptions, node links and noise are told apart', function () {
	var r = gen.splitNodeLines('  https://sub.example/a \nvless://x@h:443?y#n\n\njunk line\nHYSTERIA2://p@h:1\nhttp://b\n');
	assert.deepStrictEqual(r.subs, ['https://sub.example/a', 'http://b']);
	assert.deepStrictEqual(r.links, ['vless://x@h:443?y#n', 'HYSTERIA2://p@h:1']);
	assert.strictEqual(r.other, 1);
	assert.deepStrictEqual(gen.splitNodeLines(''), { subs: [], links: [], other: 0 });
});

console.log(n + ' generator tests passed');
