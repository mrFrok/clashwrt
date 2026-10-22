/* SPDX-License-Identifier: GPL-3.0-or-later */
'use strict';
'require view';
'require fs';
'require ui';
'require uci';
'require dom';
'require clashwrt.generator as gen';
'require clashwrt.power as power';

var UI_VERSION = '0.5.0';

var STAGING = '/tmp/clashwrt-staging';
var CONFCTL = '/usr/libexec/clashwrt/confctl.sh';
var FW = '/usr/libexec/clashwrt/fw.sh';
var STEPS = 3;

var DEFAULT_UDP_FILTER = '(?i)(hysteria|hy2|tuic)';
var SITE_CHIP_CAP = 50;

function say(node, ok, text) {
	dom.content(node, E('div', {
		'class': ok ? 'alert-message success' : 'alert-message warning',
		'style': 'white-space:pre-wrap;margin:8px 0 0 0'
	}, [ text ]));
}

function label(t, hint) {
	return E('div', { 'style': 'margin:14px 0 4px 0' }, [
		E('strong', {}, t),
		hint ? E('div', { 'style': 'font-size:90%;opacity:0.75' }, hint) : ''
	]);
}

/* One page of the wizard. Only one is shown at a time, with "Step N of 3"
 * above it, so the page asks one question at a time. */
function step(num, title, intro, kids) {
	return E('div', {
		'class': 'cbi-section',
		'data-step': String(num),
		'style': num === 1 ? '' : 'display:none'
	}, [
		E('div', { 'style': 'opacity:0.7;font-size:90%' }, _('Step %d of %d').format(num, STEPS)),
		E('h3', { 'style': 'margin:2px 0 4px 0' }, title),
		E('div', { 'style': 'opacity:0.75;margin:0 0 6px 0' }, intro)
	].concat(kids));
}

function more(title, text) {
	return E('details', { 'style': 'font-size:90%;opacity:0.8;margin:2px 0 6px 0' }, [
		E('summary', {}, title),
		text
	]);
}

return view.extend({
	load: function () {
		return Promise.all([
			uci.load('clashwrt'),
			fs.exec(CONFCTL, ['read']).catch(function () { return null; })
		]);
	},

	/* Answers live in UCI so that "flip the split" is a regeneration with one
	 * value changed, rather than an edit to a file the user may have touched.
	 * With no saved answers (a config written by hand, or by an older
	 * version) the installed config.yaml is read instead, so the form starts
	 * from what is actually running rather than from blank. */
	readAnswers: function (cfg, hasCfg) {
		var g = function (k, d) {
			var v = uci.get('clashwrt', 'wizard', k);
			return (v === undefined || v === null || v === '') ? d : v;
		};
		var gl = function (k) {
			var v = uci.get('clashwrt', 'wizard', k);
			if (!v) return [];
			return Array.isArray(v) ? v : [v];
		};

		if (uci.get('clashwrt', 'wizard')) {
			var extra = gl('extra_domain');
			return {
				source: 'uci',
				subs: gl('subscription').join('\n'),
				links: gl('link').join('\n'),
				dnsPreset: g('dns_preset', gen.DEFAULT_DNS),
				fakeIp: g('fake_ip', '0') === '1',
				tunStack: g('tun_stack', 'system'),
				dnsCustom: gl('dns_server').join('\n'),
				routing: g('routing', 'direct_except_list'),
				ruleSets: gl('ruleset'),
				udpSplit: g('udp_split', '0') === '1',
				autoBest: g('auto_best', '1') === '1',
				yandexDns: g('yandex_dns', '0') === '1',
				udpFilter: g('udp_filter', DEFAULT_UDP_FILTER),
				tcpFilter: g('tcp_filter', ''),
				extraDomains: extra.length ? extra : cfg.extraDomains,
				extraGroup: extra.length ? g('extra_group', 'Proxy') : cfg.extraGroup
			};
		}

		if (hasCfg)
			return this.answersFromConfig(cfg);

		return {
			source: 'none',
			subs: '', links: '', dnsPreset: gen.DEFAULT_DNS, dnsCustom: '', fakeIp: false, tunStack: 'system',
			routing: 'direct_except_list', ruleSets: [], udpSplit: false, autoBest: true,
			yandexDns: false, udpFilter: DEFAULT_UDP_FILTER, tcpFilter: '',
			extraDomains: [], extraGroup: 'Proxy'
		};
	},

	answersFromConfig: function (cfg) {
		var preset = null;
		Object.keys(gen.DNS_PRESETS).forEach(function (k) {
			var sv = gen.DNS_PRESETS[k].servers;
			if (k !== 'custom' && sv.length && sv.join('\n') === cfg.dnsServers.join('\n'))
				preset = k;
		});
		return {
			source: 'config',
			subs: cfg.subs.join('\n'),
			links: '',
			dnsPreset: preset || (cfg.dnsServers.length ? 'custom' : gen.DEFAULT_DNS),
			fakeIp: cfg.fakeIp,
			tunStack: cfg.tunStack || 'system',
			dnsCustom: preset ? '' : cfg.dnsServers.join('\n'),
			routing: cfg.routing || 'direct_except_list',
			ruleSets: cfg.ruleSets,
			udpSplit: cfg.udpSplit,
			/* a config written elsewhere has no Auto group; offer it anyway */
			autoBest: cfg.generatedByUs ? cfg.autoBest : true,
			yandexDns: cfg.yandexDns,
			udpFilter: cfg.udpFilter || DEFAULT_UDP_FILTER,
			tcpFilter: cfg.tcpFilter,
			extraDomains: cfg.extraDomains,
			extraGroup: cfg.extraGroup
		};
	},

	render: function (data) {
		var self = this;
		var cfgRes = data && data[1];
		var cfgText = (cfgRes && cfgRes.code === 0) ? (cfgRes.stdout || '') : '';
		var cfg = gen.parseConfig(cfgText);
		var secret = gen.newSecret();
		var hasCfg = cfgText.trim().length > 0;
		var a = this.readAnswers(cfg, hasCfg);
		var previewKind = '';
		var out = E('div');
		var preview = E('textarea', {
			'style': 'width:100%;min-height:40vh;font-family:monospace;font-size:12px;white-space:pre;overflow-x:auto',
			'spellcheck': 'false',
			'placeholder': _('Nothing to preview yet: add a subscription URL or a node link, and pick Proxy or DIRECT for added sites.')
		}, '');

		/* ---- inputs ---- */
		var subsBox = E('textarea', {
			'style': 'width:100%;min-height:5em;font-family:monospace;font-size:12px',
			'placeholder': 'https://example.com/sub/token'
		}, '');

		var linksBox = E('textarea', {
			'style': 'width:100%;min-height:5em;font-family:monospace;font-size:12px',
			'placeholder': 'vless://…\nhysteria2://…'
		}, '');

		var dnsSel = E('select', { 'class': 'cbi-input-select' },
			Object.keys(gen.DNS_PRESETS).map(function (k) {
				return E('option', { 'value': k }, gen.DNS_PRESETS[k].title);
			}));

		var dnsCustom = E('textarea', {
			'style': 'width:100%;min-height:3em;font-family:monospace;font-size:12px',
			'placeholder': '127.0.0.1:5335'
		}, '');

		var routeSel = E('select', { 'class': 'cbi-input-select' }, [
			E('option', { 'value': 'direct_except_list' },
				_('Everything direct, except the selected lists')),
			E('option', { 'value': 'proxy_except_ru' },
				_('Everything through the proxy, except Russia'))
		]);

		var setBoxes = {};
		var setList = E('div', {}, Object.keys(gen.RULESETS).map(function (k) {
			var cb = E('input', { 'type': 'checkbox' });
			setBoxes[k] = cb;
			return E('label', { 'style': 'display:block;margin:3px 0' }, [
				cb, ' ', E('span', {}, gen.RULESETS[k].title),
				gen.RULESETS[k].descr
					? E('span', { 'style': 'opacity:0.7' }, ' — ' + gen.RULESETS[k].descr) : ''
			]);
		}));

		var splitCb = E('input', { 'type': 'checkbox' });
		var autoCb = E('input', { 'type': 'checkbox' });
		var fakeCb = E('input', { 'type': 'checkbox' });
		var stackSel = E('select', { 'class': 'cbi-input-select' }, gen.TUN_STACKS.map(function (k) {
			return E('option', { 'value': k }, [ {
				system: _('system — the kernel\'s own, fastest (default)'),
				gvisor: _('gvisor — userspace, for kernels where system misbehaves'),
				mixed: _('mixed — system for TCP, gvisor for UDP'),
				mips: _('mips — userspace, built for slow MIPS routers')
			}[k] ]);
		}));
		var yandexCb = E('input', { 'type': 'checkbox' });
		var udpFilter = E('input', {
			'type': 'text', 'class': 'cbi-input-text', 'style': 'width:24em'
		});
		var tcpFilter = E('input', {
			'type': 'text', 'class': 'cbi-input-text', 'style': 'width:24em',
			'placeholder': _('empty = all nodes')
		});

		/* The one box people paste into; subsBox and linksBox above are not
		 * shown, they hold its two halves for the code that reads them. */
		var nodesBox = E('textarea', {
			'style': 'width:100%;min-height:7em;font-family:monospace;font-size:12px',
			'placeholder': 'https://example.com/sub/token\nvless://…',
			'aria-describedby': 'cw-nodes-err'
		}, '');
		var nodesErr = E('div', { 'id': 'cw-nodes-err', 'role': 'alert', 'style': 'color:#c00;font-size:90%;min-height:1.2em' });
		var ignored = 0;
		function splitNodes() {
			var r = gen.splitNodeLines(nodesBox.value);
			subsBox.value = r.subs.join('\n');
			linksBox.value = r.links.join('\n');
			ignored = r.other;
			dom.content(nodesErr, '');
		}

		var detected = E('div', { 'style': 'font-size:90%;margin-top:4px' });
		var banner = E('div');

		/* ---- sites ---- */
		var sites = [];
		var showAllSites = false;
		var siteInput = E('input', {
			'type': 'text', 'class': 'cbi-input-text', 'style': 'width:24em',
			'placeholder': _('https://example.com or a service name, e.g. youtube')
		});
		var groupSel = E('select', { 'class': 'cbi-input-select', 'style': 'margin-left:6px' });
		var siteMsg = E('div', { 'style': 'font-size:90%;margin-top:4px;min-height:1.2em' });
		var chipBox = E('div', { 'style': 'margin:8px 0' });

		function fillGroups(selected) {
			var names = ['Proxy', 'DIRECT'];
			cfg.groups.forEach(function (n) {
				if (n !== gen.UDP_GROUP && n !== gen.AUTO_UDP_GROUP && names.indexOf(n) < 0) names.push(n);
			});
			if (selected && names.indexOf(selected) < 0) names.push(selected);
			dom.content(groupSel, names.map(function (n) {
				return E('option', { 'value': n, 'selected': n === (selected || 'Proxy') ? '' : null }, [ n ]);
			}));
		}

		function renderChips() {
			if (!sites.length) {
				dom.content(chipBox, E('em', { 'style': 'opacity:0.6' }, _('No sites added.')));
				return;
			}
			var capped = !showAllSites && sites.length > SITE_CHIP_CAP;
			var shown = capped ? sites.slice(0, SITE_CHIP_CAP) : sites;
			var nodes = shown.map(function (d) {
				return E('span', {
					'style': 'display:inline-block;margin:2px 6px 2px 0;padding:2px 4px 2px 8px;' +
						'border:1px solid rgba(127,127,127,0.5);border-radius:12px;font-family:monospace'
				}, [
					d,
					E('button', {
						'type': 'button',
						'title': _('Remove'),
						'style': 'margin-left:4px;border:0;background:none;cursor:pointer;color:inherit;font-size:120%;padding:0 4px',
						'click': function () {
							sites = sites.filter(function (x) { return x !== d; });
							renderChips();
							refreshPreview();
						}
					}, '×')
				]);
			});
			if (sites.length > SITE_CHIP_CAP)
				nodes.push(E('button', {
					'type': 'button',
					'class': 'cbi-button',
					'click': function () {
						showAllSites = !showAllSites;
						renderChips();
					}
				}, capped
					? _('Show all %d sites').format(sites.length)
					: _('Show only the first %d').format(SITE_CHIP_CAP)));
			dom.content(chipBox, nodes);
		}

		function previewSite() {
			var v = siteInput.value.trim();
			if (!v) { dom.content(siteMsg, ''); return null; }
			var d = gen.siteDomains(v);
			if (!d.length) {
				dom.content(siteMsg, [ _('Not recognised as a site — enter a URL, a hostname, or a service name.') ]);
				return null;
			}
			dom.content(siteMsg, [ _('Will add %d domain(s): %s').format(d.length, d.join(', ')) ]);
			return d;
		}

		function addSite() {
			var d = previewSite();
			if (!d) return;
			sites = gen.normDomains(sites.concat(d));
			siteInput.value = '';
			renderChips();
			refreshPreview();
			dom.content(siteMsg, [ _('Added %d domain(s): %s').format(d.length, d.join(', ')) ]);
		}

		siteInput.addEventListener('input', previewSite);
		siteInput.addEventListener('keydown', function (ev) {
			if (ev.key === 'Enter') { ev.preventDefault(); addSite(); }
		});

		function applyAnswers(ans) {
			subsBox.value = ans.subs;
			linksBox.value = ans.links;
			nodesBox.value = [ ans.subs, ans.links ].filter(function (x) { return x && x.trim(); }).join('\n');
			ignored = 0;
			dnsSel.value = ans.dnsPreset;
			dnsCustom.value = ans.dnsCustom;
			routeSel.value = ans.routing;
			Object.keys(setBoxes).forEach(function (k) {
				setBoxes[k].checked = ans.ruleSets.indexOf(k) >= 0;
			});
			splitCb.checked = ans.udpSplit;
			autoCb.checked = ans.autoBest;
			fakeCb.checked = ans.fakeIp;
			stackSel.value = ans.tunStack;
			yandexCb.checked = ans.yandexDns;
			udpFilter.value = ans.udpFilter;
			tcpFilter.value = ans.tcpFilter;
			sites = gen.normDomains(ans.extraDomains);
			fillGroups(ans.extraGroup);
			renderChips();
			updateDetected();
			refreshPreview();
		}

		function showBanner(src) {
			var rows = [];
			if (src === 'uci')
				rows.push(E('div', { 'class': 'alert-message info' },
					_('Filled in from your last saved answers.')));
			else if (src === 'config')
				rows.push(E('div', { 'class': 'alert-message info' },
					_('Filled in from the installed config.yaml.')));
			if (hasCfg && !cfg.generatedByUs)
				rows.push(E('div', { 'class': 'alert-message warning' },
					_('The wizard did not write this config.yaml. Applying replaces it whole (a backup is kept); to keep it, use "Add to current config only" under "For experienced users".')));
			dom.content(banner, rows);
		}

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
			if (ignored)
				msg += ' ' + _('%d line(s) are neither a link nor a subscription and were ignored.').format(ignored);
			var rows = [ msg ];
			if (cfg.links > parsed.proxies.length)
				rows.push(E('div', { 'class': 'alert-message warning', 'style': 'margin-top:6px' },
					_('The installed config.yaml has %d inline node(s) that the wizard cannot recover from it. Generating without pasting their links again drops them.')
						.format(cfg.links)));
			dom.content(detected, rows);
		}

		nodesBox.addEventListener('input', function () { splitNodes(); updateDetected(); });

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
				autoBest: autoCb.checked,
				fakeIp: fakeCb.checked,
				tunStack: stackSel.value,
				yandexDns: yandexCb.checked,
				udpFilter: udpFilter.value,
				tcpFilter: tcpFilter.value,
				extraDomains: sites.slice(),
				extraGroup: groupSel.value || 'Proxy'
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
				fetchPort: uciGet('fetch_port', 7899),
				selfMark: uciGet('self_mark', 2),
				externalUi: uciGet('mihomo_dir', '/etc/mihomo') + '/ui',
				subscriptions: gen.subscriptionsOf(ans.subs),
				proxies: gen.parseLinks(ans.links).proxies,
				dnsPreset: ans.dnsPreset,
				dnsServers: servers,
				routing: ans.routing,
				ruleSets: ans.ruleSets,
				udpSplit: ans.udpSplit,
				autoBest: ans.autoBest,
				fakeIp: ans.fakeIp,
				tunStack: ans.tunStack,
				yandexDns: ans.yandexDns,
				udpFilter: ans.udpFilter,
				tcpFilter: ans.tcpFilter,
				extraDomains: gen.normDomains(ans.extraDomains),
				extraGroup: ans.extraGroup,
				/* keep the installed one, so a dashboard already logged in
				 * stays logged in; otherwise make one */
				secret: cfg.secret || secret
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
			setList('extra_domain', gen.normDomains(ans.extraDomains));
			uci.set('clashwrt', 'wizard', 'extra_group', ans.extraGroup);
			uci.set('clashwrt', 'wizard', 'dns_preset', ans.dnsPreset);
			uci.set('clashwrt', 'wizard', 'routing', ans.routing);
			uci.set('clashwrt', 'wizard', 'udp_split', ans.udpSplit ? '1' : '0');
			uci.set('clashwrt', 'wizard', 'auto_best', ans.autoBest ? '1' : '0');
			uci.set('clashwrt', 'wizard', 'fake_ip', ans.fakeIp ? '1' : '0');
			uci.set('clashwrt', 'wizard', 'tun_stack', ans.tunStack);
			uci.set('clashwrt', 'wizard', 'yandex_dns', ans.yandexDns ? '1' : '0');
			uci.set('clashwrt', 'wizard', 'udp_filter', ans.udpFilter);
			uci.set('clashwrt', 'wizard', 'tcp_filter', ans.tcpFilter);
			return uci.save().then(function () { return uci.apply(); });
		}

		/* A generated config only contains Proxy (and ProxyUDP); any other
		 * group exists only in a config somebody wrote. */
		function groupOk(ans) {
			if (!ans.extraDomains.length || ans.extraGroup === 'Proxy' || ans.extraGroup === 'DIRECT')
				return true;
			say(out, false, _('A generated configuration only has the Proxy group. Pick Proxy or DIRECT, or use "Add to current config only" to target "%s".')
				.format(ans.extraGroup));
			return false;
		}

		function hasNodes(ans) {
			return gen.subscriptionsOf(ans.subs).length > 0 || gen.parseLinks(ans.links).proxies.length > 0;
		}

		/* The preview is the generated config for whatever the form says right
		 * now, so it is rebuilt on load and after every change instead of only
		 * when Generate is pressed -- otherwise it sits empty under a form that
		 * was pre-filled and looks as if nothing happened. */
		function refreshPreview() {
			var ans = collect();
			var good = hasNodes(ans) && (!ans.extraDomains.length ||
				ans.extraGroup === 'Proxy' || ans.extraGroup === 'DIRECT');
			preview.value = good ? gen.generate(buildOptions(ans)) : '';
			previewKind = good ? 'generate' : '';
			return good;
		}

		var btnPreview = E('button', {
			'class': 'cbi-button cbi-button-action',
			'click': function () {
				var ans = collect();
				if (!groupOk(ans)) return;
				if (!hasNodes(ans)) {
					say(out, false, _('Add a subscription URL or at least one working node link first.'));
					return;
				}
				refreshPreview();
				say(out, true, _('Generated. Review it below, then apply.'));
			}
		}, _('Generate'));

		var btnApply = E('button', {
			'class': 'cbi-button cbi-button-positive',
			'style': 'margin-left:6px',
			'click': function (ev) {
				var b = ev.target;
				var ans = collect();
				if (previewKind === 'quick') {
					say(out, false, _('The preview holds the "add to current config" result. Press Generate first, or use "Add to current config only" to apply it.'));
					return;
				}
				if (!groupOk(ans)) return;
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
		}, _('Apply without switching on'));

		function refreshCfg() {
			return fs.exec(CONFCTL, ['read']).then(function (res) {
				cfgText = res.code === 0 ? (res.stdout || '') : '';
				cfg = gen.parseConfig(cfgText);
				hasCfg = cfgText.trim().length > 0;
				syncQuick();
			});
		}

		var btnQuick = E('button', {
			'class': 'cbi-button cbi-button-action',
			'style': 'margin-left:6px',
			'click': function (ev) {
				var b = ev.target;
				var ans = collect();
				if (!ans.extraDomains.length) {
					say(out, false, _('Add at least one site first.'));
					return;
				}
				b.disabled = true;
				fs.exec(CONFCTL, ['read'])
					.then(function (res) {
						if (res.code !== 0) throw new Error((res.stdout || '') + (res.stderr || ''));
						var next = gen.addSiteRules(res.stdout || '', ans.extraDomains, { group: ans.extraGroup });
						if (next === (res.stdout || '')) {
							say(out, true, _('Every one of these sites is already in the config for that group.'));
							return;
						}
						preview.value = next;
						previewKind = 'quick';
						say(out, true, _('Rules are inserted before the first catch-all rule; the rest of the file is untouched. Review the result below, then confirm.'));
						ui.showModal(_('Add sites to current configuration'), [
							E('p', {}, [ _('This adds %d site(s) to the rules of the installed config.yaml, sending them to "%s". The current file is backed up first, and nothing is installed unless mihomo accepts the result.')
								.format(ans.extraDomains.length, ans.extraGroup) ]),
							E('div', { 'style': 'font-family:monospace;word-break:break-all;max-height:10em;overflow:auto;margin-bottom:8px' },
								[ ans.extraDomains.join(', ') ]),
							E('div', { 'class': 'right' }, [
								E('button', { 'class': 'cbi-button', 'click': ui.hideModal }, _('Cancel')),
								' ',
								E('button', {
									'class': 'cbi-button cbi-button-positive',
									'click': function () {
										ui.hideModal();
										dom.content(out, E('em', {}, _('Applying…')));
										fs.write(STAGING, next)
											.then(function () { return fs.exec(CONFCTL, ['apply']); })
											.then(function (r) {
												say(out, r.code === 0, (r.stdout || '') + (r.stderr || ''));
												return refreshCfg();
											})
											.catch(function (e) { say(out, false, (e.stdout || '') + (e.stderr || '') || String(e.message || e)); });
									}
								}, _('Add and apply'))
							])
						]);
					})
					.catch(function (e) { say(out, false, String(e.message || e)); })
					.finally(function () { b.disabled = false; });
			}
		}, _('Add to current config only'));

		function syncQuick() {
			btnQuick.style.display = (hasCfg && !cfg.generatedByUs) ? '' : 'none';
		}

		var btnReload = E('button', {
			'class': 'cbi-button',
			'style': 'margin-left:6px',
			'click': function (ev) {
				var b = ev.target;
				b.disabled = true;
				refreshCfg()
					.then(function () {
						if (!hasCfg) {
							say(out, false, _('config.yaml could not be read.'));
							return;
						}
						applyAnswers(self.answersFromConfig(cfg));
						showBanner('config');
						say(out, true, _('Fields reloaded from the installed config.yaml.'));
					})
					.catch(function (e) { say(out, false, String(e.message || e)); })
					.finally(function () { b.disabled = false; });
			}
		}, _('Reload from config.yaml'));

		/* ---- one button: test, apply, switch on, check ---- */

		var placeholder = /Placeholder written by the clashwrt installer/.test(cfgText);
		var mainOut = E('div', { 'aria-live': 'polite' });
		var summaryBox = E('div', { 'class': 'cw-summary' });

		function dnsTitle(ans) {
			if (ans.dnsPreset === 'custom' || (ans.dnsCustom || '').trim()) return _('your own servers');
			return (gen.DNS_PRESETS[ans.dnsPreset] || {}).title || ans.dnsPreset;
		}

		function refreshSummary() {
			var ans = collect();
			var subs = gen.subscriptionsOf(ans.subs).length;
			var links = gen.parseLinks(ans.links).proxies.length;
			var lists = ans.ruleSets.map(function (k) { return (gen.RULESETS[k] || {}).title || k; });
			var row = function (k, v) {
				return E('div', { 'style': 'margin:2px 0' }, [ E('span', { 'style': 'opacity:.7' }, [ k + ': ' ]), E('strong', {}, [ v ]) ]);
			};
			dom.content(summaryBox, [
				row(_('Nodes'), _('%d subscription(s), %d node link(s)').format(subs, links)),
				row(_('Routing'), routeSel.options[routeSel.selectedIndex] ? routeSel.options[routeSel.selectedIndex].text : ans.routing),
				ans.routing === 'direct_except_list' ? row(_('Lists'), lists.length ? lists.join(', ') : _('none')) : '',
				ans.extraDomains.length ? row(_('Sites'), _('%d, to %s').format(ans.extraDomains.length, ans.extraGroup)) : '',
				row(_('DNS'), dnsTitle(ans))
			]);
		}

		/* A fresh router has never had its interception mode chosen: the
		 * default works everywhere, TPROXY is faster where the kernel honours
		 * it. Asked once, on the first run of the wizard only, so a mode
		 * someone picked by hand is never overridden. */
		function pickMode(log) {
			if (uci.get('clashwrt', 'wizard') || uci.get('clashwrt', 'config', 'mode_tested') === '1')
				return Promise.resolve();
			log(_('Testing how this router can intercept traffic…'));
			return fs.exec(FW, ['selftest']).catch(function () { return null; }).then(function (r) {
				var ok = r && r.code === 0 && /Recommended mode: tproxy/.test(r.stdout || '');
				if (ok) uci.set('clashwrt', 'config', 'mode', 'tproxy');
				uci.set('clashwrt', 'config', 'mode_tested', '1');
				log(ok ? _('TPROXY works here: using it.') : _('Using the mode that works on every router.'));
			});
		}

		function apiDelay() {
			var port = uci.get('clashwrt', 'config', 'api_port') || 9090;
			var key = cfg.secret || secret;
			return window.fetch('http://' + window.location.hostname + ':' + port +
				'/proxies/Proxy/delay?timeout=5000&url=' + encodeURIComponent('https://www.gstatic.com/generate_204'),
				{ headers: key ? { 'Authorization': 'Bearer ' + key } : {} })
				.then(function (r) { if (!r.ok) throw new Error(r.status); return r.json(); })
				.then(function (j) { if (!j || !j.delay) throw new Error('no delay'); return j.delay; });
		}

		/* Subscriptions are fetched after mihomo starts, so the first tries may
		 * find no node yet. */
		function checkVpn(tries) {
			return new Promise(function (res) { window.setTimeout(res, 5000); })
				.then(apiDelay)
				.catch(function (e) { if (tries > 1) return checkVpn(tries - 1); throw e; });
		}

		function applyAndStart(btn) {
			splitNodes();
			var ans = collect();
			if (!hasNodes(ans)) { go(1); dom.content(nodesErr, _('Paste a subscription URL or at least one node link.')); nodesBox.focus(); return; }
			if (!groupOk(ans)) return;

			var lines = E('ul', { 'style': 'margin:6px 0 0 1.2em' });
			function log(t) { lines.appendChild(E('li', {}, [ t ])); }
			function fail(t, raw) {
				dom.content(mainOut, [ lines, E('div', { 'class': 'alert-message warning', 'style': 'margin-top:8px' }, [
					E('strong', {}, [ t ]),
					raw ? E('details', { 'style': 'margin-top:4px' }, [ E('summary', {}, _('Details')),
						E('pre', { 'style': 'white-space:pre-wrap' }, [ raw ]) ]) : ''
				]) ]);
			}
			function power1(target) {
				return power.set(target, 'on').then(function (r) {
					if (!r.ok) throw { msg: _('Could not switch it on.'), raw: r.text };
				});
			}

			btn.disabled = true;
			dom.content(mainOut, lines);
			pickMode(log)
				.then(function () { log(_('Saving your answers…')); return saveAnswers(ans); })
				.then(function () {
					log(_('Writing and checking the configuration…'));
					return fs.write(STAGING, gen.generate(buildOptions(ans)))
						.then(function () { return fs.exec(CONFCTL, ['apply']); })
						.then(function (r) {
							if (r.code !== 0) throw { msg: _('mihomo did not accept the configuration; nothing was changed.'), raw: (r.stdout || '') + (r.stderr || '') };
						});
				})
				.then(function () { log(_('Starting the VPN…')); return power1('core'); })
				.then(function () { return power1('svc'); })
				.then(function () { return power1('proxy'); })
				.then(function () {
					log(_('Checking that the VPN answers…'));
					return checkVpn(4).then(function (ms) {
						dom.content(mainOut, [ lines, E('div', { 'class': 'alert-message success', 'style': 'margin-top:8px' }, [
							E('strong', {}, [ _('Done: the VPN works (%d ms).').format(ms) ]), ' ',
							_('Open a site from your lists to check. '),
							E('a', { 'href': L.url('admin/services/clashwrt/overview') }, _('Go to the Overview'))
						]) ]);
					}, function () {
						dom.content(mainOut, [ lines, E('div', { 'class': 'alert-message warning', 'style': 'margin-top:8px' }, [
							E('strong', {}, [ _('The proxy is on, but the VPN has not answered yet.') ]), ' ',
							_('A subscription can take a minute to download. If it stays this way, check the subscription link or the node; the Logs page says why. '),
							E('a', { 'href': L.url('admin/services/clashwrt/overview') }, _('Go to the Overview'))
						]) ]);
					});
				})
				.then(function () { hasCfg = true; cfg.generatedByUs = true; placeholder = false; showBanner('uci'); syncQuick(); })
				.catch(function (e) {
					fail((e && e.msg) || _('Something went wrong.'), (e && e.raw) || (e && e.message) || String(e));
				})
				.finally(function () { btn.disabled = false; });
		}

		var btnMain = E('button', {
			'class': 'cbi-button cbi-button-positive',
			'style': 'font-size:110%;padding:.5em 1.4em',
			'click': function (ev) {
				var b = ev.currentTarget;
				ev.preventDefault();
				/* replacing a hand-written config is the one thing to ask about */
				if (hasCfg && !cfg.generatedByUs && !placeholder) {
					ui.showModal(_('Replace configuration'), [
						E('p', {}, _('This replaces mihomo\'s config.yaml. The current one is backed up first, and nothing is installed unless mihomo accepts the new file.')),
						E('div', { 'class': 'right' }, [
							E('button', { 'class': 'cbi-button', 'click': ui.hideModal }, _('Cancel')), ' ',
							E('button', { 'class': 'cbi-button cbi-button-positive', 'click': function () { ui.hideModal(); applyAndStart(b); } },
								_('Replace and switch on'))
						])
					]);
					return;
				}
				applyAndStart(b);
			}
		}, _('Apply and switch on'));

		/* ---- moving between steps ---- */

		var cur = 1;
		var stepEls = [];
		var titles = [];
		function go(n) {
			if (n === 3) refreshSummary();
			cur = n;
			stepEls.forEach(function (el, i) { el.style.display = (i + 1 === n) ? '' : 'none'; });
			dom.content(progress, titles.map(function (t, i) {
				return E('span', { 'style': 'margin-right:14px;' + (i + 1 === n ? 'font-weight:bold' : 'opacity:.55'),
					'aria-current': i + 1 === n ? 'step' : null }, [ (i + 1) + '. ' + t ]);
			}));
			if (stepEls[n - 1]) stepEls[n - 1].scrollIntoView({ block: 'nearest' });
		}
		function nav(n) {
			return E('div', { 'style': 'margin-top:16px' }, [
				n > 1 ? E('button', { 'class': 'cbi-button', 'click': function (ev) { ev.preventDefault(); go(n - 1); } }, _('Back')) : '',
				n < STEPS ? E('button', { 'class': 'cbi-button cbi-button-action', 'style': 'margin-left:6px', 'click': function (ev) {
					ev.preventDefault();
					if (n === 1) {
						splitNodes();
						if (!hasNodes(collect())) {
							dom.content(nodesErr, _('Paste a subscription URL or at least one node link.'));
							nodesBox.focus();
							return;
						}
					}
					go(n + 1);
				} }, _('Next')) : ''
			]);
		}
		var progress = E('div', { 'class': 'cbi-section', 'style': 'padding:6px 10px' });

		applyAnswers(a);
		showBanner(a.source);
		syncQuick();

		var formSection;
		var onFormChange = function (ev) {
			if (ev.target !== siteInput) refreshPreview();
		};

		titles = [ _('Your VPN'), _('What goes through it'), _('Check and switch on') ];
		stepEls = [
			step(1, titles[0], _('Paste what your VPN provider gave you: a subscription link, or node links. One per line, in any order.'), [
				nodesBox,
				nodesErr,
				detected,
				nav(1)
			]),

			step(2, titles[1], _('Choose what goes through the VPN. The defaults suit most people.'), [
				label(_('Routing strategy')),
				routeSel,

				label(_('Lists'), _('Used by the "everything direct, except…" strategy.')),
				setList,

				label(_('Sites'), _('Send one website to a chosen group.')),
				more(_('How sites work'), _('Add a website by URL or by service name. Its domains are written into the config as plain rules and sent to the chosen group, ahead of the lists above.')),
				E('div', {}, [ siteInput, groupSel, ' ', E('button', {
					'type': 'button',
					'class': 'cbi-button cbi-button-add',
					'click': addSite
				}, _('Add')) ]),
				siteMsg,
				chipBox,
				nav(2)
			]),

			step(3, titles[2], _('Check your answers, then switch the VPN on. Nothing changes on the network before you press the button.'), [
				summaryBox,
				E('div', { 'style': 'margin-top:14px' }, [ btnMain ]),
				mainOut,

				E('details', { 'style': 'margin-top:18px' }, [
					E('summary', { 'style': 'cursor:pointer' }, _('More settings (DNS, fastest node, protocol split)')),

					label(_('DNS'), _('Which resolver answers when a name is looked up. The default suits most people.')),
					dnsSel,
					E('div', { 'style': 'margin-top:6px' }, [
						E('div', { 'style': 'font-size:90%;opacity:0.75' },
							_('Custom servers, one per line. If filled, these win over the preset.')),
						dnsCustom
					]),
					label(_('Fake-IP DNS'), _('Off by default.')),
					E('label', {}, [ fakeCb, ' ', _('Answer lookups with addresses from mihomo\'s own range') ]),
					more(_('What it changes'), _('Connections start without waiting for a real lookup, and proxied names are never resolved on the router. In exchange the kernel bypass set stops working (it is held back automatically), and while the proxy is switched off or bypassed by the watchdog, devices keep using the fake addresses they cached and cannot reach sites until that cache expires.')),
					label(_('Russian sites through Yandex DNS'), _('Off by default.')),
					E('label', {}, [ yandexCb, ' ', _('Use Yandex DNS for the Russian domain set') ]),
					more(_('Why use it?'), _('Resolves Russian domains with Yandex over DoH, and everything else with the resolver chosen above. A resolver abroad returns whichever CDN node is closest to itself, so RU sites end up pointed at distant edges — and those answers are the ones least in need of hiding.')),

					label(_('Fastest node'), _('On by default.')),
					E('label', {}, [ autoCb, ' ', _('Pick the fastest node automatically') ]),
					more(_('How it picks'), _('Adds an "Auto" group that times every node every five minutes and follows the fastest, and puts it first in Proxy, so a node can still be chosen by hand in the dashboard. With the protocol split, "Auto UDP" does the same for the QUIC nodes.')),
					label(_('Split TCP and UDP across protocols'), _('Off by default.')),
					E('label', {}, [ splitCb, ' ', _('Enable protocol split') ]),
					more(_('Why split?'), _('Sends UDP to QUIC-based nodes (Hysteria2, TUIC) and leaves everything else on the TCP-based ones. Worth doing when a subscription carries both: the QUIC protocols handle datagrams natively instead of tunnelling them.')),
					E('div', { 'style': 'margin-top:6px' }, [
						E('div', {}, _('UDP node filter (regex, Go RE2 — no lookahead):')),
						udpFilter
					]),
					E('div', { 'style': 'margin-top:6px' }, [
						E('div', {}, _('TCP node filter:')),
						tcpFilter
					]),
					label(_('TUN stack'), _('How the tun device hands packets to mihomo. Leave at system unless something does not work.')),
					stackSel
				]),

				E('details', { 'style': 'margin-top:10px' }, [
					E('summary', { 'style': 'cursor:pointer' }, _('For experienced users: preview, apply without switching on')),
					more(_('How it fits together'), _('Inbound settings follow the interception mode chosen on the Settings page, so the firewall and mihomo agree.')),
					E('div', { 'style': 'margin-top:8px' }, [ btnPreview, btnApply, btnQuick, btnReload ]),
					out,
					E('h4', {}, _('Preview')),
					preview
				]),
				nav(3)
			])
		];

		var page = E('div', { 'class': 'cbi-map' }, [
			E('h2', {}, [
				_('Setup wizard'),
				E('span', { 'style': 'font-size:55%;font-weight:normal;opacity:0.6;margin-left:8px' },
					'ui ' + UI_VERSION)
			]),
			E('div', { 'class': 'cbi-map-descr' },
				_('Three short steps: your VPN, what goes through it, switch on.')),
			banner,
			progress,
			formSection = E('div', {}, stepEls)
		]);
		go(1);

		formSection.addEventListener('input', onFormChange);
		formSection.addEventListener('change', onFormChange);

		return page;
	},

	handleSave: null,
	handleSaveApply: null,
	handleReset: null
});
