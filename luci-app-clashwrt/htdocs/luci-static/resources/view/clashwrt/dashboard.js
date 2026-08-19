/* SPDX-License-Identifier: GPL-3.0-or-later */
'use strict';
'require view';
'require fs';
'require uci';
'require ui';
'require dom';

var UICTL = '/usr/libexec/clashwrt/uictl.sh';

function say(node, ok, text) {
	dom.content(node, E('div', {
		'class': ok ? 'alert-message success' : 'alert-message warning',
		'style': 'white-space:pre-wrap;margin:8px 0 0 0'
	}, text || (ok ? '' : _('No output.'))));
}

/* fs.exec rejects with an Error when the command fails or is not permitted,
 * and resolves with {code, stdout, stderr} otherwise. Both carry something
 * worth showing, so normalise them into one string rather than swallowing
 * the difference. */
function describe(e) {
	if (!e) return '';
	if (e.stdout || e.stderr) return (e.stdout || '') + (e.stderr || '');
	return String(e.message || e);
}

return view.extend({
	load: function () {
		return Promise.all([
			uci.load('clashwrt'),
			fs.exec(UICTL, ['list']).catch(function (e) { return { stdout: '', error: e }; }),
			fs.exec(UICTL, ['current']).catch(function (e) { return { stdout: '', error: e }; })
		]);
	},

	render: function (data) {
		var listRes = data[1] || {};
		var currentRes = data[2] || {};

		var list = ((listRes.stdout) || '').split('\n')
			.filter(function (l) { return l.trim().length; })
			.map(function (l) { var p = l.split('\t'); return { id: p[0], title: p[1] || p[0] }; });
		var current = ((currentRes.stdout) || '').trim();

		var apiPort = uci.get('clashwrt', 'config', 'api_port') || '9090';
		var uiUrl = 'http://' + window.location.hostname + ':' + apiPort + '/ui/';

		var out = E('div');
		var cur = E('strong', {}, current || '—');

		var sel = E('select', { 'class': 'cbi-input-select' },
			list.length
				? list.map(function (d) { return E('option', { 'value': d.id }, d.title); })
				: [E('option', { 'value': '' }, _('unavailable'))]);

		var customUrl = E('input', {
			'type': 'text', 'class': 'cbi-input-text', 'style': 'width:34em',
			'placeholder': 'https://…/dashboard.tar.gz'
		});

		function run(args, btn, busyText) {
			btn.disabled = true;
			dom.content(out, E('em', {}, busyText));
			fs.exec(UICTL, args).then(function (res) {
				dom.content(out, E('div', {
					'class': 'alert-message success',
					'style': 'white-space:pre-wrap;margin:8px 0 0 0'
				}, [
					E('div', {}, (res.stdout || '') + (res.stderr || '')),
					/* A dashboard already open in another tab is held by its
					 * own service worker until the next navigation, so the
					 * panel can still look unchanged right after installing. */
					E('div', { 'style': 'margin-top:6px' },
						_('If the panel still looks unchanged, reload its tab once — the previous dashboard holds it in the browser cache until then.'))
				]));
				btn.disabled = false;
				return fs.exec(UICTL, ['current']).then(function (r) {
					dom.content(cur, (r.stdout || '').trim() || '—');
				});
			}).catch(function (e) {
				say(out, false, describe(e));
				btn.disabled = false;
			});
		}

		var btnInstall = E('button', {
			'class': 'cbi-button cbi-button-action',
			'style': 'margin-left:6px',
			'click': function (ev) {
				if (!sel.value) { say(out, false, _('No dashboard list available.')); return; }
				run(['install', sel.value], ev.target, _('Downloading and installing…'));
			}
		}, _('Install selected'));

		var btnCustom = E('button', {
			'class': 'cbi-button cbi-button-action',
			'style': 'margin-left:6px',
			'click': function (ev) {
				var u = (customUrl.value || '').trim();
				if (!u) { say(out, false, _('Enter a URL first.')); return; }
				run(['install-url', u], ev.target, _('Downloading and installing…'));
			}
		}, _('Install from URL'));

		/* The dashboard talks to mihomo's API, which only starts serving the
		 * files after a restart when external-ui has just changed. */
		var btnRestart = E('button', {
			'class': 'cbi-button cbi-button-reset',
			'click': function (ev) {
				var b = ev.target;
				b.disabled = true;
				dom.content(out, E('em', {}, _('Restarting mihomo…')));
				fs.exec('/etc/init.d/mihomo', ['restart']).then(function (res) {
					say(out, true, (res.stdout || '') + (res.stderr || '') || _('mihomo restarted.'));
					b.disabled = false;
				}).catch(function (e) {
					say(out, false, describe(e));
					b.disabled = false;
				});
			}
		}, _('Restart mihomo'));

		var openLink = E('a', {
			'href': uiUrl,
			'target': '_blank',
			'rel': 'noopener',
			'class': 'cbi-button cbi-button-apply',
			'style': 'margin-left:6px'
		}, _('Open dashboard'));

		return E('div', { 'class': 'cbi-map' }, [
			E('h2', {}, _('Web dashboard')),
			E('div', { 'class': 'cbi-map-descr' },
				_('The panel mihomo serves at its API port. Any of these can be swapped at any time; the previous one is only removed once the new copy has been checked.')),

			E('div', { 'class': 'cbi-section' }, [
				E('p', {}, [ _('Currently installed: '), cur ]),
				E('p', {}, [
					_('Address: '),
					E('a', { 'href': uiUrl, 'target': '_blank', 'rel': 'noopener' }, uiUrl)
				]),
				E('div', {}, [ openLink, btnRestart ]),

				E('div', { 'style': 'margin-top:14px' }, [
					E('label', { 'style': 'margin-right:6px' }, _('Dashboard:')),
					sel, btnInstall
				]),

				E('div', { 'style': 'margin-top:14px' }, [
					E('div', { 'style': 'font-size:90%;opacity:0.75;margin-bottom:4px' },
						_('Or install any other dashboard from a .tar.gz archive containing index.html. Note that .zip is not supported: OpenWrt images routinely ship without unzip.')),
					customUrl, btnCustom
				]),

				out
			])
		]);
	},

	handleSave: null,
	handleSaveApply: null,
	handleReset: null
});
