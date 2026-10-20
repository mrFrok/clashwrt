'use strict';
var assert = require('assert');
var L = require('./loadjs');

var power = L.load('clashwrt/power.js', {
	baseclass: L.baseclass,
	fs: { exec: function () { return Promise.reject(new Error('no router')); } },
	_: function (s) { return s; },
	E: function () { return {}; }
});

var n = 0;
function t(name, fn) { fn(); n++; console.log('ok - ' + name); }

function st(over) {
	var base = { proxy: 'on', core: 'running', rules: 'present', autobypass: 'no',
		service: 'on', svc_live: 'yes', wd_enabled: 'off', wd_running: 'no', wd_state: '' };
	Object.keys(over || {}).forEach(function (k) { base[k] = over[k]; });
	return base;
}
function key(over) { return power.classify(st(over)).key; }

t('parseStatus splits on the first colon only', function () {
	assert.deepStrictEqual(power.parseStatus('a: b\nwd_why: x: y\n\nbad'), { a: 'b', wd_why: 'x: y' });
});

t('pill states', function () {
	assert.strictEqual(key({}), 'active');
	assert.strictEqual(key({ service: 'off', svc_live: 'no', rules: 'absent' }), 'svc_off');
	assert.strictEqual(key({ proxy: 'off', rules: 'present' }), 'stray');
	assert.strictEqual(power.classify(st({ proxy: 'off', rules: 'present', core: 'stopped' })).tone, 'red');
	assert.strictEqual(key({ proxy: 'off', rules: 'absent' }), 'direct');
	assert.strictEqual(key({ proxy: 'off', rules: 'absent', core: 'stopped' }), 'off');
	assert.strictEqual(key({ autobypass: 'yes', rules: 'absent' }), 'bypassed');
	assert.strictEqual(key({ core: 'stopped' }), 'broken');
	assert.strictEqual(key({ rules: 'absent' }), 'broken');
	assert.strictEqual(key({ wd_state: 'wan_down' }), 'wan_down');
});

t('a missing core outranks healthy-looking rules, bypass outranks a stopped core', function () {
	assert.strictEqual(key({ core: 'missing' }), 'broken');
	assert.strictEqual(key({ autobypass: 'yes', rules: 'absent', core: 'stopped' }), 'bypassed');
});

t('service off at boot but still running is "half"', function () {
	var c = power.classify(st({ service: 'off', svc_live: 'yes' }));
	assert.strictEqual(c.half, true);
	assert.strictEqual(c.key, 'active');
});

t('an old powerctl without service/svc_live lines', function () {
	var o = st({}); delete o.service; delete o.svc_live;
	assert.strictEqual(power.classify(o).key, 'active');
	o.rules = 'absent'; o.wd_running = 'no'; o.service = 'off';
	assert.strictEqual(power.serviceLive(o), false);
});

t('unknown without a proxy line', function () {
	assert.strictEqual(power.classify({}).key, 'unknown');
	assert.strictEqual(power.classify(null).key, 'unknown');
});

t('watchdog not running is noted on a protected pill', function () {
	var c = power.classify(st({ wd_enabled: 'on', wd_running: 'no' }));
	assert.strictEqual(c.key, 'active');
	assert.ok(/watchdog is not running/.test(c.message));
});

t('apiSecret reads the top-level secret, quoted or not', function () {
	assert.strictEqual(power.apiSecret('mode: rule\nsecret: abc123\n'), 'abc123');
	assert.strictEqual(power.apiSecret("secret: 'a b' # note\n"), 'a b');
	assert.strictEqual(power.apiSecret('dns:\n  secret: nope\n'), '');
	assert.strictEqual(power.apiSecret(''), '');
});

t('nodeLine follows Proxy -> Auto -> node and takes the node delay', function () {
	var n = power.nodeLine([
		{ name: 'Proxy', type: 'Selector', now: 'Auto' },
		{ name: 'Auto', type: 'URLTest', now: 'NL-1' },
		{ name: 'NL-1', type: 'Vless', history: [ { delay: 90 }, { delay: 48 } ] }
	]);
	assert.deepStrictEqual(n, { path: ['Auto', 'NL-1'], delay: 48 });
	assert.deepStrictEqual(power.nodeLine([{ name: 'Proxy', now: 'X' }, { name: 'X' }]), { path: ['X'], delay: null });
});

t('bypassLine: on, held back, off', function () {
	assert.deepStrictEqual(power.bypassLine('mode:     auto -> include (MATCH,DIRECT in /etc/mihomo/config.yaml)\nin_kernel: 34596 entries\n'),
		{ key: 'on', mode: 'include', entries: 34596 });
	var h = power.bypassLine('mode:     include\nHELD BACK: the set is not used, everything goes to mihomo: install dnsmasq-full\n');
	assert.deepStrictEqual(h, { key: 'held', why: 'install dnsmasq-full' });
	assert.strictEqual(power.bypassLine('mode:     off\n').key, 'off');
});

t('a kill switch reads as blocked, red', function () {
	var c = power.classify(st({ autobypass: 'yes', autobypass_action: 'block', rules: 'absent' }));
	assert.strictEqual(c.key, 'blocked');
	assert.strictEqual(c.tone, 'red');
	assert.strictEqual(power.classify(st({ autobypass: 'yes', autobypass_action: 'direct', rules: 'absent' })).key, 'bypassed');
});

console.log(n + ' power tests passed');
