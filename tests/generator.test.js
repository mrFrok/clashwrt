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

console.log(n + ' generator tests passed');
