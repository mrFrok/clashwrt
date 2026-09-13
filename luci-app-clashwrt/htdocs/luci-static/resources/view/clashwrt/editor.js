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

/* YAML highlighting without a library.
 *
 * A textarea cannot render styled text, and pulling in a real editor is not an
 * option here: the page is served from the router and the CSP-free CDN route
 * does not exist. So the textarea is made transparent and laid over a <pre>
 * that holds the same text, tokenised. The two must agree on every metric that
 * affects glyph position — font, size, line height, padding, wrapping — or the
 * caret drifts away from the letters.
 */
var HL_METRICS =
	'font-family:monospace;font-size:12px;line-height:1.45;' +
	'white-space:pre;overflow-wrap:normal;' +
	'margin:0;padding:8px;border:1px solid transparent;' +
	'tab-size:4;';

function esc(t) {
	return t.replace(/&/g, '&amp;').replace(/</g, '&lt;').replace(/>/g, '&gt;');
}

/* Line-oriented on purpose: YAML's meaning is carried by indentation and the
 * first token, which is exactly what a reader scans for. */
function highlightYaml(text) {
	return (text || '').split('\n').map(function (line) {
		var m = line.match(/^(\s*)(#.*)$/);
		if (m) return esc(m[1]) + '<span class="cw-c">' + esc(m[2]) + '</span>';

		var out = '', rest = line;

		var lead = rest.match(/^(\s*(?:-\s+)?)/)[1];
		out += esc(lead);
		rest = rest.slice(lead.length);

		var kv = rest.match(/^([A-Za-z0-9_.\/-]+)(\s*:)(.*)$/);
		if (kv) {
			out += '<span class="cw-k">' + esc(kv[1]) + '</span>' + esc(kv[2]);
			rest = kv[3];
		}

		/* a trailing comment is not part of the value */
		var cmt = '';
		var ci = rest.indexOf(' #');
		if (ci >= 0) { cmt = rest.slice(ci); rest = rest.slice(0, ci); }

		if (rest.length) {
			var v = rest;
			if (/^\s*(true|false|null|~)\s*$/i.test(v))
				out += v.replace(/(\S+)/, '<span class="cw-b">$1</span>');
			else if (/^\s*-?\d+(\.\d+)?\s*$/.test(v))
				out += v.replace(/(\S+)/, '<span class="cw-n">$1</span>');
            else
				out += esc(v)
					.replace(/(&#39;[^&]*?&#39;|&quot;[^&]*?&quot;|'[^']*'|"[^"]*")/g, '<span class="cw-s">$1</span>');
		}
		if (cmt) out += '<span class="cw-c">' + esc(cmt) + '</span>';
		return out;
	}).join('\n');
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

		var hlPre = E('pre', {
			'aria-hidden': 'true',
			'style': HL_METRICS +
				'position:absolute;inset:0;overflow:auto;pointer-events:none;' +
				'border-radius:4px;background:var(--background-color-medium,rgba(127,127,127,0.08));'
		});

		var area = E('textarea', {
			'id': 'clashwrt-config',
			'spellcheck': 'false',
			'style': HL_METRICS +
				'position:absolute;inset:0;width:100%;height:100%;resize:none;' +
				'overflow:auto;background:transparent;color:transparent;' +
				'caret-color:var(--color-fg,#ccc);border-radius:4px;'
		}, text);

		var styleTag = E('style', {}, [
			'.cw-k{color:#7aa2f7}',
			'.cw-s{color:#9ece6a}',
			'.cw-n{color:#ff9e64}',
			'.cw-b{color:#bb9af7}',
			'.cw-c{color:#767b91;font-style:italic}',
			':root[data-theme="light"] .cw-k{color:#1a56c4}',
			':root[data-theme="light"] .cw-s{color:#2c7a2c}',
			':root[data-theme="light"] .cw-n{color:#b05500}',
			':root[data-theme="light"] .cw-b{color:#7c3aed}',
			':root[data-theme="light"] .cw-c{color:#6b7280}'
		].join('\n'));

		function repaint() {
			/* trailing newline keeps the last line scrollable into view */
			hlPre.innerHTML = highlightYaml(area.value) + '\n';
			hlPre.scrollTop = area.scrollTop;
			hlPre.scrollLeft = area.scrollLeft;
		}
		area.addEventListener('input', repaint);
		area.addEventListener('scroll', function () {
			hlPre.scrollTop = area.scrollTop;
			hlPre.scrollLeft = area.scrollLeft;
		});

		var editorBox = E('div', {
			'style': 'position:relative;width:100%;height:60vh'
		}, [ styleTag, hlPre, area ]);

		repaint();   /* the file is already loaded, so paint it once up front */

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
					.then(function (res) { area.value = res.stdout || ''; repaint(); say(out, true, _('Reloaded from disk.')); })
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
							.then(function (res) { area.value = res.stdout || ''; repaint(); })
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
				editorBox,
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
