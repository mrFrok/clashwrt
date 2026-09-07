/* SPDX-License-Identifier: GPL-3.0-or-later */
'use strict';
'require view';
'require form';
'require fs';
'require ui';
'require uci';
'require poll';
'require dom';
'require clashwrt.gen as gen';

var UI_VERSION = '0.1.2';

var callStatus = function () {
	return fs.exec('/usr/libexec/clashwrt/fw.sh', ['status'])
		.then(function (res) { return (res && res.stdout) ? res.stdout : ''; })
		.catch(function () { return ''; });
};

function parseStatus(text) {
	var out = {};
	(text || '').split('\n').forEach(function (line) {
		var i = line.indexOf(':');
		if (i < 0) return;
		out[line.slice(0, i).trim()] = line.slice(i + 1).trim();
	});
	return out;
}

var UPDCTL = '/usr/libexec/clashwrt/updctl.sh';

/* fs.exec rejects with an Error when the command fails or is not permitted,
 * and resolves with {code, stdout, stderr} otherwise. Both carry something
 * worth showing, so normalise them into one string rather than swallowing
 * the difference. */
function describe(e) {
	if (!e) return '';
	if (e.stdout || e.stderr) return (e.stdout || '') + (e.stderr || '');
	return String(e.message || e);
}

function pill(bg, fg, label) {
	return E('span', {
		'style': 'display:inline-block;padding:1px 8px;border-radius:10px;font-size:90%;' +
			'background:' + bg + ';color:' + fg + ';'
	}, label);
}

function badge(ok, label) {
	return ok ? pill('#e6f4ea', '#137333', label) : pill('#fce8e6', '#c5221f', label);
}

/* "An update is waiting" is neither good news nor bad, and neither is "the
 * network did not answer", so neither gets the green/red pair. */
function updatePill(state) {
	if (state === 'available') return pill('#fef7e0', '#b06000', _('update available'));
	if (state === 'current')   return pill('#e6f4ea', '#137333', _('up to date'));
	return pill('#f1f3f4', '#5f6368', _('cannot tell'));
}

/* Commit ids are compared in full and shown short: the whole thing tells the
 * reader nothing the first seven characters do not. */
function shortId(id) {
	if (!id || id === 'unknown') return '';
	return /^[0-9a-f]{12,}$/.test(id) ? id.slice(0, 7) : id;
}

function renderStatus(text) {
	var st = parseStatus(text);
	if (!Object.keys(st).length)
		return E('em', {}, _('Status unavailable.'));

	var rows = [
		[_('Mode'), E('strong', {}, st['mode'] || '?')],
		[_('Enabled'), badge(st['enabled'] === '1', st['enabled'] === '1' ? _('yes') : _('no'))],
		[_('Firewall ruleset'), badge(st['nft_table'] === 'present', st['nft_table'] || '?')],
		[_('mihomo daemon'), badge(st['mihomo'] === 'running', st['mihomo'] || '?')],
		[_('Tun device'), badge(st['tun_link'] === 'up', (st['tun_device'] || '') + ' ' + (st['tun_link'] || '?'))],
		[_('Tun route'), badge(st['tun_route'] === 'ok', st['tun_route'] || '?')],
		[_('TPROXY port'), E('span', {}, st['tproxy_port'] || '-')],
		[_('Redirect port'), E('span', {}, st['redir_port'] || '-')]
	];

	return E('table', { 'class': 'table' }, rows.map(function (r) {
		return E('tr', { 'class': 'tr' }, [
			E('td', { 'class': 'td left', 'style': 'width:30%' }, r[0]),
			E('td', { 'class': 'td left' }, r[1])
		]);
	}));
}

return view.extend({
	load: function () {
		return Promise.all([
			uci.load('clashwrt'),
			callStatus()
		]);
	},

	render: function (data) {
		var statusText = data[1];
		var m, s, o;

		m = new form.Map('clashwrt', _('ClashWrt — transparent proxy'),
			_('Intercepts LAN traffic and hands it to mihomo. Pick the interception mode that your kernel actually honours — see the mode descriptions below.'));

		/* ---------------- status ---------------- */

		s = m.section(form.NamedSection, 'config', 'clashwrt');
		s.render = L.bind(function (view /* self */) {
			var btn = E('button', {
				'class': 'cbi-button cbi-button-action',
				'click': function (ev) {
					var out = document.getElementById('clashwrt-selftest-out');
					ev.target.disabled = true;
					dom.content(out, E('em', {}, _('Testing, this takes a few seconds…')));
					fs.exec('/usr/libexec/clashwrt/fw.sh', ['selftest'])
						.then(function (res) {
							var text = (res.stdout || '') + (res.stderr || '');
							dom.content(out, E('pre', {
								'style': 'white-space:pre-wrap;margin:6px 0 0 0'
							}, text || _('No output.')));
						})
						.catch(function (e) {
							dom.content(out, E('pre', {}, String(e)));
						})
						.finally(function () { ev.target.disabled = false; });
				}
			}, _('Test TPROXY support'));

			function actionOut() {
				return document.getElementById('clashwrt-selftest-out');
			}

			function report(ok, text) {
				dom.content(actionOut(), E('div', {
					'class': ok ? 'alert-message success' : 'alert-message warning',
					'style': 'white-space:pre-wrap;margin-top:6px'
				}, text));
			}

			/* Restarting the core is the first thing anyone reaches for after
			 * editing a config or swapping a dashboard, so it belongs here
			 * rather than only on the page that happens to need it. Stop and
			 * start sit next to it because the pair is what you need when a
			 * config is being debugged and the daemon must be out of the way. */
			var btnPower = E('button', { 'class': 'cbi-button cbi-button-remove' }, _('Stop mihomo'));
			var running = (parseStatus(statusText)['mihomo'] === 'running');

			/* One button rather than two: a bare Stop leaves no way back from
			 * the page that offered it. Which of the two it is follows the
			 * status poll, so it cannot claim a state the router is not in. */
			function paintPower(isRunning) {
				/* leave a click that is still in flight alone */
				if (btnPower.disabled) return;
				running = isRunning;
				btnPower.className = 'cbi-button ' + (isRunning ? 'cbi-button-remove' : 'cbi-button-apply');
				dom.content(btnPower, isRunning ? _('Stop mihomo') : _('Start mihomo'));
			}

			function refreshStatus() {
				return callStatus().then(function (txt) {
					var target = document.getElementById('clashwrt-status');
					if (target) dom.content(target, renderStatus(txt));
					paintPower(parseStatus(txt)['mihomo'] === 'running');
				});
			}

			/* Run an init action and re-read the status immediately afterwards,
			 * so the badges do not sit on the old value until the next poll. */
			function service(action, busy, fallback, b) {
				b.disabled = true;
				dom.content(actionOut(), E('em', {}, busy));
				fs.exec('/etc/init.d/mihomo', [action]).then(function (res) {
					report(true, (res.stdout || '') + (res.stderr || '') || fallback);
				}).catch(function (e) {
					report(false, describe(e));
				}).finally(function () {
					b.disabled = false;
					refreshStatus();
				});
			}

			btnPower.addEventListener('click', function () {
				/* the button itself, not ev.target: paintPower keys off
				 * btnPower.disabled to know a click is still in flight */
				if (running)
					service('stop', _('Stopping mihomo…'), _('mihomo stopped.'), btnPower);
				else
					service('start', _('Starting mihomo…'), _('mihomo started.'), btnPower);
			});

			var btnRestart = E('button', {
				'class': 'cbi-button cbi-button-reset',
				'style': 'margin-left:6px',
				'click': function (ev) {
					service('restart', _('Restarting mihomo…'), _('mihomo restarted.'), ev.target);
				}
			}, _('Restart mihomo'));

			paintPower(running);

			/* Browsers cache view scripts by a URL that never changes, so after
			 * an update it is otherwise impossible to tell from the page
			 * whether you are looking at the new code or a cached copy.
			 * This stamp makes that a single glance. */
			var node = E('div', { 'class': 'cbi-section' }, [
				E('h3', {}, [
					_('Status'),
					E('span', {
						'style': 'font-size:65%;font-weight:normal;opacity:0.6;margin-left:8px'
					}, 'ui ' + UI_VERSION)
				]),
				E('div', { 'id': 'clashwrt-status' }, renderStatus(statusText)),
				E('div', { 'style': 'margin-top:1em' }, [
					btnPower, btnRestart,
					/* Worth saying plainly: the ruleset stays up when the
					 * daemon goes down, and in the TPROXY and NAT-redirect
					 * modes that means LAN traffic is sent to a port with
					 * nothing behind it rather than quietly going direct. */
					E('div', {
						'style': 'font-size:90%;opacity:0.8;margin-top:4px'
					}, _('Stopping the core does not take the firewall rules down. In the TPROXY and NAT-redirect modes intercepted traffic then has nowhere to go and fails outright, so turn Enable off below as well if you want the LAN back on a direct path.'))
				]),
				E('div', { 'style': 'margin-top:1em' }, [
					btn,
					E('div', {
						'style': 'font-size:90%;opacity:0.8;margin-top:4px'
					}, _('Checks whether this kernel actually delivers TPROXY packets to a transparent socket, and recommends a mode. Requires socat. Briefly attaches a test interface to the LAN.')),
					E('div', { 'id': 'clashwrt-selftest-out' })
				])
			]);

			poll.add(refreshStatus, 5);

			return node;
		}, this, this);

		/* ---------------- updates ---------------- */
		/* Two things get updated on a router and they fail differently, so
		 * they get a button each. The core is a single binary from a GitHub
		 * release and swapping it is contained; ClashWrt is whatever
		 * install.sh last laid down, and re-running it rewrites the LuCI
		 * pages and restarts rpcd underneath the page doing the asking. */

		s = m.section(form.NamedSection, 'config', 'clashwrt');
		s.render = L.bind(function () {
			var coreVer = E('span', {}, _('checking…'));
			var coreState = E('span', {});
			var selfVer = E('span', {}, _('checking…'));
			var selfState = E('span', {});
			var out = E('div');

			var logBox = E('pre', {
				'style': 'white-space:pre-wrap;max-height:18em;overflow:auto;margin:8px 0 0 0;display:none'
			});

			var btnCore = E('button', {
				'class': 'cbi-button cbi-button-action',
				'disabled': 'disabled'
			}, _('Update core'));

			var btnSelf = E('button', {
				'class': 'cbi-button cbi-button-action',
				'disabled': 'disabled'
			}, _('Update ClashWrt'));

			function report(ok, text) {
				dom.content(out, E('div', {
					'class': ok ? 'alert-message success' : 'alert-message warning',
					'style': 'white-space:pre-wrap;margin-top:8px'
				}, text));
			}

			function loadCore() {
				return fs.exec(UPDCTL, ['core-status']).then(function (res) {
					var st = parseStatus(res.stdout || '');
					dom.content(coreVer, [
						E('strong', {}, st['installed'] || '?'),
						' → ',
						st['latest'] || '?',
						E('span', { 'style': 'opacity:0.6' }, ' (' + (st['arch'] || '?') + ')')
					]);
					dom.content(coreState, updatePill(st['update']));
					btnCore.disabled = false;
				}).catch(function (e) {
					dom.content(coreVer, _('unavailable'));
					dom.content(coreState, updatePill('unknown'));
					report(false, describe(e));
				});
			}

			function loadSelf() {
				return fs.exec(UPDCTL, ['self-status']).then(function (res) {
					var st = parseStatus(res.stdout || '');
					var have = shortId(st['installed']);
					var want = shortId(st['latest']);
					dom.content(selfVer, [
						E('strong', {}, have || _('unknown')),
						want ? ' → ' + want : '',
						st['date'] && st['date'] !== 'unknown'
							? E('span', { 'style': 'opacity:0.6' }, ' (' + st['date'] + ')')
							: ''
					]);
					dom.content(selfState, updatePill(st['update']));
					btnSelf.disabled = false;
				}).catch(function (e) {
					dom.content(selfVer, _('unavailable'));
					dom.content(selfState, updatePill('unknown'));
					report(false, describe(e));
				});
			}

			btnCore.addEventListener('click', function (ev) {
				var b = ev.target;
				b.disabled = true;
				dom.content(out, E('em', {}, _('Downloading the core, this takes a while…')));
				fs.exec(UPDCTL, ['core-install']).then(function (res) {
					report(true, (res.stdout || '') + (res.stderr || ''));
				}).catch(function (e) {
					report(false, describe(e));
				}).finally(function () {
					b.disabled = false;
					loadCore();
				});
			});

			/* The installer replaces this very page's script and then restarts
			 * rpcd, which drops the session carrying these calls. So the work
			 * runs detached and is followed through a log file rather than
			 * through the exec that started it -- and the follow is expected
			 * to lose contact near the end rather than to fail. */
			var timer = null;
			var misses = 0;

			function stopFollow() {
				if (timer !== null) {
					window.clearInterval(timer);
					timer = null;
				}
			}

			function follow() {
				stopFollow();
				misses = 0;
				logBox.style.display = '';
				timer = window.setInterval(function () {
					fs.exec(UPDCTL, ['log']).then(function (res) {
						var text = (res.stdout || '') + (res.stderr || '');
						misses = 0;
						dom.content(logBox, text);
						logBox.scrollTop = logBox.scrollHeight;
						if (text.indexOf('=== clashwrt update finished') >= 0) {
							stopFollow();
							btnSelf.disabled = false;
							report(text.indexOf('rc=0 ===') >= 0,
								_('Update finished. Reload this page to load the new interface — you may have to log in again, because the update restarts rpcd.'));
						}
					}).catch(function () {
						/* rpcd going down at the end of the install ends this
						 * session, so a run of failures here is the normal
						 * ending, not an error worth shouting about. */
						if (++misses >= 5) {
							stopFollow();
							btnSelf.disabled = false;
							report(true, _('Lost contact with the router, which is what the last step of the update looks like: it restarts rpcd and ends this session. Log in again and reload the page.'));
						}
					});
				}, 2000);
			}

			btnSelf.addEventListener('click', function (ev) {
				var b = ev.target;
				b.disabled = true;
				dom.content(out, E('em', {}, _('Starting the update…')));
				dom.content(logBox, '');
				fs.exec(UPDCTL, ['self-update']).then(function (res) {
					report(true, (res.stdout || '') + (res.stderr || ''));
					follow();
				}).catch(function (e) {
					report(false, describe(e));
					b.disabled = false;
				});
			});

			loadCore();
			loadSelf();

			function row(label, ver, state, btn) {
				return E('tr', { 'class': 'tr' }, [
					E('td', { 'class': 'td left', 'style': 'width:22%' }, label),
					E('td', { 'class': 'td left' }, [ver, ' ', state]),
					E('td', { 'class': 'td left', 'style': 'width:14em' }, btn)
				]);
			}

			return E('div', { 'class': 'cbi-section' }, [
				E('h3', {}, _('Updates')),
				E('table', { 'class': 'table' }, [
					row(_('mihomo core'), coreVer, coreState, btnCore),
					row(_('ClashWrt'), selfVer, selfState, btnSelf)
				]),
				E('div', { 'style': 'font-size:90%;opacity:0.75;margin-top:6px' },
					_('Updating the core downloads the build for this CPU and restarts mihomo if it was running; your configuration is untouched. Updating ClashWrt re-runs the installer, which keeps /etc/config/clashwrt and config.yaml but replaces the LuCI pages — reload the page once it reports finished.')),
				logBox,
				out
			]);
		}, this, this);

		/* ---------------- protocol split toggle ---------------- */
		/* One button, because this is a thing people flip while testing.
		 * It transforms whatever config is currently installed rather than
		 * regenerating from the wizard's answers: plenty of configs were
		 * written by hand and have no answers to regenerate from, and throwing
		 * such a file away to turn one feature on would be a poor trade.
		 * confctl validates the result before installing it, so a transform
		 * that goes wrong cannot take the proxy down. */

		s = m.section(form.NamedSection, 'config', 'clashwrt');
		s.render = L.bind(function () {
			var out = E('div');
			var state = E('strong', {}, _('checking…'));
			var btn = E('button', { 'class': 'cbi-button cbi-button-action', 'disabled': 'disabled' },
				_('Enable protocol split'));

			var udpFilter = uci.get('clashwrt', 'wizard', 'udp_filter') || '(?i)(hysteria|hy2|tuic)';
			var on = false;

			function paint() {
				dom.content(state, on ? _('enabled') : _('disabled'));
				btn.className = 'cbi-button ' + (on ? 'cbi-button-reset' : 'cbi-button-action');
				dom.content(btn, on ? _('Disable protocol split') : _('Enable protocol split'));
			}

			function report(ok, text) {
				dom.content(out, E('div', {
					'class': ok ? 'alert-message success' : 'alert-message warning',
					'style': 'white-space:pre-wrap;margin-top:8px'
				}, text));
			}

			fs.exec('/usr/libexec/clashwrt/confctl.sh', ['read']).then(function (res) {
				on = gen.detectSplit(res.stdout || '').on;
				btn.disabled = false;
				paint();
			}).catch(function (e) {
				dom.content(state, _('unknown'));
				report(false, (e.stderr || e.message || String(e)));
			});

			btn.addEventListener('click', function () {
				btn.disabled = true;
				dom.content(out, E('em', {}, _('Applying…')));

				fs.exec('/usr/libexec/clashwrt/confctl.sh', ['read']).then(function (res) {
					var cur = res.stdout || '';
					var next = on
						? gen.disableSplit(cur)
						: gen.enableSplit(cur, { udpFilter: udpFilter });

					return fs.write('/tmp/clashwrt-staging', next)
						.then(function () { return fs.exec('/usr/libexec/clashwrt/confctl.sh', ['apply']); })
						.then(function (r) {
							on = !on;
							paint();
							btn.disabled = false;
							report(true, (r.stdout || '') + (r.stderr || ''));
						});
				}).catch(function (e) {
					btn.disabled = false;
					report(false, (e.stdout || '') + (e.stderr || '') || String(e.message || e));
				});
			});

			return E('div', { 'class': 'cbi-section' }, [
				E('h3', {}, _('TCP / UDP protocol split')),
				E('p', {}, [
					_('Sends UDP to QUIC-based nodes (Hysteria2, TUIC) and everything else to the TCP-based ones. Currently '),
					state, '.'
				]),
				E('p', { 'style': 'font-size:90%;opacity:0.75' },
					_('Applies to the configuration that is installed now, whether the wizard wrote it or you did. The result is checked before it replaces anything.')),
				btn,
				out
			]);
		}, this, this);

		/* ---------------- general ---------------- */

		s = m.section(form.NamedSection, 'config', 'clashwrt', _('General'));
		s.anonymous = true;

		o = s.option(form.Flag, 'enabled', _('Enable'),
			_('Build the ruleset and policy routing. Disabling tears both down and leaves traffic direct.'));
		o.rmempty = false;

		o = s.option(form.ListValue, 'mode', _('Interception mode'));
		o.value('tproxy', _('TPROXY — TCP + UDP'));
		o.value('tproxy_tun', _('TPROXY for TCP + tun for UDP'));
		o.value('tun', _('Tun — TCP + UDP'));
		o.value('redirect_tun', _('NAT redirect for TCP + tun for UDP'));
		o.default = 'redirect_tun';
		/* Joined outside the _() calls, not inside them: concatenating literals
		 * within one _() makes the runtime msgid the whole joined string,
		 * while every extractor sees four separate literals -- so the lookup
		 * misses and the text renders untranslated. */
		o.description =
			_('<strong>TPROXY</strong> is the correct transparent-proxy mechanism and the only one that preserves the original destination of UDP without a tun device — but on some kernels it is silently broken: the rule matches and marks the packet, yet it is never delivered to the transparent socket. ') +
			_('<strong>NAT redirect</strong> always works but cannot carry UDP at all (there is no SO_ORIGINAL_DST for datagrams), so it has to be paired with a tun device. ') +
			_('<strong>Tun</strong> works everywhere but every packet takes a trip through userspace, which costs throughput. ') +
			_('If unsure, try TPROXY first and fall back to NAT redirect + tun.');

		o = s.option(form.Value, 'lan_device', _('LAN device'),
			_('Only traffic arriving on this device is intercepted.'));
		o.default = 'br-lan';
		o.rmempty = false;

		o = s.option(form.Value, 'tun_device', _('Tun device'),
			_('Must match <code>tun.device</code> in mihomo\'s config.yaml.'));
		o.default = 'clash-tun';
		o.depends({ mode: 'tproxy', '!reverse': true });

		o = s.option(form.Value, 'mihomo_dir', _('Mihomo directory'),
			_('Where config.yaml lives. Listening ports are read from it, so the firewall cannot drift from the daemon.'));
		o.default = '/etc/mihomo';

		/* ---------------- behaviour ---------------- */

		s = m.section(form.NamedSection, 'config', 'clashwrt', _('Behaviour'));
		s.anonymous = true;

		o = s.option(form.Flag, 'manage_zone', _('Manage firewall zone'),
			_('Create and maintain an fw4 zone for the tun device. Without it fw4\'s own forward chain rejects forwarded tun traffic no matter what any other table accepts.'));
		o.default = '1';

		o = s.option(form.Flag, 'block_quic', _('Block QUIC'),
			_('Reject UDP/443 so browsers fall back to TCP. Only useful when UDP is not proxied well.'));
		o.default = '0';

		o = s.option(form.Flag, 'dns_hijack', _('Hijack LAN DNS'),
			_('Redirect port 53 from the LAN into mihomo\'s resolver. Leave off if dnsmasq already forwards to mihomo.'));
		o.default = '0';

		o = s.option(form.DynamicList, 'bypass_net', _('Bypass destinations'),
			_('Destination networks that are never proxied.'));
		o.datatype = 'cidr4';

		o = s.option(form.DynamicList, 'bypass_src', _('Bypass clients'),
			_('LAN source addresses that are never proxied.'));
		o.datatype = 'ip4addr';

		/* ---------------- advanced ---------------- */

		s = m.section(form.NamedSection, 'config', 'clashwrt', _('Advanced'));
		s.anonymous = true;

		o = s.option(form.Value, 'tproxy_port', _('TPROXY port'),
			_('Leave empty to read <code>tproxy-port</code> from config.yaml.'));
		o.datatype = 'port';
		o.depends('mode', 'tproxy');
		o.depends('mode', 'tproxy_tun');

		o = s.option(form.Value, 'redir_port', _('Redirect port'),
			_('Leave empty to read <code>redir-port</code> from config.yaml.'));
		o.datatype = 'port';
		o.depends('mode', 'redirect_tun');

		o = s.option(form.Value, 'dns_port', _('Mihomo DNS port'));
		o.datatype = 'port';
		o.default = '1053';

		o = s.option(form.Value, 'api_port', _('Mihomo API port'));
		o.datatype = 'port';
		o.default = '9090';

		o = s.option(form.Value, 'self_mark', _('Mihomo routing mark'),
			_('Must match <code>routing-mark</code> in config.yaml. Traffic carrying it is never re-intercepted, otherwise mihomo\'s own connections loop back into mihomo.'));
		o.datatype = 'uinteger';
		o.default = '2';

		o = s.option(form.Value, 'mark_tproxy', _('TCP fwmark'));
		o.datatype = 'uinteger';
		o.default = '1';

		o = s.option(form.Value, 'mark_tun', _('Tun fwmark'));
		o.datatype = 'uinteger';
		o.default = '3';

		o = s.option(form.Value, 'table_tproxy', _('TPROXY routing table'));
		o.datatype = 'uinteger';
		o.default = '100';

		o = s.option(form.Value, 'table_tun', _('Tun routing table'));
		o.datatype = 'uinteger';
		o.default = '151';

		o = s.option(form.Value, 'rule_pref', _('Rule preference'));
		o.datatype = 'uinteger';
		o.default = '1002';

		o = s.option(form.Value, 'tun_wait', _('Tun wait (seconds)'),
			_('How long to wait for the tun device at startup. It is created by mihomo, so it may not exist yet; hotplug re-applies the route regardless once it appears.'));
		o.datatype = 'uinteger';
		o.default = '10';

		return m.render();
	}
});
