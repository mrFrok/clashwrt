/* SPDX-License-Identifier: GPL-3.0-or-later */
'use strict';
'require view';
'require fs';
'require ui';
'require dom';

/* A dashboard of its own, for routers with no room for a web one: the proxy
 * groups, the node each one uses, and a delay test. The router asks the core
 * (apictl.sh), so the controller may listen on 127.0.0.1 only. */
var APICTL = '/usr/libexec/clashwrt/apictl.sh';
var UI_VERSION = '1.9.5';

var GROUPS = [ 'Selector', 'URLTest', 'Fallback', 'LoadBalance', 'Relay' ];

function lastDelay(p) {
	var h = p && p.history;
	return (h && h.length) ? h[h.length - 1].delay : null;
}

function delayBadge(ms) {
	if (ms == null) return E('span', { 'class': 'cw-delay' }, '—');
	if (ms === 0) return E('span', { 'class': 'cw-delay cw-bad' }, _('timeout'));
	return E('span', { 'class': 'cw-delay ' + (ms < 300 ? 'cw-good' : ms < 800 ? 'cw-mid' : 'cw-bad') }, ms + ' ms');
}

function exec(args) {
	return fs.exec(APICTL, args).then(function (r) {
		if (r.code !== 0) throw new Error((r.stderr || r.stdout || '').trim() || _('the core did not answer'));
		return r.stdout || '';
	});
}

return view.extend({
	load: function () {
		return exec([ 'proxies' ]).then(function (out) {
			return JSON.parse(out).proxies || {};
		}).catch(function (e) { return { _error: String(e.message || e) }; });
	},

	/* the order the core lists them in GLOBAL, which is the config's */
	groups: function (px) {
		var names = (px.GLOBAL && px.GLOBAL.all) ? px.GLOBAL.all.slice() : Object.keys(px);
		return names.filter(function (n) {
			return px[n] && GROUPS.indexOf(px[n].type) >= 0 && n !== 'GLOBAL';
		});
	},

	renderGroup: function (px, name, delays) {
		var self = this, g = px[name];
		var nodes = g.all || [];
		var delayOf = function (n) { return (n in delays) ? delays[n] : lastDelay(px[n]); };

		var list = E('div', { 'class': 'cw-nodes' }, nodes.map(function (n) {
			var pick = g.type === 'Selector';
			var el = E(pick ? 'button' : 'div', {
				'class': 'cw-node' + (n === g.now ? ' cw-now' : '') + (pick ? '' : ' cw-static'),
				'title': px[n] ? px[n].type : ''
			}, [ E('span', { 'class': 'cw-name' }, n), delayBadge(delayOf(n)) ]);
			if (pick)
				el.addEventListener('click', function () {
					if (n === g.now) return;
					el.disabled = true;
					exec([ 'select', name, n ]).then(function () { return self.refresh(delays); })
						.catch(function (e) { ui.addNotification(null, E('p', e.message)); el.disabled = false; });
				});
			return el;
		}));

		var btn = E('button', { 'class': 'cbi-button cbi-button-action' }, _('Test delay'));
		btn.addEventListener('click', function () {
			btn.disabled = true;
			dom.content(btn, _('Testing…'));
			exec([ 'delay', name ]).then(function (out) {
				var r = {};
				try { r = JSON.parse(out); } catch (e) {}
				nodes.forEach(function (n) { delays[n] = (n in r) ? r[n] : 0; });
				return self.refresh(delays);
			}).catch(function (e) {
				ui.addNotification(null, E('p', e.message));
				btn.disabled = false;
				dom.content(btn, _('Test delay'));
			});
		});

		return E('div', { 'class': 'cbi-section cw-group' }, [
			E('div', { 'class': 'cw-head' }, [
				E('h3', {}, name),
				E('span', { 'class': 'cw-meta' }, g.type + (g.now ? ' · ' + g.now : '')),
				btn
			]),
			list
		]);
	},

	refresh: function (delays) {
		var self = this;
		return this.load().then(function (px) {
			dom.content(self.body, self.renderBody(px, delays));
		});
	},

	renderBody: function (px, delays) {
		var self = this;
		if (px._error)
			return E('div', { 'class': 'alert-message warning' }, [
				_('The core does not answer: %s').format(px._error), E('br'),
				_('Start it on the Overview page.') ]);
		var gs = this.groups(px);
		if (!gs.length)
			return E('p', {}, _('This configuration has no proxy groups.'));
		return E('div', {}, gs.map(function (n) { return self.renderGroup(px, n, delays); }));
	},

	render: function (px) {
		this.body = E('div', {}, this.renderBody(px, {}));
		return E('div', { 'class': 'cbi-map' }, [
			E('style', {}, [
				'.cw-head{display:flex;align-items:center;gap:12px;flex-wrap:wrap;margin-bottom:8px}',
				'.cw-head h3{margin:0}',
				'.cw-meta{opacity:.65;flex:1}',
				'.cw-nodes{display:grid;grid-template-columns:repeat(auto-fill,minmax(210px,1fr));gap:6px}',
				'.cw-node{display:flex;justify-content:space-between;align-items:center;gap:8px;padding:7px 10px;',
				'border:1px solid rgba(128,128,128,.35);border-radius:6px;background:transparent;color:inherit;',
				'font:inherit;text-align:left;cursor:pointer;min-width:0}',
				'.cw-node:hover{border-color:rgba(128,128,128,.8)}',
				'.cw-static{cursor:default}',
				'.cw-now{border-color:#2f7de1;box-shadow:inset 3px 0 0 #2f7de1}',
				'.cw-name{overflow:hidden;text-overflow:ellipsis;white-space:nowrap}',
				'.cw-delay{font-size:85%;opacity:.8;white-space:nowrap;font-variant-numeric:tabular-nums}',
				'.cw-good{color:#2e9e4f}.cw-mid{color:#c48a00}.cw-bad{color:#d0392b}'
			].join('')),
			E('h2', {}, [ _('Proxies'),
				E('span', { 'style': 'font-size:55%;font-weight:normal;opacity:0.6;margin-left:8px' }, 'ui ' + UI_VERSION) ]),
			E('div', { 'class': 'cbi-map-descr' },
				_('The node each group uses, picked here instead of in a web dashboard. A choice lasts until the core restarts, unless config.yaml keeps it (profile: store-selected: true).')),
			this.body
		]);
	},

	handleSave: null,
	handleSaveApply: null,
	handleReset: null
});
