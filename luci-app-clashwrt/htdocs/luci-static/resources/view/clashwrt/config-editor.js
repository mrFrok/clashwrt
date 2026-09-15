/* SPDX-License-Identifier: GPL-3.0-or-later */
'use strict';
'require view';
'require fs';
'require ui';
'require dom';

var UI_VERSION = '0.1.5';

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
/* Every metric that decides where a glyph lands must match between the two
 * layers, or the caret drifts away from the letters. The theme fights for some
 * of them -- proton2025 forces a proportional font onto textarea with
 * !important when its system-font option is on -- and an ordinary inline style
 * loses to that. Setting them as important inline properties wins, and does so
 * whatever theme is installed. */
var HL_FONT = 'ui-monospace, SFMono-Regular, Menlo, Consolas, "Liberation Mono", monospace';

var HL_METRICS = {
	'font-family': HL_FONT,
	'font-size': '12px',
	'font-weight': '400',
	'font-style': 'normal',
	'line-height': '1.45',
	'letter-spacing': '0',
	'word-spacing': '0',
	'text-transform': 'none',
	'text-indent': '0',
	'padding': '8px',
	'margin': '0',
	'border': '1px solid transparent',
	'box-sizing': 'border-box',
	'white-space': 'pre',
	'overflow-wrap': 'normal',
	'word-break': 'normal',
	'tab-size': '4',
	'max-width': 'none'
};

function applyMetrics(el) {
	for (var k in HL_METRICS)
		el.style.setProperty(k, HL_METRICS[k], 'important');
}

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

/* fs.exec resolves whatever the command exits with; only an RPC or permission
 * failure rejects. So the promise settling is not the answer to "did it work"
 * -- the exit code is. Reading the one for the other is how a rejected config
 * came back in a green success box with the parser's complaint inside it. */
function ok(res) {
	return !!res && res.code === 0;
}

function textOf(res) {
	if (!res) return '';
	return (res.stdout || '') + (res.stderr || '');
}

/* mihomo locates a syntax error by line, which is only useful if the line can
 * be found. Pull the number out so the editor can go there. */
function errorLine(text) {
	var m = /(?:^|[^0-9])line[\s:]+(\d+)/i.exec(text || '');
	return m ? parseInt(m[1], 10) : 0;
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
			'style': 'position:absolute;left:0;right:0;top:0;bottom:0;overflow:auto;' +
				'pointer-events:none;border-radius:4px;' +
				'background:var(--background-color-medium,rgba(127,127,127,0.08));'
		});

		/* A third layer, to the left of the other two. It carries the same
		 * metrics as they do, because a number that does not sit level with
		 * its line is worse than no number at all. Only the vertical scroll is
		 * mirrored -- it must not drift sideways with the text. */
		var gutter = E('pre', {
			'aria-hidden': 'true',
			'style': 'position:absolute;left:0;top:0;bottom:0;overflow:hidden;' +
				'text-align:right;pointer-events:none;user-select:none;' +
				'border-radius:4px 0 0 4px;' +
				'background:var(--background-color-medium,rgba(127,127,127,0.08));' +
				'opacity:0.6;'
		});

		var area = E('textarea', {
			'id': 'clashwrt-config',
			'spellcheck': 'false',
			'style': 'position:absolute;left:0;right:0;top:0;bottom:0;resize:none;' +
				'overflow:auto;background:transparent;color:transparent;' +
				'caret-color:var(--color-fg,#ccc);border-radius:4px;'
		}, text);

		var styleTag = E('style', {}, [
			'.cw-k{color:#7aa2f7}',
			'.cw-s{color:#9ece6a}',
			'.cw-n{color:#ff9e64}',
			'.cw-b{color:#bb9af7}',
			'.cw-c{color:#767b91;font-style:italic}',
			'.cw-err{color:#f7768e;font-weight:700;opacity:1}',
			':root[data-theme="light"] .cw-k{color:#1a56c4}',
			':root[data-theme="light"] .cw-s{color:#2c7a2c}',
			':root[data-theme="light"] .cw-n{color:#b05500}',
			':root[data-theme="light"] .cw-b{color:#7c3aed}',
			':root[data-theme="light"] .cw-c{color:#6b7280}',
			':root[data-theme="light"] .cw-err{color:#c5221f}'
		].join('\n'));

		/* Which line the last check complained about, 0 for none. */
		var badLine = 0;

		function paintGutter() {
			var n = area.value.split('\n').length;
			var width = 'calc(' + String(n).length + 'ch + 16px)';

			/* Widening the gutter has to move the other two layers with it, or
			 * the text slides under the numbers at 10, 100, 1000 lines. */
			gutter.style.setProperty('width', width, 'important');
			hlPre.style.setProperty('left', width, 'important');
			area.style.setProperty('left', width, 'important');

			var rows = [];
			for (var i = 1; i <= n; i++)
				rows.push(i === badLine
					? '<span class="cw-err">' + i + '</span>'
					: String(i));
			gutter.innerHTML = rows.join('\n') + '\n';
		}

		function repaint() {
			/* trailing newline keeps the last line scrollable into view */
			hlPre.innerHTML = highlightYaml(area.value) + '\n';
			paintGutter();
			syncScroll();
		}

		function syncScroll() {
			hlPre.scrollTop = area.scrollTop;
			hlPre.scrollLeft = area.scrollLeft;
			gutter.scrollTop = area.scrollTop;
		}

		/* Editing invalidates the mark: the line the parser named is not
		 * necessarily the same line any more. */
		area.addEventListener('input', function () { badLine = 0; repaint(); });
		area.addEventListener('scroll', syncScroll);

		/* Put the caret on the offending line and bring it into view. A line
		 * number in a message is only half an answer when the file is long. */
		function goToLine(n) {
			var lines = area.value.split('\n');
			if (!n || n < 1 || n > lines.length) return;

			var start = 0, i;
			for (i = 0; i < n - 1; i++) start += lines[i].length + 1;

			var lh = parseFloat(window.getComputedStyle(area).lineHeight) || 17;
			area.scrollTop = Math.max(0, (n - 1) * lh - area.clientHeight / 2);
			area.focus();
			area.setSelectionRange(start, start + lines[n - 1].length);
			syncScroll();
		}

		/* Report an outcome: colour by the exit code, and if the message
		 * located a line, mark it and go there. */
		function report(res) {
			var body = textOf(res);
			var good = ok(res);
			badLine = good ? 0 : errorLine(body);
			paintGutter();
			say(out, good, body || (good ? _('Done.') : _('No output.')));
			if (badLine) goToLine(badLine);
		}

		var editorBox = E('div', {
			'style': 'position:relative;width:100%;height:60vh'
		}, [ styleTag, gutter, hlPre, area ]);

		applyMetrics(gutter);
		applyMetrics(hlPre);
		applyMetrics(area);

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
					.then(report)
					.catch(function (e) {
						say(out, false, textOf(e) || String(e.message || e));
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
									.then(report)
									.catch(function (e) {
										say(out, false, textOf(e) || String(e.message || e));
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
					.then(function (res) {
						badLine = 0;
						area.value = res.stdout || '';
						repaint();
						say(out, ok(res), ok(res)
							? _('Reloaded from disk.')
							: textOf(res));
					})
					.catch(function (e) {
						say(out, false, textOf(e) || String(e.message || e));
					})
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
								say(out, ok(res), textOf(res));
								return confctl(['read']);
							})
							.then(function (res) {
								badLine = 0;
								area.value = res.stdout || '';
								repaint();
							})
							.catch(function (e) {
								say(out, false, textOf(e) || String(e.message || e));
							})
							.finally(function () { busy(b, false); });
					}
				}, _('Restore selected'))
			]);
		}

		return E('div', { 'class': 'cbi-map' }, [
			E('h2', {}, [
				_('Mihomo configuration'),
				E('span', { 'style': 'font-size:55%;font-weight:normal;opacity:0.6;margin-left:8px' },
					'ui ' + UI_VERSION)
			]),
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
