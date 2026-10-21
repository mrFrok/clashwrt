/* SPDX-License-Identifier: GPL-3.0-or-later
 *
 * Maintenance: status table, restart and self-test, updates, the TCP/UDP
 * split and the dashboard installer. Used to be a tab of Settings; it lives
 * on the Overview now, under one collapsible section.
 */
'use strict';
'require baseclass';
'require fs';
'require ui';
'require uci';
'require dom';
'require clashwrt.generator as gen';
'require clashwrt.dashui as dashui';

var UI_VERSION = '0.5.0';

var callStatus = function () {
	return fs.exec('/usr/libexec/clashwrt/fw.sh', ['status'])
		.then(function (res) { return (res && res.stdout) ? res.stdout : ''; })
		.catch(function () { return ''; });
};

/* status refreshers registered by the blocks below, run by refresh() */
var refreshers = [];

/* told what each update check found, so the page's "update available" pill
 * reuses these answers instead of asking GitHub a second time */
var onUpdate = function () {};

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
	return pill('#fef7e0', '#b06000', _('could not check for updates'));
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

	/* refreshed by the page's own poll (see refresh below), so the Overview
	 * does not run two 5-second loops against rpcd */
	refreshers.push(refreshStatus);

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

	/* where Settings -> Storage keeps it */
	function coreWhere(st) {
		var loc = String(st['location'] || '').split(' ')[0];
		if (loc === 'ram')
			return ', ' + (st['store'] === 'gz' ? _('in RAM, packed on flash') : _('in RAM only'));
		if (loc === 'flash') return ', ' + _('on flash');
		return '';
	}

	function loadCore() {
		return fs.exec(UPDCTL, ['core-status']).then(function (res) {
			var st = parseStatus(res.stdout || '');
			dom.content(coreVer, [
				E('strong', {}, [ st['installed'] || '?' ]),
				' → ',
				st['latest'] || '?',
				E('span', { 'style': 'opacity:0.6' }, [ ' (' + (st['arch'] || '?') + ')' ]),
				E('span', { 'style': 'opacity:0.6' }, [ coreWhere(st) ])
			]);
			dom.content(coreState, updatePill(st['update']));
			onUpdate('core', st['update']);
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
			onUpdate('self', st['update']);
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


/* Export and import of the settings, through fixed paths in /tmp the way
 * LuCI's own backup page moves its archive. */
function buildBackup() {
	var CONFCTL = '/usr/libexec/clashwrt/confctl.sh';
	var out = E('div');
	function report(ok, text) {
		dom.content(out, E('div', {
			'class': ok ? 'alert-message success' : 'alert-message warning',
			'style': 'white-space:pre-wrap;margin-top:8px'
		}, [ text ]));
	}

	var btnExport = E('button', {
		'class': 'cbi-button cbi-button-action',
		'click': function (ev) {
			var b = ev.target;
			b.disabled = true;
			fs.exec(CONFCTL, ['export']).then(function (r) {
				if (r.code !== 0) throw new Error((r.stderr || r.stdout || '').trim());
				return fs.read_direct((r.stdout || '').trim(), 'blob');
			}).then(function (blob) {
				var a = E('a', {
					'href': URL.createObjectURL(blob),
					'download': 'clashwrt-settings-' + new Date().toISOString().slice(0, 10) + '.tar.gz'
				});
				document.body.appendChild(a);
				a.click();
				document.body.removeChild(a);
				dom.content(out, '');
			}).catch(function (e) {
				report(false, describe(e));
			}).finally(function () { b.disabled = false; });
		}
	}, _('Download settings'));

	var btnImport = E('button', {
		'class': 'cbi-button cbi-button-reset',
		'style': 'margin-left:6px',
		'click': function (ev) {
			var b = ev.target;
			ui.uploadFile('/tmp/clashwrt-settings-restore.tar.gz', ev.target).then(function () {
				confirmThen(_('Restore these settings?'),
					_('Replaces the ClashWrt settings, config.yaml and the rule files with the ones in the file. The current config.yaml is backed up first, and nothing is changed if mihomo does not accept the new one.'),
					_('Restore'), function () {
						b.disabled = true;
						dom.content(out, E('em', {}, [ _('Restoring…') ]));
						fs.exec(CONFCTL, ['import']).then(function (r) {
							report(r.code === 0, ((r.stdout || '') + (r.stderr || '')).trim());
						}).catch(function (e) {
							report(false, describe(e));
						}).finally(function () { b.disabled = false; });
					});
			}).catch(function () { /* the upload dialog was closed */ });
		}
	}, _('Restore from file…'));

	return E('div', { 'class': 'cbi-section' }, [
		E('h3', {}, _('Settings backup')),
		E('p', { 'style': 'font-size:90%;opacity:.8' }, [
			_('The ClashWrt settings, config.yaml and your rule files, in one file. Downloaded lists and providers are not included; they come back by themselves.')
		]),
		btnExport, btnImport,
		out
	]);
}

return baseclass.extend({
	load: function () {
		return Promise.all([ callStatus(), dashui.load() ]);
	},

	/* One section, closed unless open is set. data is what load() returned. */
	render: function (data, open, updated) {
		refreshers = [];
		onUpdate = updated || function () {};
		return E('details', { 'class': 'cbi-section', 'id': 'cw-maint', 'open': open ? '' : null }, [
			E('summary', { 'style': 'cursor:pointer;font-weight:bold;font-size:110%' }, _('Maintenance')),
			buildStatus(data[0]),
			buildUpdates(),
			buildSplit(),
			buildBackup(),
			dashui.render(data[1])
		]);
	},

	/* for the page's poll: skipped while the section is closed */
	refresh: function () {
		var d = document.getElementById('cw-maint');
		if (!d || !d.open) return Promise.resolve();
		return Promise.all(refreshers.map(function (f) { return f(); }));
	}
});
