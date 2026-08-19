/* SPDX-License-Identifier: GPL-3.0-or-later */
'use strict';
'require view';
'require fs';
'require ui';
'require dom';

var STAGING = '/tmp/clashwrt-staging';
var CONFCTL = '/usr/libexec/clashwrt/confctl.sh';

function confctl(args) {
	return fs.exec(CONFCTL, args);
}

/* Content goes to a staging file first and is installed by the helper only
 * after mihomo has accepted it. A config that fails to parse takes the proxy
 * down on the next restart, which on a router means no internet at all. */
function stage(text) {
	return fs.write(STAGING, text);
}

function say(node, ok, text) {
	dom.content(node, E('div', {
		'class': ok ? 'alert-message success' : 'alert-message warning',
		'style': 'white-space:pre-wrap;margin:8px 0 0 0'
	}, text));
}

return view.extend({
	load: function () {
		return Promise.all([
			confctl(['read']).catch(function () { return { stdout: '' }; }),
			confctl(['backups']).catch(function () { return { stdout: '' }; })
		]);
	},

	render: function (data) {
		var text = (data[0] && data[0].stdout) ? data[0].stdout : '';
		var backups = ((data[1] && data[1].stdout) ? data[1].stdout : '')
			.split('\n').filter(function (s) { return s.trim().length; });

		var area = E('textarea', {
			'id': 'clashwrt-config',
			'style': 'width:100%;min-height:60vh;font-family:monospace;font-size:12px;white-space:pre;overflow-wrap:normal;overflow-x:auto',
			'spellcheck': 'false'
		}, text);

		var out = E('div', { 'id': 'clashwrt-editor-out' });

		var busy = function (btn, on) { btn.disabled = on; };

		var btnValidate = E('button', {
			'class': 'cbi-button cbi-button-action',
			'click': function (ev) {
				var b = ev.target;
				busy(b, true);
				dom.content(out, E('em', {}, _('Checking…')));
				stage(area.value)
					.then(function () { return confctl(['validate']); })
					.then(function (res) {
						say(out, true, (res.stdout || '') + (res.stderr || ''));
					})
					.catch(function (e) {
						say(out, false, (e.stdout || '') + (e.stderr || '') || String(e));
					})
					.finally(function () { busy(b, false); });
			}
		}, _('Check syntax'));

		var btnSave = E('button', {
			'class': 'cbi-button cbi-button-positive',
			'style': 'margin-left:6px',
			'click': function (ev) {
				var b = ev.target;
				ui.showModal(_('Save and apply'), [
					E('p', {}, _('The configuration will be checked, backed up and installed, then mihomo will be restarted. If the check fails nothing is changed.')),
					E('div', { 'class': 'right' }, [
						E('button', {
							'class': 'cbi-button',
							'click': ui.hideModal
						}, _('Cancel')),
						' ',
						E('button', {
							'class': 'cbi-button cbi-button-positive',
							'click': function () {
								ui.hideModal();
								busy(b, true);
								dom.content(out, E('em', {}, _('Applying…')));
								stage(area.value)
									.then(function () { return confctl(['apply']); })
									.then(function (res) {
										say(out, true, (res.stdout || '') + (res.stderr || ''));
									})
									.catch(function (e) {
										say(out, false, (e.stdout || '') + (e.stderr || '') || String(e));
									})
									.finally(function () { busy(b, false); });
							}
						}, _('Save and apply'))
					])
				]);
			}
		}, _('Save and apply'));

		var btnReload = E('button', {
			'class': 'cbi-button',
			'style': 'margin-left:6px',
			'click': function (ev) {
				var b = ev.target;
				busy(b, true);
				confctl(['read'])
					.then(function (res) { area.value = res.stdout || ''; say(out, true, _('Reloaded from disk.')); })
					.finally(function () { busy(b, false); });
			}
		}, _('Discard changes'));

		var restoreRow = null;
		if (backups.length) {
			var sel = E('select', { 'class': 'cbi-input-select' },
				backups.map(function (b) { return E('option', { 'value': b }, b); }));

			restoreRow = E('div', { 'style': 'margin-top:1em' }, [
				E('label', { 'style': 'margin-right:6px' }, _('Backups:')),
				sel,
				' ',
				E('button', {
					'class': 'cbi-button cbi-button-neutral',
					'click': function (ev) {
						var b = ev.target;
						busy(b, true);
						dom.content(out, E('em', {}, _('Restoring…')));
						confctl(['restore', sel.value])
							.then(function (res) {
								say(out, true, (res.stdout || '') + (res.stderr || ''));
								return confctl(['read']);
							})
							.then(function (res) { area.value = res.stdout || ''; })
							.catch(function (e) {
								say(out, false, (e.stdout || '') + (e.stderr || '') || String(e));
							})
							.finally(function () { busy(b, false); });
					}
				}, _('Restore selected'))
			]);
		}

		return E('div', { 'class': 'cbi-map' }, [
			E('h2', {}, _('Mihomo configuration')),
			E('div', { 'class': 'cbi-map-descr' },
				_('Direct editor for config.yaml. Nothing is installed until mihomo has accepted it, and the previous version is kept as a backup.')),
			E('div', { 'class': 'cbi-section' }, [
				area,
				E('div', { 'style': 'margin-top:8px' }, [ btnValidate, btnSave, btnReload ]),
				restoreRow || '',
				out
			])
		]);
	},

	handleSave: null,
	handleSaveApply: null,
	handleReset: null
});
