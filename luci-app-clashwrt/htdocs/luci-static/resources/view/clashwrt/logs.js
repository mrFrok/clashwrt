/* SPDX-License-Identifier: GPL-3.0-or-later */
'use strict';
'require view';
'require fs';
'require uci';
'require dom';
'require poll';

var LOGCTL = '/usr/libexec/clashwrt/logctl.sh';
var CONFCTL = '/usr/libexec/clashwrt/confctl.sh';

var MAX_LINES = 1000;

/* mihomo's controller sends Access-Control-Allow-Origin: *, so the browser can
 * read its log stream directly. That beats proxying it through a helper: the
 * stream never ends, and an exec-based reader would either block forever or
 * lose whatever arrives between polls. */
function apiBase(port) {
	return 'http://' + window.location.hostname + ':' + port;
}

function fmtTime(d) {
	function p(n) { return (n < 10 ? '0' : '') + n; }
	return p(d.getHours()) + ':' + p(d.getMinutes()) + ':' + p(d.getSeconds());
}

return view.extend({
	load: function () {
		return Promise.all([
			uci.load('clashwrt'),
			/* the API may be protected; the secret lives in mihomo's config */
			fs.exec(CONFCTL, ['read']).catch(function () { return { stdout: '' }; })
		]);
	},

	render: function (data) {
		var conf = (data[1] && data[1].stdout) || '';
		var apiPort = uci.get('clashwrt', 'config', 'api_port') || '9090';

		var secret = '';
		var m = conf.match(/^secret:\s*(.*)$/m);
		if (m) secret = m[1].trim().replace(/^['"]|['"]$/g, '');

		var lines = [];
		var paused = false;
		var reader = null;
		var abort = null;
		var source = 'mihomo';

		var pre = E('pre', {
			'style': 'margin:0;padding:10px;height:60vh;overflow:auto;' +
				'font-family:monospace;font-size:12px;line-height:1.45;' +
				'white-space:pre-wrap;word-break:break-word;' +
				'background:var(--background-color-medium,rgba(127,127,127,0.08));border-radius:4px'
		}, '');

		var statusEl = E('span', { 'style': 'margin-left:8px;opacity:0.8' }, '');

		var filterBox = E('input', {
			'type': 'text', 'class': 'cbi-input-text', 'style': 'width:16em',
			'placeholder': _('filter, e.g. an IP or a domain')
		});

		var autoscroll = E('input', { 'type': 'checkbox', 'checked': '' });

		function matches(text) {
			var f = (filterBox.value || '').trim().toLowerCase();
			return !f || text.toLowerCase().indexOf(f) >= 0;
		}

		function repaint() {
			var shown = lines.filter(matches);
			dom.content(pre, shown.join('\n'));
			if (autoscroll.checked) pre.scrollTop = pre.scrollHeight;
			dom.content(statusEl, _('%d line(s)').format(shown.length));
		}

		function push(text) {
			lines.push(text);
			/* a log page must not grow without bound: this streams for as long
			 * as the tab is open */
			if (lines.length > MAX_LINES) lines.splice(0, lines.length - MAX_LINES);
			if (!paused) repaint();
		}

		/* ---- live stream from mihomo ---- */

		function stopStream() {
			if (abort) { try { abort.abort(); } catch (e) {} }
			abort = null;
			reader = null;
		}

		function startStream(level) {
			stopStream();
			var url = apiBase(apiPort) + '/logs?level=' + encodeURIComponent(level);
			var opts = {};
			if (window.AbortController) {
				abort = new AbortController();
				opts.signal = abort.signal;
			}
			if (secret) opts.headers = { 'Authorization': 'Bearer ' + secret };

			push('--- ' + _('connecting to %s').format(url) + ' ---');

			fetch(url, opts).then(function (res) {
				if (!res.ok) throw new Error('HTTP ' + res.status);
				if (!res.body || !res.body.getReader)
					throw new Error(_('this browser cannot read a streaming response'));

				reader = res.body.getReader();
				var dec = new TextDecoder();
				var buf = '';

				function pump() {
					return reader.read().then(function (r) {
						if (r.done) { push('--- ' + _('stream ended') + ' ---'); return; }
						buf += dec.decode(r.value, { stream: true });
						var parts = buf.split('\n');
						buf = parts.pop();
						parts.forEach(function (line) {
							line = line.trim();
							if (!line) return;
							var t = fmtTime(new Date());
							try {
								var o = JSON.parse(line);
								push('[' + t + '] ' + (o.type ? o.type.toUpperCase().padEnd(5) + ' ' : '') + (o.payload || line));
							} catch (e) {
								push('[' + t + '] ' + line);
							}
						});
						return pump();
					});
				}
				return pump();
			}).catch(function (e) {
				if (e && e.name === 'AbortError') return;
				push('--- ' + _('stream error: %s').format(String(e.message || e)) + ' ---');
				push(_('If mihomo is running, check that its API is reachable at %s.').format(apiBase(apiPort)));
			});
		}

		/* ---- system log ---- */

		var sysPoll = null;

		function stopSyslog() {
			if (sysPoll) { poll.remove(sysPoll); sysPoll = null; }
		}

		function loadSyslog() {
			return fs.exec(LOGCTL, [sysKind.value, '300']).then(function (res) {
				lines = (res.stdout || '').split('\n').filter(function (l) { return l.trim(); });
				if (!lines.length) lines = [_('nothing logged yet')];
				repaint();
			}).catch(function (e) {
				lines = [String((e && (e.stderr || e.message)) || e)];
				repaint();
			});
		}

		function startSyslog() {
			stopSyslog();
			/* Which file the entries actually come from is worth showing: on a
			 * router with rsyslog installed, `logread` is empty while the log
			 * is perfectly healthy in a file, and that difference is otherwise
			 * invisible and very confusing. */
			fs.exec(LOGCTL, ['where']).then(function (r) {
				dom.content(sourceNote, _('reading from %s').format((r.stdout || '').trim() || '?'));
			}).catch(function () { dom.content(sourceNote, ''); });

			loadSyslog();
			sysPoll = function () { if (!paused) return loadSyslog(); };
			poll.add(sysPoll, 5);
		}

		/* ---- controls ---- */

		var levelSel = E('select', { 'class': 'cbi-input-select' }, [
			E('option', { 'value': 'info', 'selected': '' }, 'info'),
			E('option', { 'value': 'warning' }, 'warning'),
			E('option', { 'value': 'error' }, 'error'),
			E('option', { 'value': 'debug' }, 'debug'),
			E('option', { 'value': 'silent' }, 'silent')
		]);

		var sysKind = E('select', { 'class': 'cbi-input-select' }, [
			E('option', { 'value': 'syslog', 'selected': '' }, _('proxy-related')),
			E('option', { 'value': 'all' }, _('everything')),
			E('option', { 'value': 'kernel' }, _('kernel'))
		]);

		var srcSel = E('select', { 'class': 'cbi-input-select' }, [
			E('option', { 'value': 'mihomo', 'selected': '' }, _('mihomo (live)')),
			E('option', { 'value': 'system' }, _('system log'))
		]);

		var mihomoCtl = E('span', {}, [ ' ', _('Level:'), ' ', levelSel ]);
		var sourceNote = E('span', { 'style': 'margin-left:8px;opacity:0.7;font-size:90%' }, '');
		var systemCtl = E('span', { 'style': 'display:none' }, [ ' ', _('Show:'), ' ', sysKind, sourceNote ]);

		function switchSource() {
			source = srcSel.value;
			lines = [];
			repaint();
			stopStream();
			stopSyslog();
			if (source === 'mihomo') {
				mihomoCtl.style.display = '';
				systemCtl.style.display = 'none';
				startStream(levelSel.value);
			} else {
				mihomoCtl.style.display = 'none';
				systemCtl.style.display = '';
				startSyslog();
			}
		}

		srcSel.addEventListener('change', switchSource);
		levelSel.addEventListener('change', function () {
			if (source === 'mihomo') { lines = []; repaint(); startStream(levelSel.value); }
		});
		sysKind.addEventListener('change', function () { if (source === 'system') loadSyslog(); });
		filterBox.addEventListener('input', repaint);

		var btnPause = E('button', {
			'class': 'cbi-button',
			'click': function (ev) {
				paused = !paused;
				dom.content(ev.target, paused ? _('Resume') : _('Pause'));
				if (!paused) repaint();
			}
		}, _('Pause'));

		var btnClear = E('button', {
			'class': 'cbi-button',
			'style': 'margin-left:6px',
			'click': function () { lines = []; repaint(); }
		}, _('Clear'));

		var btnCopy = E('button', {
			'class': 'cbi-button',
			'style': 'margin-left:6px',
			'click': function (ev) {
				var text = lines.filter(matches).join('\n');
				if (navigator.clipboard && navigator.clipboard.writeText) {
					navigator.clipboard.writeText(text).then(function () {
						dom.content(ev.target, _('Copied'));
						window.setTimeout(function () { dom.content(ev.target, _('Copy')); }, 1500);
					});
				} else {
					/* clipboard API needs a secure context, and a router is
					 * usually plain http -- fall back to a selectable dump */
					pre.focus();
					var r = document.createRange();
					r.selectNodeContents(pre);
					var s = window.getSelection();
					s.removeAllRanges();
					s.addRange(r);
				}
			}
		}, _('Copy'));

		/* stop the stream when leaving the page, or it keeps running */
		window.addEventListener('beforeunload', stopStream);
		document.addEventListener('visibilitychange', function () {
			if (document.hidden) return;
			if (source === 'mihomo' && !reader && !paused) startStream(levelSel.value);
		});

		switchSource();

		return E('div', { 'class': 'cbi-map' }, [
			E('h2', {}, _('Logs')),
			E('div', { 'class': 'cbi-map-descr' },
				_('The live view is mihomo\'s own log, read straight from its API — this is where you see which rule matched a connection and which node carried it. The system log shows everything around it: the firewall engine, hotplug and the daemon being restarted.')),

			E('div', { 'class': 'cbi-section' }, [
				E('div', { 'style': 'margin-bottom:8px' }, [
					_('Source:'), ' ', srcSel,
					mihomoCtl, systemCtl,
					' ', _('Filter:'), ' ', filterBox,
					statusEl
				]),
				E('div', { 'style': 'margin-bottom:8px' }, [
					btnPause, btnClear, btnCopy,
					E('label', { 'style': 'margin-left:12px' }, [ autoscroll, ' ', _('Auto-scroll') ])
				]),
				pre
			])
		]);
	},

	handleSave: null,
	handleSaveApply: null,
	handleReset: null
});
