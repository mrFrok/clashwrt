/* SPDX-License-Identifier: GPL-3.0-or-later */
'use strict';
'require view';
'require fs';
'require ui';
'require uci';
'require dom';
'require clashwrt.gen as gen';

var STAGING = '/tmp/clashwrt-staging';
var CONFCTL = '/usr/libexec/clashwrt/confctl.sh';

function say(node, ok, text) {
	dom.content(node, E('div', {
		'class': ok ? 'alert-message success' : 'alert-message warning',
		'style': 'white-space:pre-wrap;margin:8px 0 0 0'
	}, text));
}

function label(t, hint) {
	return E('div', { 'style': 'margin:14px 0 4px 0' }, [
		E('strong', {}, t),
		hint ? E('div', { 'style': 'font-size:90%;opacity:0.75' }, hint) : ''
	]);
}

return view.extend({
	load: function () {
		return uci.load('clashwrt');
	},

	/* Answers live in UCI so that "flip the split" is a regeneration with one
	 * value changed, rather than an edit to a file the user may have touched. */
	readAnswers: function () {
		var g = function (k, d) {
			var v = uci.get('clashwrt', 'wizard', k);
			return (v === undefined || v === null || v === '') ? d : v;
		};
		var gl = function (k) {
			var v = uci.get('clashwrt', 'wizard', k);
			if (!v) return [];
			return Array.isArray(v) ? v : [v];
		};
		return {
			subs: gl('subscription').join('\n'),
			links: gl('link').join('\n'),
			dnsPreset: g('dns_preset', 'quad9'),
			dnsCustom: gl('dns_server').join('\n'),
			routing: g('routing', 'direct_except_list'),
			ruleSets: gl('ruleset'),
			udpSplit: g('udp_split', '0') === '1',
			udpFilter: g('udp_filter', '(?i)(hysteria|hy2|tuic)'),
			tcpFilter: g('tcp_filter', '')
		};
	},

	render: function () {
		var self = this;
		var a = this.readAnswers();
		var out = E('div');
		var preview = E('textarea', {
			'style': 'width:100%;min-height:40vh;font-family:monospace;font-size:12px;white-space:pre;overflow-x:auto',
			'spellcheck': 'false'
		}, '');

		/* ---- inputs ---- */
		var subsBox = E('textarea', {
			'style': 'width:100%;min-height:5em;font-family:monospace;font-size:12px',
			'placeholder': 'https://example.com/sub/token'
		}, a.subs);

		var linksBox = E('textarea', {
			'style': 'width:100%;min-height:5em;font-family:monospace;font-size:12px',
			'placeholder': 'vless://…\nhysteria2://…'
		}, a.links);

		var dnsSel = E('select', { 'class': 'cbi-input-select' },
			Object.keys(gen.DNS_PRESETS).map(function (k) {
				return E('option', { 'value': k, 'selected': k === a.dnsPreset ? '' : null },
					gen.DNS_PRESETS[k].title);
			}));

		var dnsCustom = E('textarea', {
			'style': 'width:100%;min-height:3em;font-family:monospace;font-size:12px',
			'placeholder': '127.0.0.1:5335'
		}, a.dnsCustom);

		var routeSel = E('select', { 'class': 'cbi-input-select' }, [
			E('option', { 'value': 'direct_except_list', 'selected': a.routing === 'direct_except_list' ? '' : null },
				_('Everything direct, except the selected lists')),
			E('option', { 'value': 'proxy_except_ru', 'selected': a.routing === 'proxy_except_ru' ? '' : null },
				_('Everything through the proxy, except Russia'))
		]);

		var setBoxes = {};
		var setList = E('div', {}, Object.keys(gen.RULESETS).map(function (k) {
			var cb = E('input', {
				'type': 'checkbox',
				'checked': a.ruleSets.indexOf(k) >= 0 ? '' : null
			});
			setBoxes[k] = cb;
			return E('label', { 'style': 'display:block;margin:3px 0' }, [
				cb, ' ', E('span', {}, gen.RULESETS[k].title),
				gen.RULESETS[k].descr
					? E('span', { 'style': 'opacity:0.7' }, ' — ' + gen.RULESETS[k].descr) : ''
			]);
		}));

		var splitCb = E('input', { 'type': 'checkbox', 'checked': a.udpSplit ? '' : null });
		var udpFilter = E('input', {
			'type': 'text', 'class': 'cbi-input-text', 'style': 'width:24em',
			'value': a.udpFilter
		});
		var tcpFilter = E('input', {
			'type': 'text', 'class': 'cbi-input-text', 'style': 'width:24em',
			'value': a.tcpFilter, 'placeholder': _('empty = all nodes')
		});

		var detected = E('div', { 'style': 'font-size:90%;margin-top:4px' });

		function updateDetected() {
			var parsed = gen.parseLinks(linksBox.value);
			var f = gen.families(parsed.proxies);
			var msg;
			if (!parsed.proxies.length && !gen.subscriptionsOf(subsBox.value).length) {
				msg = _('No nodes yet.');
			} else if (parsed.proxies.length) {
				msg = _('Parsed %d node(s): %d UDP-native (%s), %d TCP-based.')
					.format(parsed.proxies.length, f.udp.length, f.udp.join(', ') || '—', f.tcp.length);
				if (!f.udp.length)
					msg += ' ' + _('Splitting will have nothing to send UDP through.');
			} else {
				msg = _('Subscription only — node protocols are unknown until it is fetched, so the split relies on the name filters below.');
			}
			if (parsed.failed)
				msg += ' ' + _('%d line(s) could not be parsed.').format(parsed.failed);
			dom.content(detected, msg);
		}

		linksBox.addEventListener('input', updateDetected);
		subsBox.addEventListener('input', updateDetected);

		function collect() {
			var sets = Object.keys(setBoxes).filter(function (k) { return setBoxes[k].checked; });
			return {
				subs: subsBox.value,
				links: linksBox.value,
				dnsPreset: dnsSel.value,
				dnsCustom: dnsCustom.value,
				routing: routeSel.value,
				ruleSets: sets,
				udpSplit: splitCb.checked,
				udpFilter: udpFilter.value,
				tcpFilter: tcpFilter.value
			};
		}

		function buildOptions(ans) {
			var uciGet = function (k, d) {
				var v = uci.get('clashwrt', 'config', k);
				return (v === undefined || v === null || v === '') ? d : v;
			};
			var custom = (ans.dnsCustom || '').split(/[\r\n,\s]+/).filter(function (s) { return s.trim(); });
			var servers = (ans.dnsPreset === 'custom' || custom.length)
				? custom
				: gen.DNS_PRESETS[ans.dnsPreset].servers;

			return {
				mode: uciGet('mode', 'redirect_tun'),
				tproxyPort: uciGet('tproxy_port', 7894),
				redirPort: uciGet('redir_port', 7893),
				tunDevice: uciGet('tun_device', 'clash-tun'),
				dnsPort: uciGet('dns_port', 1053),
				apiPort: uciGet('api_port', 9090),
				selfMark: uciGet('self_mark', 2),
				externalUi: uciGet('mihomo_dir', '/etc/mihomo') + '/ui',
				subscriptions: gen.subscriptionsOf(ans.subs),
				proxies: gen.parseLinks(ans.links).proxies,
				dnsPreset: ans.dnsPreset,
				dnsServers: servers,
				routing: ans.routing,
				ruleSets: ans.ruleSets,
				udpSplit: ans.udpSplit,
				udpFilter: ans.udpFilter,
				tcpFilter: ans.tcpFilter
			};
		}

		function saveAnswers(ans) {
			if (!uci.get('clashwrt', 'wizard'))
				uci.add('clashwrt', 'wizard', 'wizard');
			var setList = function (k, arr) {
				uci.unset('clashwrt', 'wizard', k);
				if (arr.length) uci.set('clashwrt', 'wizard', k, arr);
			};
			setList('subscription', gen.subscriptionsOf(ans.subs));
			setList('link', (ans.links || '').split(/[\r\n]+/)
				.map(function (s) { return s.trim(); })
				.filter(function (s) { return s.indexOf('://') > 0; }));
			setList('dns_server', (ans.dnsCustom || '').split(/[\r\n,\s]+/).filter(function (s) { return s.trim(); }));
			setList('ruleset', ans.ruleSets);
			uci.set('clashwrt', 'wizard', 'dns_preset', ans.dnsPreset);
			uci.set('clashwrt', 'wizard', 'routing', ans.routing);
			uci.set('clashwrt', 'wizard', 'udp_split', ans.udpSplit ? '1' : '0');
			uci.set('clashwrt', 'wizard', 'udp_filter', ans.udpFilter);
			uci.set('clashwrt', 'wizard', 'tcp_filter', ans.tcpFilter);
			return uci.save().then(function () { return uci.apply(); });
		}

		var btnPreview = E('button', {
			'class': 'cbi-button cbi-button-action',
			'click': function () {
				var ans = collect();
				if (!gen.subscriptionsOf(ans.subs).length && !gen.parseLinks(ans.links).proxies.length) {
					say(out, false, _('Add a subscription URL or at least one working node link first.'));
					return;
				}
				preview.value = gen.generate(buildOptions(ans));
				say(out, true, _('Generated. Review it below, then apply.'));
			}
		}, _('Generate'));

		var btnApply = E('button', {
			'class': 'cbi-button cbi-button-positive',
			'style': 'margin-left:6px',
			'click': function (ev) {
				var b = ev.target;
				var ans = collect();
				var text = preview.value || gen.generate(buildOptions(ans));
				ui.showModal(_('Replace configuration'), [
					E('p', {}, _('This replaces mihomo\'s config.yaml. The current one is backed up first, and nothing is installed unless mihomo accepts the new file.')),
					E('div', { 'class': 'right' }, [
						E('button', { 'class': 'cbi-button', 'click': ui.hideModal }, _('Cancel')),
						' ',
						E('button', {
							'class': 'cbi-button cbi-button-positive',
							'click': function () {
								ui.hideModal();
								b.disabled = true;
								dom.content(out, E('em', {}, _('Applying…')));
								saveAnswers(ans)
									.then(function () { return fs.write(STAGING, text); })
									.then(function () { return fs.exec(CONFCTL, ['apply']); })
									.then(function (res) { say(out, true, (res.stdout || '') + (res.stderr || '')); })
									.catch(function (e) { say(out, false, (e.stdout || '') + (e.stderr || '') || String(e)); })
									.finally(function () { b.disabled = false; });
							}
						}, _('Replace and apply'))
					])
				]);
			}
		}, _('Apply configuration'));

		updateDetected();

		return E('div', { 'class': 'cbi-map' }, [
			E('h2', {}, _('Setup wizard')),
			E('div', { 'class': 'cbi-map-descr' },
				_('Builds a working config.yaml from a subscription or node links. Inbound settings are generated to match the interception mode currently selected on the Settings page, so the firewall and mihomo always agree.')),

			E('div', { 'class': 'cbi-section' }, [
				label(_('Subscription URLs'), _('One per line. Each becomes a proxy-provider.')),
				subsBox,

				label(_('Node links'), _('vless://, vmess://, trojan://, ss://, hysteria2://, tuic:// — one per line.')),
				linksBox,
				detected,

				label(_('DNS')),
				dnsSel,
				E('div', { 'style': 'margin-top:6px' }, [
					E('div', { 'style': 'font-size:90%;opacity:0.75' },
						_('Custom servers, one per line. If filled, these win over the preset.')),
					dnsCustom
				]),

				label(_('Routing strategy')),
				routeSel,

				label(_('Lists'), _('Used by the "everything direct, except…" strategy.')),
				setList,

				label(_('Split TCP and UDP across protocols'),
					_('Sends UDP to QUIC-based nodes (Hysteria2, TUIC) and leaves everything else on the TCP-based ones. Worth doing when a subscription carries both: the QUIC protocols handle datagrams natively instead of tunnelling them.')),
				E('label', {}, [ splitCb, ' ', _('Enable protocol split') ]),
				E('div', { 'style': 'margin-top:6px' }, [
					E('div', {}, _('UDP node filter (regex, Go RE2 — no lookahead):')),
					udpFilter
				]),
				E('div', { 'style': 'margin-top:6px' }, [
					E('div', {}, _('TCP node filter:')),
					tcpFilter
				]),

				E('div', { 'style': 'margin-top:14px' }, [ btnPreview, btnApply ]),
				out
			]),

			E('div', { 'class': 'cbi-section' }, [
				E('h3', {}, _('Preview')),
				preview
			])
		]);
	},

	handleSave: null,
	handleSaveApply: null,
	handleReset: null
});
