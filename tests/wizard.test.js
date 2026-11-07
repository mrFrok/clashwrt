'use strict';
/* The setup wizard renders, walks its three steps and refuses to go on
 * without nodes -- under node, with a tiny stand-in for the DOM. */
var assert = require('assert');
var L = require('./loadjs');

function El(tag, attrs, kids) {
	this.tagName = tag; this.attrs = attrs || {}; this.style = {}; this.children = [];
	this.listeners = {}; this.value = ''; this.checked = false; this.disabled = false;
	this.options = []; this.selectedIndex = 0;
	if (typeof this.attrs.style === 'string') this.style.cssText = this.attrs.style;
	if (/display:none/.test(this.attrs.style || '')) this.style.display = 'none';
	/* LuCI's E() takes event handlers as attributes */
	for (var a in this.attrs) if (typeof this.attrs[a] === 'function') this.listeners[a] = [ this.attrs[a] ];
	this.append(kids);
}
El.prototype.append = function (k) {
	if (this.tagName === 'select' && k instanceof El && k.tagName === 'option')
		k.disabledOpt = k.attrs.disabled !== null && k.attrs.disabled !== undefined;
	var self = this;
	if (k === undefined || k === null || k === '') return;
	if (Array.isArray(k)) { k.forEach(function (x) { self.append(x); }); return; }
	if (!(k instanceof El)) { this.children.push(String(k)); return; }
	this.children.push(k);
	if (this.tagName === 'select' && k.tagName === 'option') {
		this.options.push({ value: k.attrs.value, text: k.text(), disabled: !!k.disabledOpt });
		if (!this.value) this.value = k.attrs.value;
	}
	if (this.tagName === 'textarea' && typeof k === 'string') this.value = k;
};
El.prototype.appendChild = function (k) { this.append(k); return k; };
El.prototype.addEventListener = function (ev, fn) { (this.listeners[ev] = this.listeners[ev] || []).push(fn); };
El.prototype.text = function () { return this.children.map(function (c) { return c instanceof El ? c.text() : c; }).join(''); };
El.prototype.focus = El.prototype.scrollIntoView = function () {};
El.prototype.find = function (pred, acc) {
	acc = acc || [];
	if (pred(this)) acc.push(this);
	this.children.forEach(function (c) { if (c instanceof El) c.find(pred, acc); });
	return acc;
};
function E(tag, attrs, kids) {
	if (Array.isArray(attrs) || typeof attrs === 'string' || attrs instanceof El) { kids = attrs; attrs = {}; }
	if (tag === 'textarea' && typeof kids === 'string') { var t = new El(tag, attrs); t.value = kids; return t; }
	return new El(tag, attrs, kids);
}
global.E = E;
global.window = { crypto: require('crypto').webcrypto, setTimeout: setTimeout, location: { hostname: 'r' }, fetch: function () { return Promise.reject(new Error('x')); } };
global.L = { url: function () { return '/x'; } };
String.prototype.format = function () { var a = arguments, i = 0; return this.replace(/%[sd]/g, function () { return a[i++]; }); };

var store = {};
var written = '';
var SUB = 'proxies:\n  - { name: "🇳🇱 Amsterdam", type: vless, server: a }\n  - { name: "🇳🇱 NL hy2", type: hysteria2, server: b }\n' +
	'  - { name: "🇷🇺 Moscow", type: vless, server: c }\n  - { name: "Info: 12 days", type: vless, server: d }\n';
var uci = {
	get: function (c, s, k) { return k === undefined ? (store[s] ? {} : undefined) : (store[s] || {})[k]; },
	set: function (c, s, k, v) { (store[s] = store[s] || {})[k] = v; },
	unset: function (c, s, k) { if (store[s]) delete store[s][k]; },
	add: function (c, t, n) { store[n] = {}; },
	save: function () { return Promise.resolve(); },
	apply: function () { return Promise.resolve(); },
	load: function () { return Promise.resolve(); }
};
var dom = { content: function (n, k) { n.children = []; if (n.tagName === 'select') { n.options = []; n.value = ''; } n.append(k); } };
var gen = L.gen();
var power = { set: function () { return Promise.resolve({ ok: true }); } };
var view = L.load('view/clashwrt/setup-wizard.js', {
	view: { extend: function (o) { return o; } },
	fs: {
		exec: function (cmd, args) {
			if (args && args[0] === 'subfetch')
				return Promise.resolve({ code: 0, stdout: SUB });
			return Promise.resolve({ code: 0, stdout: '' });
		},
		write: function (path, text) { written = text; return Promise.resolve(); }
	},
	ui: { showModal: function () {}, hideModal: function () {} },
	uci: uci, dom: dom, gen: gen, power: power,
	_: function (s) { return s; }
});

var n = 0;
function t(name, fn) { fn(); n++; console.log('ok - ' + name); }

t('Yandex DNS for RU sites is on unless a config of ours turned it off', function () {
	var hand = 'proxies: []\nrules:\n  - MATCH,DIRECT\n';
	assert.strictEqual(view.answersFromConfig(gen.parseConfig(hand)).yandexDns, true, 'a config written elsewhere');
	var off = gen.generate({ proxies: [], mode: 'tproxy', routing: 'direct_except_list', yandexDns: false });
	assert.strictEqual(view.answersFromConfig(gen.parseConfig(off)).yandexDns, false, 'ours, turned off');
	var on = gen.generate({ proxies: [], mode: 'tproxy', routing: 'direct_except_list', yandexDns: true });
	assert.strictEqual(view.answersFromConfig(gen.parseConfig(on)).yandexDns, true, 'ours, on');
});

var page = view.render([ null, { code: 0, stdout: '# Placeholder written by the clashwrt installer.\nmode: rule\n' } ]);
var steps = page.find(function (e) { return e.attrs['data-step']; });
var shown = function () { return steps.filter(function (s) { return s.style.display !== 'none'; }).map(function (s) { return s.attrs['data-step']; }); };
var btn = function (label) { return page.find(function (e) { return e.tagName === 'button' && e.text() === label; }); };
var click = function (b) { b.listeners.click.forEach(function (f) { f({ preventDefault: function () {}, target: b, currentTarget: b }); }); };

t('three steps, the first shown', function () {
	assert.strictEqual(steps.length, 3);
	assert.deepStrictEqual(shown(), [ '1' ]);
});

t('Next refuses without nodes and says so at the field', function () {
	click(btn('Next')[0]);
	assert.deepStrictEqual(shown(), [ '1' ]);
	var err = page.find(function (e) { return e.attrs.id === 'cw-nodes-err'; })[0];
	assert.ok(/Paste a subscription URL/.test(err.text()));
});

t('one box takes a subscription and a link; Next, Next, Back', function () {
	var box = page.find(function (e) { return e.attrs['aria-describedby'] === 'cw-nodes-err'; })[0];
	box.value = 'https://sub.example/x\nvless://u@h:443?security=none#n';
	box.listeners.input.forEach(function (f) { f({ target: box }); });
	click(btn('Next')[0]);
	assert.deepStrictEqual(shown(), [ '2' ]);
	click(btn('Next')[1]);
	assert.deepStrictEqual(shown(), [ '3' ]);
	assert.ok(/1 subscription\(s\), 1 node link\(s\)/.test(page.text()));
	assert.ok(/Interception: Auto/.test(page.text()));
	click(btn('Back')[1]);
	assert.deepStrictEqual(shown(), [ '2' ]);
});

var aiSel = page.find(function (e) { return e.tagName === 'select' && e.options.some(function (o) { return /Looking for countries|node\(s\)/.test(o.text); }); })[0];

/* the one button, end to end, with every call answering well */
global.window.setTimeout = function (f) { return setTimeout(f, 0); };
global.window.fetch = function () { return Promise.resolve({ ok: true, json: function () { return { delay: 48 }; } }); };
click(btn('Next')[1]);
click(btn('Apply and switch on')[0]);
setTimeout(function () {
	t('Apply and switch on: tests the mode once, applies, switches on, checks', function () {
		/* the stand-in selftest says nothing about TPROXY: the safe mode, kept */
		assert.strictEqual(store.config.mode_auto, 'redirect_tun');
		assert.strictEqual(store.config.mode, 'redirect_tun');
		assert.strictEqual(store.wizard.mode_choice, 'auto');
		assert.ok(store.wizard, 'answers saved');
		assert.ok(/Done: the VPN works \(48 ms\)/.test(page.text()), page.text().slice(-300));
	});
	t('AI country: found in the subscription, refused ones off, the top one applied', function () {
		var nl = aiSel.options.filter(function (o) { return o.value === 'NL'; })[0];
		var ru = aiSel.options.filter(function (o) { return o.value === 'RU'; })[0];
		assert.ok(nl && /2 node/.test(nl.text) && !nl.disabled, JSON.stringify(aiSel.options));
		assert.ok(ru && ru.disabled);
		assert.strictEqual(aiSel.value, 'NL', 'the allowed country with most nodes is chosen');
		assert.strictEqual(gen.parseConfig(written).aiCountry, 'NL', 'and reaches the applied config');
		assert.ok(!aiSel.options.some(function (o) { return o.value === ''; }), 'no "any country" choice');
		assert.ok(/5 node\(s\), 3 with a country/.test(page.text()), 'one inline link and four from the subscription');
		aiSel.value = 'NL';
		var form = page.find(function (e) { return e.listeners.change && e.tagName === 'div'; })[0];
		form.listeners.change.forEach(function (f) { f({ target: aiSel }); });
		var preview = page.find(function (e) { return e.tagName === 'textarea' && /^# Generated/.test(e.value); })[0];
		assert.strictEqual(gen.parseConfig(preview.value).aiCountry, 'NL');
	});
	console.log(n + ' wizard tests passed');
}, 200);
