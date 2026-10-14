/* SPDX-License-Identifier: GPL-3.0-or-later */
'use strict';
'require view';
'require fs';
'require ui';
'require uci';
'require poll';
'require dom';
'require clashwrt.generator as gen';
'require clashwrt.power as power';

var UI_VERSION = '0.2.4';

var CONFCTL = '/usr/libexec/clashwrt/confctl.sh';
var UPDCTL = '/usr/libexec/clashwrt/updctl.sh';
var STAGING = '/tmp/clashwrt-staging';

var CSS =
	'.cw-row{display:flex;align-items:flex-start;gap:12px;padding:10px 0;border-bottom:1px solid rgba(128,128,128,.25)}' +
	'.cw-sw{position:relative;display:inline-block;width:42px;height:22px;flex:none;margin-top:2px}' +
	'.cw-sw input{opacity:0;width:0;height:0;position:absolute}' +
	'.cw-sw span{position:absolute;top:0;left:0;right:0;bottom:0;background:#bbb;border-radius:22px;cursor:pointer}' +
	'.cw-sw span:before{content:"";position:absolute;height:16px;width:16px;left:3px;top:3px;background:#fff;border-radius:50%;transition:left .15s}' +
	'.cw-sw input:checked+span{background:#34a853}' +
	'.cw-sw input:checked+span:before{left:23px}' +
	'.cw-sw input:disabled+span{opacity:.45;cursor:not-allowed}';

function settingsUrl() {
	return (typeof L !== 'undefined' && L.url)
		? L.url('admin', 'services', 'clashwrt', 'settings')
		: '#';
}

function say(node, ok, text) {
	dom.content(node, text ? E('div', {
		'class': ok ? 'alert-message success' : 'alert-message warning',
		'style': 'white-space:pre-wrap;margin:8px 0 0 0'
	}, [ text ]) : '');
}

return view.extend({
	load: function () {
		return Promise.all([
			uci.load('clashwrt'),
			power.status(),
			fs.exec(CONFCTL, ['read']).catch(function () { return { code: 1, stdout: '' }; })
		]);
	},

	render: function (data) {
		var cur = data[1] || {};
		var cfgText = (data[2] && data[2].code === 0) ? (data[2].stdout || '') : '';
		var busy = false;

		var pillBox = E('span', { 'id': 'cw-pill' });
		var msgBox = E('span', { 'id': 'cw-pill-msg', 'style': 'margin-left:10px' });
		var updBox = E('span', { 'id': 'cw-upd', 'style': 'margin-left:10px' });
		var out = E('div', { 'id': 'cw-out' });

		/* ---------------- the switches ---------------- */

		var switches = {};

		function makeSwitch(key, title, why) {
			var input = E('input', {
				'type': 'checkbox',
				'id': 'cw-sw-' + key,
				'change': function () { toggled(key, input.checked); }
			});
			var state = E('strong', { 'class': 'cw-state' });
			var note = E('div', { 'class': 'cw-note', 'style': 'font-size:90%;color:#b06000' });
			var row = E('div', { 'class': 'cw-row', 'data-switch': key }, [
				E('label', { 'class': 'cw-sw' }, [ input, E('span') ]),
				E('div', { 'style': 'flex:1' }, [
					E('div', {}, [ E('strong', {}, title), ' ', state ]),
					E('div', { 'class': 'cw-why', 'style': 'font-size:90%;opacity:.8' }, why),
					note
				])
			]);
			switches[key] = { input: input, state: state, note: note, node: row };
			return row;
		}

		var rows = [
			makeSwitch('proxy', _('Proxy'),
				_('Steers your network into the core. Off: it behaves as if ClashWrt were not installed. Starts off.')),
			makeSwitch('core', _('mihomo core'),
				_('The engine itself. Off: it also stays stopped after a reboot. Starts on.')),
			makeSwitch('all', _('Everything'),
				_('Both together, in the safe order. Use this when something is wrong.')),
			makeSwitch('svc', _('ClashWrt'),
				_('The whole service. Off: nothing is steered, the watchdog sleeps, and it stays off after a reboot. Starts on.'))
		];

		function setBusy(b) {
			busy = b;
			Object.keys(switches).forEach(function (k) { switches[k].input.disabled = b; });
			btnRestart.disabled = b || btnRestart.getAttribute('data-down') === '1';
		}

		function showResult(ok, text) {
			say(out, ok, text);
		}

		function act(target, on) {
			setBusy(true);
			dom.content(out, E('em', {}, on ? _('Switching on…') : _('Switching off…')));
			return power.set(target, on ? 'on' : 'off').then(function (res) {
				showResult(res.ok, res.text);
				return Object.keys(res.status).length ? res.status : power.status();
			}).then(function (s) {
				busy = false;
				paint(s);
			});
		}

		function confirmCoreOff() {
			ui.showModal(_('Turn off the core?'), [
				E('p', {}, _('The proxy is still on. With the core off, your network would lose its connection until the proxy is turned off too.')),
				E('div', { 'class': 'right' }, [
					E('button', {
						'class': 'cbi-button',
						'click': function () { ui.hideModal(); paint(cur); }
					}, _('Cancel')),
					' ',
					E('button', {
						'class': 'cbi-button cbi-button-positive',
						'click': function () { ui.hideModal(); act('all', false); }
					}, _('Turn off both (recommended)'))
				])
			]);
		}

		function toggled(key, want) {
			if (busy) return;
			if (key === 'core' && !want && cur['proxy'] === 'on' && power.serviceOn(cur)) {
				confirmCoreOff();
				return;
			}
			act(key, want);
		}

		/* ---------------- shortcuts ---------------- */

		var apiPort = uci.get('clashwrt', 'config', 'api_port') || '9090';
		var uiUrl = 'http://' + window.location.hostname + ':' + apiPort + '/ui/';

		var btnRestart = E('button', {
			'class': 'cbi-button cbi-button-reset',
			'click': function () {
				setBusy(true);
				dom.content(out, E('em', {}, _('Restarting mihomo…')));
				fs.exec('/etc/init.d/mihomo', ['restart']).then(function (res) {
					showResult(true, ((res.stdout || '') + (res.stderr || '')).trim() || _('mihomo restarted.'));
				}).catch(function (e) {
					showResult(false, power.describe(e));
				}).then(function () {
					return power.status();
				}).then(function (s) {
					busy = false;
					paint(s);
				});
			}
		}, _('Restart core'));

		var openLink = E('a', {
			'href': uiUrl,
			'target': '_blank',
			'rel': 'noopener',
			'class': 'cbi-button cbi-button-apply',
			'style': 'margin-left:6px'
		}, _('Open dashboard'));

		/* ---------------- add a site ---------------- */

		var siteInput = E('input', {
			'type': 'text', 'class': 'cbi-input-text', 'style': 'width:22em',
			'placeholder': _('https://example.com or a service name, e.g. youtube')
		});
		var siteGroup = E('select', { 'class': 'cbi-input-select', 'style': 'margin-left:6px' });

		function fillGroups(text) {
			var names = ['Proxy', 'DIRECT'];
			try {
				gen.parseConfig(text).groups.forEach(function (n) {
					if (n !== gen.UDP_GROUP && names.indexOf(n) < 0) names.push(n);
				});
			} catch (e) { /* keep the two that always exist */ }
			dom.content(siteGroup, names.map(function (n) { return E('option', { 'value': n }, [ n ]); }));
		}
		fillGroups(cfgText);

		function addSite() {
			var d = gen.siteDomains(siteInput.value);
			if (!d.length) {
				say(out, false, _('Not recognised as a site — enter a URL, a hostname, or a service name.'));
				return;
			}
			var group = siteGroup.value || 'Proxy';
			fs.exec(CONFCTL, ['read']).then(function (res) {
				if (res.code !== 0) throw new Error(power.describe(res));
				var next = gen.addSiteRules(res.stdout || '', d, { group: group });
				if (next === (res.stdout || '')) {
					say(out, true, _('Every one of these sites is already in the config for that group.'));
					return;
				}
				ui.showModal(_('Add sites to current configuration'), [
					E('p', {}, [ _('This adds %d site(s) to the rules of the installed config.yaml, sending them to "%s". The current file is backed up first, and nothing is installed unless mihomo accepts the result.')
						.format(d.length, group) ]),
					E('pre', { 'style': 'max-height:12em;overflow:auto;white-space:pre-wrap' }, [ d.join('\n') ]),
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
										if (r.code === 0) siteInput.value = '';
										return fs.exec(CONFCTL, ['read']);
									})
									.then(function (r) { if (r && r.code === 0) fillGroups(r.stdout || ''); })
									.catch(function (e) { say(out, false, power.describe(e)); });
							}
						}, _('Add and apply'))
					])
				]);
			}).catch(function (e) { say(out, false, String(e.message || e)); });
		}

		siteInput.addEventListener('keydown', function (ev) {
			if (ev.key === 'Enter') { ev.preventDefault(); addSite(); }
		});

		var siteRow = E('div', { 'class': 'cw-site', 'style': 'margin-top:1em' }, [
			E('label', { 'style': 'margin-right:6px' }, _('Add site:')),
			siteInput,
			siteGroup,
			' ',
			E('button', { 'type': 'button', 'class': 'cbi-button cbi-button-add', 'click': addSite }, _('Add'))
		]);

		/* ---------------- watchdog ---------------- */

		var wdBox = E('div', { 'id': 'cw-wd', 'class': 'cbi-section' });
		var wdOut = E('div');

		function wdLine(s) {
			var w = s['wd_state'];
			if (w === 'ok') {
				return _('Watchdog is on. The VPN is responding, all is well.') +
					(s['wd_delay'] ? ' (' + s['wd_delay'] + ' ' + _('ms') + ')' : '');
			}
			if (w === 'grace') return _('The watchdog has just started and is still looking around.');
			if (w === 'failing')
				return _('The VPN stopped responding. Checking again (%s of %s).').format(s['wd_fails'] || '?', s['wd_fail_limit'] || '?');
			if (w === 'bypassed')
				return _('The VPN is not responding, so the internet goes direct. It can come back in %s s at the earliest.').format(s['wd_hold_left'] || '0');
			if (w === 'wan_down') return _('There is no internet at all, so the VPN is not to blame. Waiting.');
			if (w === 'idle') return _('The proxy is off, so the watchdog has nothing to do.');
			if (w === 'skip') return _('Cannot check the VPN: %s').format(s['wd_why'] || '?');
			return _('The watchdog is not running.');
		}

		var btnProbe = E('button', {
			'class': 'cbi-button cbi-button-action',
			'click': function (ev) {
				var b = ev.target;
				b.disabled = true;
				dom.content(wdOut, E('em', {}, _('Probing…')));
				power.probe().then(function (r) {
					dom.content(wdOut, E('pre', { 'style': 'margin:6px 0 0 0;white-space:pre-wrap' }, [ r.text ]));
				}).then(function () { b.disabled = false; });
			}
		}, _('Probe now'));

		var btnForce = E('button', {
			'class': 'cbi-button cbi-button-negative',
			'style': 'margin-left:6px',
			'click': function () {
				ui.showModal(_('Restore the proxy now?'), [
					E('p', {}, _('This brings the proxy back right away, even if the VPN is still not working. After a short pause the watchdog will check it again.')),
					E('div', { 'class': 'right' }, [
						E('button', { 'class': 'cbi-button', 'click': ui.hideModal }, _('Cancel')),
						' ',
						E('button', {
							'class': 'cbi-button cbi-button-negative',
							'click': function () {
								ui.hideModal();
								setBusy(true);
								power.restore().then(function (r) {
									showResult(r.ok, r.text);
									return power.status();
								}).then(function (s) {
									busy = false;
									paint(s);
								});
							}
						}, _('Restore now'))
					])
				]);
			}
		}, _('Restore proxy now'));

		function paintWatchdog(s) {
			if (!power.serviceOn(s)) {
				dom.content(wdBox, E('div', { 'class': 'cw-wd-off', 'style': 'font-size:90%;opacity:.75' },
					_('The watchdog sleeps while ClashWrt is off.')));
				return;
			}
			if (s['wd_enabled'] !== 'on') {
				dom.content(wdBox, E('div', { 'class': 'cw-wd-off', 'style': 'font-size:90%;opacity:.75' }, [
					_('The watchdog is off.') + ' ',
					E('a', { 'href': settingsUrl() }, _('Turn it on in Settings'))
				]));
				return;
			}
			var bypassed = s['autobypass'] === 'yes';
			var kids = [
				E('h3', {}, _('Watchdog')),
				E('div', { 'class': 'cw-wd-line' }, [ wdLine(s) ]),
				E('div', { 'style': 'margin-top:8px' }, [ btnProbe ]),
				wdOut
			];
			if (bypassed) kids[2].appendChild(btnForce);
			if (bypassed && s['wd_dns_forward'] === 'yes') {
				kids.push(E('div', { 'class': 'cw-wd-dns', 'style': 'margin-top:8px;color:#b06000' },
					_('Website names may not open: DNS could not be switched away from the stopped core.')));
			}
			kids.push(E('details', { 'style': 'margin-top:8px' }, [
				E('summary', {}, _('Details')),
				E('div', { 'style': 'font-size:90%;opacity:.85' }, [
					_('Group: %s · failed probes: %s · passed probes: %s · quick relapses: %s')
						.format(s['wd_group'] || '?', s['wd_fails'] || '0', s['wd_oks'] || '0', s['wd_flaps'] || '0')
				])
			]));
			dom.content(wdBox, kids);
		}

		/* ---------------- painting ---------------- */

		function stateWord(on) { return on ? _('on') : _('off'); }

		function paint(s) {
			cur = s || {};
			var c = power.classify(cur);
			/* switches show what runs, not what boot will do: the service is
			 * on while anything of it is at work, the proxy while its rules
			 * are loaded (or a bypass holds them off for a moment) */
			var svcOn = power.serviceOn(cur);
			var svcBoot = power.serviceBoot(cur);
			var proxyOn = (cur['proxy'] === 'on' || cur['rules'] === 'present') && svcOn;
			var coreUp = cur['core'] === 'running';
			var known = !!cur['proxy'];

			dom.content(pillBox, power.pill(c.tone, c.label));
			pillBox.setAttribute('data-state', c.key);
			dom.content(msgBox, c.message);

			switches.proxy.input.checked = proxyOn;
			switches.core.input.checked = coreUp;
			switches.all.input.checked = proxyOn && coreUp;
			dom.content(switches.proxy.state, stateWord(proxyOn));
			dom.content(switches.core.state, stateWord(coreUp));
			dom.content(switches.all.state, stateWord(proxyOn && coreUp));
			switches.svc.input.checked = svcOn;
			dom.content(switches.svc.state, stateWord(svcOn));

			/* The proxy rules with no core behind them are an outage, so the
			 * page does not offer to switch them on that way round. */
			var proxyBlocked = !proxyOn && !coreUp;
			var missing = cur['core'] === 'missing';
			dom.content(switches.proxy.note,
				!svcBoot ? _('Switch ClashWrt on first.') : (proxyBlocked && known ? _('Start the core first.') : ''));
			dom.content(switches.all.note, !svcBoot ? _('Switch ClashWrt on first.') : '');
			dom.content(switches.core.note, missing ? _('The core is not installed. Install it from Settings.') : '');
			dom.content(switches.svc.note, power.serviceHalf(cur) ? [
				_('Will not start after a reboot.') + ' ',
				E('a', {
					'href': '#',
					'class': 'cw-keep',
					'click': function (ev) { ev.preventDefault(); if (!busy) act('svc', true); }
				}, _('Keep it on'))
			] : '');

			if (!busy) {
				switches.proxy.input.disabled = !known || proxyBlocked || !svcBoot;
				switches.core.input.disabled = !known || missing;
				switches.all.input.disabled = !known || missing || !svcBoot;
				switches.svc.input.disabled = !known;
			}

			btnRestart.setAttribute('data-down', coreUp ? '0' : '1');
			btnRestart.disabled = busy || !coreUp;

			paintWatchdog(cur);
		}

		/* ---------------- updates ---------------- */

		function checkUpdates() {
			var found = [];
			function ask(args, label) {
				return fs.exec(UPDCTL, args).then(function (res) {
					var st = power.parseStatus(res.stdout || '');
					if (st['update'] === 'available') found.push(label);
				}).catch(function () { /* offline is not news */ });
			}
			return Promise.all([
				ask(['self-status'], _('ClashWrt')),
				ask(['core-status'], _('mihomo core'))
			]).then(function () {
				if (!found.length) return;
				dom.content(updBox, E('a', { 'href': settingsUrl(), 'class': 'cw-upd-link' }, [
					power.pill('amber', _('Update available')),
					' ', found.join(', ')
				]));
			});
		}

		/* ---------------- assembly ---------------- */

		paint(cur);
		poll.add(function () {
			if (busy) return Promise.resolve();
			return power.status().then(function (s) { if (!busy) paint(s); });
		}, 5);
		checkUpdates();

		return E('div', { 'class': 'cbi-map' }, [
			E('style', {}, CSS),
			E('h2', {}, [
				_('ClashWrt'),
				E('span', { 'style': 'font-size:55%;font-weight:normal;opacity:0.6;margin-left:8px' }, 'ui ' + UI_VERSION)
			]),
			E('div', { 'class': 'cbi-map-descr' }, _('Status and kill switches. Everything else is in the tabs above.')),
			E('div', { 'class': 'cbi-section' }, [
				E('div', { 'style': 'font-size:120%' }, [ pillBox, msgBox, updBox ])
			]),
			E('div', { 'class': 'cbi-section' }, rows),
			E('div', { 'class': 'cbi-section' }, [
				E('div', {}, [ btnRestart, openLink ]),
				siteRow,
				out
			]),
			wdBox
		]);
	},

	handleSave: null,
	handleSaveApply: null,
	handleReset: null
});
