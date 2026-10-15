/* SPDX-License-Identifier: GPL-3.0-or-later */
'use strict';
'require view';
'require form';
'require fs';
'require ui';
'require uci';
'require poll';
'require dom';
'require clashwrt.generator as gen';
'require clashwrt.dashui as dashui';
'require clashwrt.power as power';

var UI_VERSION = '0.2.7';

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
	}, [ label ]);
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

/* The engine reports state as bare words on stdout. Passing them straight to
 * the page leaves English sitting inside an otherwise translated table, so map
 * the known ones and fall back to the raw value for anything new. */
function stateWord(v) {
	var known = {
		present: _('present'), absent: _('absent'),
		running: _('running'), stopped: _('stopped'),
		up: _('up'), missing: _('missing'),
		ok: _('ok'), unknown: _('unknown')
	};
	return known[v] || v || '?';
}

/* Three states, plain words: off in the config, on and the VPN is fine, or on
 * and the VPN is down so traffic goes direct. What it says follows whether the
 * daemon really runs (fw.sh 'wd_running'), not what the switches were set to:
 * a watchdog left running by a service that is off at boot still guards. */
function watchdogPill(st) {
	var running = st['wd_running'];
	if (running === 'yes') {
		if (st['egress'] === 'bypassed')
			return pill('#fef7e0', '#b06000', _('Watchdog: bypass, VPN unavailable'));
		return pill('#e6f4ea', '#137333', _('Watchdog on, all is well'));
	}
	if (st['service'] === 'off')
		return pill('#f1f3f4', '#5f6368', _('Watchdog sleeps, ClashWrt is off'));
	if (st['watchdog'] !== 'on')
		return pill('#f1f3f4', '#5f6368', _('Watchdog off'));
	/* with the proxy off the init script starts no watchdog at all */
	if (running === 'no' && st['enabled'] !== '1')
		return pill('#f1f3f4', '#5f6368', _('Watchdog idle, the proxy is off'));
	/* an older fw.sh says nothing about the daemon itself */
	if (running === 'no')
		return pill('#fef7e0', '#b06000', _('Watchdog not running'));
	if (st['egress'] === 'bypassed')
		return pill('#fef7e0', '#b06000', _('Watchdog: bypass, VPN unavailable'));
	return pill('#e6f4ea', '#137333', _('Watchdog on, all is well'));
}

function renderStatus(text) {
	var st = parseStatus(text);
	if (!Object.keys(st).length)
		return E('em', {}, _('Status unavailable.'));

	/* The mode in UCI decides what the firewall builds; the inbounds in
	 * config.yaml decide what mihomo is listening for. Change either by hand
	 * and they stop agreeing, with nothing to show for it but traffic
	 * arriving at a port nothing is bound to. So the page reads the config
	 * and says whether it can serve the mode that is selected, rather than
	 * repeating the selection back as though it were a fact. */
	var agrees = st['conf_agrees'];
	var serves = st['conf_modes'] || '';

	var modeCell;
	if (agrees === 'no') {
		modeCell = E('span', {}, [
			E('strong', {}, [ st['mode'] || '?' ]), ' ',
			pill('#fce8e6', '#c5221f', _('config.yaml cannot serve this')),
			E('div', { 'style': 'font-size:90%;opacity:0.8;margin-top:2px' },
				[ _('Its inbounds fit: ') + serves ])
		]);
	} else if (agrees === 'yes') {
		modeCell = E('span', {}, [ E('strong', {}, [ st['mode'] || '?' ]), ' ', badge(true, _('matches config.yaml')) ]);
	} else {
		modeCell = E('span', {}, [
			E('strong', {}, [ st['mode'] || '?' ]), ' ',
			pill('#f1f3f4', '#5f6368', _('config.yaml not readable'))
		]);
	}

	var rows = [
		[_('Mode'), modeCell],
		[_('Proxy'), badge(st['enabled'] === '1', st['enabled'] === '1' ? _('on') : _('off'))],
		[_('Watchdog'), watchdogPill(st)],
		[_('Firewall ruleset'), badge(st['nft_table'] === 'present', stateWord(st['nft_table']))],
		[_('mihomo daemon'), badge(st['mihomo'] === 'running', stateWord(st['mihomo']))],
		[_('Tun device'), badge(st['tun_link'] === 'up', (st['tun_device'] || '') + ' ' + stateWord(st['tun_link']))],
		[_('Tun route'), badge(st['tun_route'] === 'ok', stateWord(st['tun_route']))],
		[_('TPROXY port'), E('span', {}, [ st['tproxy_port'] || '-' ])],
		[_('Redirect port'), E('span', {}, [ st['redir_port'] || '-' ])]
	];

	return E('table', { 'class': 'table' }, rows.map(function (r) {
		return E('tr', { 'class': 'tr' }, [
			E('td', { 'class': 'td left', 'style': 'width:30%' }, r[0]),
			E('td', { 'class': 'td left' }, r[1])
		]);
	}));
}

/* Dangerous actions ask first, in one place. */
function confirmThen(title, body, label, fn) {
	ui.showModal(title, [
		E('p', {}, [ body ]),
		E('div', { 'class': 'right' }, [
			E('button', { 'class': 'cbi-button', 'click': ui.hideModal }, _('Cancel')),
			' ',
			E('button', {
				'class': 'cbi-button cbi-button-negative important',
				'click': function () { ui.hideModal(); fn(); }
			}, label)
		])
	]);
}


/* Status, self-test and restart. Start and stop are the kill switches on the
 * Overview page now; this block only reports and restarts. */
function buildStatus(statusText) {
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
					}, [ text || _('No output.') ]));
				})
				.catch(function (e) {
					dom.content(out, E('pre', {}, [ String(e) ]));
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
		}, [ text ]));
	}

	function refreshStatus() {
		return callStatus().then(function (txt) {
			var target = document.getElementById('clashwrt-status');
			if (target) dom.content(target, renderStatus(txt));
		});
	}

	var btnRestart = E('button', {
		'class': 'cbi-button cbi-button-reset',
		'click': function (ev) {
			var b = ev.target;
			b.disabled = true;
			dom.content(actionOut(), E('em', {}, _('Restarting mihomo…')));
			fs.exec('/etc/init.d/mihomo', ['restart']).then(function (res) {
				report(true, (res.stdout || '') + (res.stderr || '') || _('mihomo restarted.'));
			}).catch(function (e) {
				report(false, describe(e));
			}).finally(function () {
				b.disabled = false;
				refreshStatus();
			});
		}
	}, _('Restart mihomo'));

	/* Browsers cache view scripts by a URL that never changes, so after
	 * an update it is otherwise impossible to tell from the page whether
	 * you are looking at the new code or a cached copy. */
	var node = E('div', { 'class': 'cbi-section' }, [
		E('h3', {}, [
			_('Status'),
			E('span', {
				'style': 'font-size:65%;font-weight:normal;opacity:0.6;margin-left:8px'
			}, 'ui ' + UI_VERSION)
		]),
		E('div', { 'id': 'clashwrt-status' }, renderStatus(statusText)),
		E('div', { 'style': 'margin-top:1em' }, [
			btnRestart,
			E('div', { 'style': 'font-size:90%;opacity:0.8;margin-top:4px' },
				_('Start and stop live on the Overview page.'))
		]),
		E('div', { 'style': 'margin-top:1em' }, [
			btn,
			E('div', { 'style': 'font-size:90%;opacity:0.8;margin-top:4px' },
				_('Checks that this kernel delivers TPROXY packets. Briefly attaches a test interface.')),
			E('details', { 'style': 'font-size:90%;opacity:0.8' }, [
				E('summary', {}, _('More about the test')),
				_('Recommends an interception mode. Requires socat.')
			]),
			E('div', { 'id': 'clashwrt-selftest-out' })
		])
	]);

	poll.add(refreshStatus, 5);

	return node;
}

function buildUpdates() {
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
		}, [ text ]));
	}

	function loadCore() {
		return fs.exec(UPDCTL, ['core-status']).then(function (res) {
			var st = parseStatus(res.stdout || '');
			dom.content(coreVer, [
				E('strong', {}, [ st['installed'] || '?' ]),
				' → ',
				st['latest'] || '?',
				E('span', { 'style': 'opacity:0.6' }, [ ' (' + (st['arch'] || '?') + ')' ])
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
				E('strong', {}, [ have || _('unknown') ]),
				want ? ' → ' + want : '',
				st['date'] && st['date'] !== 'unknown'
					? E('span', { 'style': 'opacity:0.6' }, [ ' (' + st['date'] + ')' ])
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

	function runCoreUpdate(b) {
		b.disabled = true;
		dom.content(out, E('em', {}, _('Downloading the core, this takes a while…')));
		fs.exec(UPDCTL, ['core-install']).then(function (res) {
			/* the exit code is the verdict: a refusal for lack of room
			 * resolves just like a success does */
			report(res.code === 0, (res.stdout || '') + (res.stderr || ''));
		}).catch(function (e) {
			report(false, describe(e));
		}).finally(function () {
			b.disabled = false;
			loadCore();
		});
	}

	btnCore.addEventListener('click', function (ev) {
		var b = ev.target;
		confirmThen(_('Update the mihomo core?'),
			_('mihomo restarts for a moment. Your configuration is untouched.'),
			_('Update core'), function () { runCoreUpdate(b); });
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
				dom.content(logBox, [ text ]);
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

	function runSelfUpdate(b) {
		b.disabled = true;
		dom.content(out, E('em', {}, _('Starting the update…')));
		dom.content(logBox, '');
		fs.exec(UPDCTL, ['self-update']).then(function (res) {
			report(res.code === 0, (res.stdout || '') + (res.stderr || ''));
			/* refused before it started (no room, no release): no log to follow */
			if (res.code === 0)
				follow();
			else
				b.disabled = false;
		}).catch(function (e) {
			report(false, describe(e));
			b.disabled = false;
		});
	}

	btnSelf.addEventListener('click', function (ev) {
		var b = ev.target;
		confirmThen(_('Update ClashWrt?'),
			_('The installer replaces the pages and restarts rpcd. You may have to log in again.'),
			_('Update ClashWrt'), function () { runSelfUpdate(b); });
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
		E('details', { 'style': 'font-size:90%;opacity:0.75;margin-top:6px' }, [
			E('summary', {}, _('What updating does')),
			_('Updating the core downloads the build for this CPU and restarts mihomo if it was running; your configuration is untouched. Updating ClashWrt re-runs the installer, which keeps /etc/config/clashwrt and config.yaml but replaces the LuCI pages — reload the page once it reports finished.')
		]),
		logBox,
		out
	]);
}

function buildSplit() {
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
		}, [ text ]));
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
			_('Sends UDP to QUIC nodes, the rest to TCP nodes. Currently') + ' ',
			state, '.'
		]),
		E('details', { 'style': 'font-size:90%;opacity:0.75;margin-bottom:6px' }, [
			E('summary', {}, _('How it works')),
			_('Applies to the configuration that is installed now, whether the wizard wrote it or you did. The result is checked before it replaces anything.')
		]),
		btn,
		out
	]);
}

/* The Flag below only takes effect through Save & Apply at the bottom of the
 * page, which is easy to miss. This button commits just this one option;
 * uci.apply() fires the procd reload trigger, which is the only reload. */
function buildWatchdogToggle(map, flag) {
	var on = uci.get('clashwrt', 'config', 'watchdog') === '1';
	var busy = false;
	var out = E('div');
	var btn = E('button', {
		'class': 'cbi-button',
		'click': function (ev) {
			ev.preventDefault();
			if (busy) return;
			var next = on ? '0' : '1';
			busy = true;
			btn.disabled = true;
			dom.content(out, E('em', {}, _('Applying…')));
			uci.set('clashwrt', 'config', 'watchdog', next);
			uci.save().then(function () {
				return uci.apply();
			}).then(function () {
				on = next === '1';
				syncFlag();
				dom.content(out, E('div', { 'class': 'alert-message success' },
					[ on ? _('The watchdog is on.') : _('The watchdog is off.') ]));
			}).catch(function (e) {
				dom.content(out, E('div', { 'class': 'alert-message warning',
					'style': 'white-space:pre-wrap' }, [ _('Could not change the watchdog: %s').format(describe(e)) ]));
			}).finally(function () {
				busy = false;
				btn.disabled = false;
				paint();
			});
		}
	});

	/* Keeps the checkbox in the form equal to what was just committed;
	 * otherwise a later Save would write the stale value back. */
	function syncFlag() {
		var w = flag.getUIElement ? flag.getUIElement('config') : null;
		if (w && w.setValue) w.setValue(on ? '1' : '0');
		if (map.checkDepends) map.checkDepends();
	}

	function paint() {
		btn.className = 'cbi-button ' + (on ? 'cbi-button-reset' : 'cbi-button-action');
		dom.content(btn, on ? _('Turn the watchdog off') : _('Turn the watchdog on'));
	}

	paint();
	poll.add(function () {
		if (busy) return Promise.resolve();
		return power.status().then(function (st) {
			if (st['wd_enabled'] !== 'on' && st['wd_enabled'] !== 'off') return;
			on = st['wd_enabled'] === 'on';
			paint();
		});
	}, 5);

	return E('div', { 'class': 'cbi-section', 'style': 'margin-top:-0.5em' }, [
		btn,
		E('div', { 'style': 'font-size:90%;opacity:0.8;margin-top:4px' },
			_('Applies at once, without Save.')),
		out
	]);
}

function customNode(s, tab, name, build) {
	var o = s.taboption(tab, form.DummyValue, name);
	o.rawhtml = true;
	o.render = function () { return build(); };
	o.write = function () {};
	o.remove = function () {};
	return o;
}

return view.extend({
	load: function () {
		return Promise.all([
			uci.load('clashwrt'),
			callStatus(),
			dashui.load()
		]);
	},

	render: function (data) {
		var statusText = data[1];
		var dashData = data[2];
		var m, s, o;

		/* The proxy on/off switch used to be a Flag here. It lives on the
		 * Overview page now and owns the `enabled` key, so showing a second
		 * control for it would let the two disagree. */
		m = new form.Map('clashwrt', _('Settings'),
			_('Safe defaults are set. Change only what you need.'));

		s = m.section(form.NamedSection, 'config', 'clashwrt');
		s.anonymous = true;
		s.tab('basic', _('Basic'));
		s.tab('bypass', _('Bypass'));
		s.tab('advanced', _('Advanced'));
		s.tab('maintenance', _('Maintenance'));

		function basic()  { return s.taboption.apply(s, ['basic'].concat([].slice.call(arguments))); }
		function bypass() { return s.taboption.apply(s, ['bypass'].concat([].slice.call(arguments))); }
		function adv()    { return s.taboption.apply(s, ['advanced'].concat([].slice.call(arguments))); }

		/* ---------------- basic ---------------- */

		o = basic(form.ListValue, 'mode', _('Interception mode'));
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
			_('How LAN traffic is caught. The default works on every kernel.') +
			'<details><summary>' + _('Which one should I pick?') + '</summary>' +
			_('<strong>TPROXY</strong> is the correct transparent-proxy mechanism and the only one that preserves the original destination of UDP without a tun device — but on some kernels it is silently broken: the rule matches and marks the packet, yet it is never delivered to the transparent socket.') + ' ' +
			_('<strong>NAT redirect</strong> always works but cannot carry UDP at all (there is no SO_ORIGINAL_DST for datagrams), so it has to be paired with a tun device.') + ' ' +
			_('<strong>Tun</strong> works everywhere but every packet takes a trip through userspace, which costs throughput.') + ' ' +
			_('If unsure, try TPROXY first and fall back to NAT redirect + tun.') +
			'</details>';

		o = basic(form.Value, 'lan_device', _('LAN device'),
			_('Only traffic arriving on this device is intercepted. Default: br-lan.'));
		o.default = 'br-lan';
		o.rmempty = false;

		o = basic(form.Flag, 'dns_hijack', _('Hijack LAN DNS'),
			_('Sends LAN DNS queries to mihomo. Default: off. Leave off if dnsmasq already forwards to mihomo.'));
		o.default = '0';

		o = basic(form.Flag, 'block_quic', _('Block QUIC'),
			_('Makes browsers fall back to TCP. Default: off. Only useful when UDP is not proxied well.'));
		o.default = '0';

		o = basic(form.Flag, 'watchdog', _('VPN watchdog'),
			_('Turns the proxy off for you if the VPN stops working, and back on when it recovers. Default: off.') +
			'<details><summary>' + _('How it works') + '</summary>' +
			_('It tests the proxy every few seconds. After repeated failures with the internet itself up, LAN traffic goes direct until the proxy answers again. Switching the proxy off yourself always wins.') + ' ' +
			_('While it is bypassed, DNS is switched to your uplink resolver, and switched back when the proxy returns.') +
			'</details>');
		o.default = '0';
		o.rmempty = false;
		var wdFlag = o;
		customNode(s, 'basic', '_n_wdtoggle', function () { return buildWatchdogToggle(m, wdFlag); });

		/* ---------------- bypass ---------------- */

		o = bypass(form.DynamicList, 'bypass_net', _('Bypass destinations'),
			_('Destination networks that are never proxied. Default: none.'));
		o.datatype = 'cidr4';

		o = bypass(form.DynamicList, 'bypass_src', _('Bypass clients'),
			_('LAN devices that are never proxied. Default: none.'));
		o.datatype = 'ip4addr';

		/* One question, not two.
		 *
		 * This used to ask for a direction and a list separately, which left
		 * the reader holding a puzzle only the author knew the answer to: each
		 * preset list makes sense in exactly one direction, and picking the
		 * other one is not a preference but a mistake. setctl.sh knows the
		 * same pairing and refuses a mismatch, so the second question could
		 * only ever be answered wrongly or redundantly.
		 *
		 * The direction is a real question for a list of your own, and it is
		 * asked there and nowhere else. Every line answers the same question
		 * -- what skips the proxy -- so the entries can be compared at a glance. */
		o = bypass(form.ListValue, 'bypass_set_profile', _('Skip the proxy for'),
			_('Skips mihomo in the kernel, which is faster. Default: nothing.'));
		o.value('off', _('Nothing — everything goes to mihomo'));
		o.value('ru', _('Russian networks (ipdeny)'));
		o.value('ru-geoip', _('Russian networks (meta-rules-dat)'));
		o.value('refilter', _('Everything except what is blocked in Russia (Re-filter)'));
		o.value('config', _('Whatever config.yaml does not send to the proxy'));
		o.value('custom', _('A list of your own'));
		o.default = 'off';

		/* A virtual option: it carries no UCI key of its own and instead reads
		 * and writes the two the engine actually reads. */
		o.cfgvalue = function (sid) {
			if ((uci.get('clashwrt', sid, 'bypass_set_mode') || 'off') === 'off')
				return 'off';
			return uci.get('clashwrt', sid, 'bypass_set_source') || 'ru';
		};
		o.write = function (sid, value) {
			if (value === 'off') {
				uci.set('clashwrt', sid, 'bypass_set_mode', 'off');
				return;
			}
			uci.set('clashwrt', sid, 'bypass_set_source', value);
			/* the config's own rules only make sense the way round its
			 * MATCH rule says, so that is not asked */
			if (value === 'config') {
				uci.set('clashwrt', sid, 'bypass_set_mode', 'auto');
				return;
			}
			if (value === 'custom') {
				/* the direction is settled below; only seed it, so that
				 * switching to a custom list cannot leave the set off */
				var cur = uci.get('clashwrt', sid, 'bypass_set_mode');
				if (cur !== 'exclude' && cur !== 'include')
					uci.set('clashwrt', sid, 'bypass_set_mode', 'auto');
				return;
			}
			uci.set('clashwrt', sid, 'bypass_set_mode',
				value === 'refilter' ? 'include' : 'exclude');
		};
		o.remove = function (sid) { uci.set('clashwrt', sid, 'bypass_set_mode', 'off'); };

		/* Which way round the set goes follows from what mihomo does with
		 * traffic that matches no rule, and mihomo says that in one line --
		 * its terminal MATCH rule. So the default is to read it. */
		o = bypass(form.ListValue, 'bypass_set_mode', _('Which way round'),
			_('Default: work it out from your mihomo routing.'));
		o.value('auto', _('Work it out from mihomo\'s routing'));
		o.value('exclude', _('Skip the proxy for the listed addresses'));
		o.value('include', _('Skip the proxy for everything except the listed addresses'));
		o.default = 'auto';
		o.depends('bypass_set_profile', 'custom');
		/* Written by the option above for every preset, so being inactive must
		 * not mean being cleared. */
		o.retain = true;

		/* A downloaded list does not know about the config's own rules: with
		 * "everything except the list", a site a rule sends to the proxy but
		 * the list happens to miss went direct before mihomo could see it. */
		o = bypass(form.Flag, 'bypass_set_from_config', _('Add the rules from config.yaml'),
			_('Also uses the addresses and domains your config.yaml rules send to the proxy (or, with a list of what skips the proxy, the addresses they send direct). Domains need the dnsmasq-full package. Default: on.'));
		o.default = '1';
		o.rmempty = false;
		o.depends('bypass_set_profile', 'ru');
		o.depends('bypass_set_profile', 'ru-geoip');
		o.depends('bypass_set_profile', 'refilter');
		o.depends('bypass_set_profile', 'custom');

		o = bypass(form.Value, 'bypass_set_url', _('List URL'),
			_('Plain CIDR per line, or a YAML <code>payload:</code> list. Anything that is not an IPv4 network is ignored.'));
		o.depends('bypass_set_profile', 'custom');

		o = bypass(form.Value, 'bypass_set_interval', _('Refresh interval (seconds)'),
			_('How often the list is downloaded again. Default: 86400 (one day).'));
		o.datatype = 'uinteger';
		o.default = '86400';
		o.depends('bypass_set_profile', 'ru');
		o.depends('bypass_set_profile', 'ru-geoip');
		o.depends('bypass_set_profile', 'refilter');
		o.depends('bypass_set_profile', 'custom');

		/* The status block is where a derived direction becomes visible, so it
		 * has to be filled on arrival rather than only after someone presses
		 * Refresh. cfgvalue is called more than once per render, hence the
		 * guard: one read, not one per call. */
		var setStatusRead = false;

		o = bypass(form.DummyValue, '_setstatus', _('Status'));
		o.rawhtml = true;
		o.depends({ bypass_set_profile: 'off', '!reverse': true });
		o.cfgvalue = function () {
			var node = E('div', { 'id': 'clashwrt-set-status' }, E('em', {}, _('checking…')));
			if (setStatusRead)
				return node;
			setStatusRead = true;

			var paint = function (text) {
				var target = document.getElementById('clashwrt-set-status') || node;
				dom.content(target, E('pre', { 'style': 'margin:0' }, [ text ]));
			};
			fs.exec('/usr/libexec/clashwrt/setctl.sh', ['status'])
				.then(function (r) { paint((r.stdout || '') + (r.stderr || '')); })
				.catch(function (e) { paint(String(e.message || e)); });
			return node;
		};

		o = bypass(form.Button, '_setupdate', _('Refresh now'));
		o.inputstyle = 'action';
		o.depends({ bypass_set_profile: 'off', '!reverse': true });
		o.onclick = function () {
			var out = document.getElementById('clashwrt-set-status');
			dom.content(out, E('em', {}, _('Downloading…')));
			return fs.exec('/usr/libexec/clashwrt/setctl.sh', ['update', 'force'])
				.then(function () { return fs.exec('/usr/libexec/clashwrt/setctl.sh', ['status']); })
				.then(function (r) { dom.content(out, E('pre', { 'style': 'margin:0' }, [ r.stdout || '' ])); })
				.catch(function (e) { dom.content(out, E('pre', {}, [ String(e.message || e) ])); });
		};

		/* ---------------- advanced ---------------- */

		o = adv(form.Value, 'tun_device', _('Tun device'),
			_('Must match <code>tun.device</code> in config.yaml. Default: clash-tun.'));
		o.default = 'clash-tun';
		o.depends({ mode: 'tproxy', '!reverse': true });

		o = adv(form.Value, 'mihomo_dir', _('Mihomo directory'),
			_('Where config.yaml lives; ports are read from it. Default: /etc/mihomo.'));
		o.default = '/etc/mihomo';

		o = adv(form.Flag, 'manage_zone', _('Manage firewall zone'),
			_('Keeps an fw4 zone for the tun device. Default: on. Without it fw4 rejects forwarded tun traffic.'));
		o.default = '1';

		o = adv(form.Value, 'tproxy_port', _('TPROXY port'),
			_('Leave empty to read <code>tproxy-port</code> from config.yaml. Default: empty.'));
		o.datatype = 'port';
		o.depends('mode', 'tproxy');
		o.depends('mode', 'tproxy_tun');

		o = adv(form.Value, 'redir_port', _('Redirect port'),
			_('Leave empty to read <code>redir-port</code> from config.yaml. Default: empty.'));
		o.datatype = 'port';
		o.depends('mode', 'redirect_tun');

		o = adv(form.Value, 'dns_port', _('Mihomo DNS port'),
			_('Where mihomo\'s resolver listens. Default: 1053.'));
		o.datatype = 'port';
		o.default = '1053';

		o = adv(form.Value, 'api_port', _('Mihomo API port'),
			_('Used by the dashboard and the watchdog. Default: 9090.'));
		o.datatype = 'port';
		o.default = '9090';

		o = adv(form.Value, 'self_mark', _('Mihomo routing mark'),
			_('Must match <code>routing-mark</code> in config.yaml, or mihomo\'s own traffic loops back into itself. Default: 2.'));
		o.datatype = 'uinteger';
		o.default = '2';

		o = adv(form.Value, 'mark_tproxy', _('TCP fwmark'),
			_('Firewall mark for TPROXY traffic. Default: 1.'));
		o.datatype = 'uinteger';
		o.default = '1';

		o = adv(form.Value, 'mark_tun', _('Tun fwmark'),
			_('Firewall mark for tun traffic. Default: 3.'));
		o.datatype = 'uinteger';
		o.default = '3';

		o = adv(form.Value, 'table_tproxy', _('TPROXY routing table'),
			_('Routing table number for TPROXY. Default: 100.'));
		o.datatype = 'uinteger';
		o.default = '100';

		o = adv(form.Value, 'table_tun', _('Tun routing table'),
			_('Routing table number for tun. Default: 151.'));
		o.datatype = 'uinteger';
		o.default = '151';

		o = adv(form.Value, 'rule_pref', _('Rule preference'),
			_('Priority of the policy-routing rules. Default: 1002.'));
		o.datatype = 'uinteger';
		o.default = '1002';

		o = adv(form.Value, 'tun_wait', _('Tun wait (seconds)'),
			_('How long to wait for the tun device at startup. Default: 10. Hotplug re-applies the route once it appears.'));
		o.datatype = 'uinteger';
		o.default = '10';

		function wd(name, title, desc, def) {
			var w = adv(form.Value, name, title, desc);
			w.datatype = 'min(1)';
			w.default = def;
			w.placeholder = def;
			w.depends('watchdog', '1');
			return w;
		}

		o = adv(form.Value, 'watchdog_group', _('Watchdog proxy group'),
			_('Group whose delay is tested. Default: empty, read from config.yaml.'));
		o.depends('watchdog', '1');

		wd('watchdog_fail', _('Watchdog: failures before bypass'),
			_('Failed tests in a row, with the internet up, before traffic goes direct. Default: 3.'), '3');
		wd('watchdog_ok', _('Watchdog: successes before restore'),
			_('Good tests in a row before the proxy comes back. Default: 3.'), '3');
		wd('watchdog_interval', _('Watchdog: test interval (seconds)'),
			_('Time between tests while all is well. Default: 20.'), '20');
		wd('watchdog_fast', _('Watchdog: fast interval (seconds)'),
			_('Time between tests after a failure. Default: 5.'), '5');
		wd('watchdog_hold', _('Watchdog: minimum bypass (seconds)'),
			_('Traffic stays direct at least this long. Default: 120.'), '120');
		wd('watchdog_hold_max', _('Watchdog: maximum bypass hold (seconds)'),
			_('The hold doubles on repeated flips, up to this. Default: 900.'), '900');
		wd('watchdog_grace', _('Watchdog: boot grace (seconds)'),
			_('No bypass this long after the proxy starts. Default: 90.'), '90');
		wd('watchdog_timeout', _('Watchdog: test timeout (seconds)'),
			_('How long one test waits for an answer. Default: 5.'), '5');

		/* ---------------- maintenance ---------------- */

		customNode(s, 'maintenance', '_n_status', function () { return buildStatus(statusText); });
		customNode(s, 'maintenance', '_n_updates', buildUpdates);
		customNode(s, 'maintenance', '_n_split', buildSplit);
		customNode(s, 'maintenance', '_n_dash', function () { return dashui.render(dashData); });

		return m.render();
	}
});
