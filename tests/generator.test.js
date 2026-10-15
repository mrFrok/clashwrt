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

console.log(n + ' generator tests passed');
