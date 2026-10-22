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
'require clashwrt.power as power';

var UI_VERSION = '0.5.0';


/* fs.exec rejects with an Error when the command fails or is not permitted,
 * and resolves with {code, stdout, stderr} otherwise. */
function describe(e) {
	if (!e) return '';
	if (e.stdout || e.stderr) return (e.stdout || '') + (e.stderr || '');
	return String(e.message || e);
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

/* setctl.sh status, with a held-back set said up front rather than left as one
 * line in the middle of the text -- and, when what is missing is dnsmasq-full,
 * a button that installs it. */
function setStatusView(text) {
	var held = /^HELD BACK:\s*(?:the set is not used, everything goes to mihomo:\s*)?(.*)$/m.exec(text || '');
	var pre = E('pre', { 'style': 'margin:0' }, [ text ]);
	if (!held) return pre;

	var out = E('div');
	var kids = [
		E('strong', {}, [ _('The bypass set is held back: everything goes to mihomo.') ]),
		E('div', {}, [ held[1] ])
	];
	if (/dnsmasq-full/.test(held[1])) {
		kids.push(E('div', { 'style': 'margin-top:6px' }, [
			E('button', {
				'class': 'cbi-button cbi-button-action',
				'click': function (ev) {
					var b = ev.target;
					ui.showModal(_('Install dnsmasq-full?'), [
						E('p', {}, [ _('Replaces the router\'s dnsmasq with dnsmasq-full. Your DHCP and DNS settings are kept, but name lookups on the network stop for a few seconds while it restarts.') ]),
						E('div', { 'class': 'right' }, [
							E('button', { 'class': 'cbi-button', 'click': ui.hideModal }, [ _('Cancel') ]),
							' ',
							E('button', {
								'class': 'cbi-button cbi-button-action important',
								'click': function () {
									ui.hideModal();
									b.disabled = true;
									dom.content(out, E('em', {}, [ _('Installing, this takes a minute…') ]));
									fs.exec('/usr/libexec/clashwrt/setctl.sh', ['install-dnsmasq-full']).then(function (r) {
										dom.content(out, E('div', {
											'class': r.code === 0 ? 'alert-message success' : 'alert-message warning',
											'style': 'white-space:pre-wrap'
										}, [ ((r.stdout || '') + (r.stderr || '')).trim() ]));
									}).catch(function (e) {
										dom.content(out, E('div', { 'class': 'alert-message warning' }, [ describe(e) ]));
									}).finally(function () { b.disabled = false; });
								}
							}, [ _('Install') ])
						])
					]);
				}
			}, [ _('Install dnsmasq-full') ]),
			out
		]));
	}
	return E('div', {}, [ E('div', { 'class': 'alert-message warning', 'style': 'margin-bottom:6px' }, kids), pre ]);
}

function customNode(s, tab, name, build) {
	var o = s.taboption(tab, form.DummyValue, name);
	o.rawhtml = true;
	o.render = function () { return build(); };
	o.write = function () {};
	o.remove = function () {};
	return o;
}

/* Where the core and the dashboard are kept. Moving them is a job for the
 * scripts (room checks, copy first, delete last), so each has its own Apply
 * rather than going through Save & Apply. */
function buildStorage() {
	var UPDCTL = '/usr/libexec/clashwrt/updctl.sh';
	var UICTL = '/usr/libexec/clashwrt/uictl.sh';
	var out = E('div');
	var busy = false;

	function kv(text) {
		var r = {};
		String(text || '').split('\n').forEach(function (l) {
			var m = l.match(/^([a-z]+):\s*(.*)$/);
			if (m) r[m[1]] = m[2];
		});
		return r;
	}

	function where(st) {
		var loc = String(st.location || 'none');
		var kb = function (x) { return (parseInt(x, 10) / 1024).toFixed(1) + ' MB'; };
		var m = loc.match(/^ram (\d+)K(?:, packed on flash (\d+)K)?/);
		if (m) return m[2] ? _('in RAM (%s), packed on flash (%s)').format(kb(m[1]), kb(m[2]))
			: _('in RAM only (%s)').format(kb(m[1]));
		m = loc.match(/^flash (\d+)K/);
		if (m) return _('on flash (%s)').format(kb(m[1]));
		return _('not installed');
	}

	function row(title, cmd, args, opts, status) {
		var sel = E('select', { 'class': 'cbi-input-select' }, opts.map(function (o) {
			return E('option', { 'value': o[0] }, o[1]);
		}));
		var now = E('span', {}, E('em', {}, _('checking…')));
		var btn = E('button', { 'class': 'cbi-button cbi-button-apply', 'click': function (ev) {
			ev.preventDefault();
			if (busy) return;
			busy = true; btn.disabled = true;
			dom.content(out, E('em', {}, _('Moving, this can take a minute…')));
			fs.exec(cmd, args.concat([ sel.value ])).then(function (r) {
				dom.content(out, E('div', {
					'class': r.code === 0 ? 'alert-message success' : 'alert-message warning',
					'style': 'white-space:pre-wrap' }, [ (r.stdout || '') + (r.stderr || '') ]));
			}).catch(function (e) {
				dom.content(out, E('div', { 'class': 'alert-message warning', 'style': 'white-space:pre-wrap' }, [ describe(e) ]));
			}).finally(function () { busy = false; btn.disabled = false; refresh(); });
		} }, _('Apply'));
		function refresh() {
			return fs.exec(cmd, status).then(function (r) {
				var st = kv(r.stdout);
				sel.value = st.store || 'flash';
				dom.content(now, where(st));
			}).catch(function () { dom.content(now, _('unknown')); });
		}
		refresh();
		return E('div', { 'class': 'cbi-value' }, [
			E('label', { 'class': 'cbi-value-title' }, title),
			E('div', { 'class': 'cbi-value-field' }, [ sel, ' ', btn,
				E('div', { 'class': 'cbi-value-description' }, [ _('Now: '), now ]) ])
		]);
	}

	var modes = [
		[ 'flash', _('On flash') ],
		[ 'gz', _('Packed on flash, unpacked into RAM at boot') ],
		[ 'ram', _('Only in RAM, downloaded at every boot') ]
	];

	return E('div', {}, [
		E('p', {}, [ _('The mihomo core is about 55 MB, more than many routers have free on flash. Packed it takes about 22 MB of flash; kept only in RAM, none. Either way it then takes about 55 MB of RAM, so this needs a router with 256 MB of RAM or more.') ]),
		E('p', { 'style': 'opacity:0.85' }, [ _('Only in RAM means downloading it at every boot: while GitHub cannot be reached there is no core, and LAN traffic gets what "When the VPN fails" says. Packed on flash has no such gap.') ]),
		row(_('mihomo core'), UPDCTL, [ 'core-store' ], modes, [ 'core-where' ]),
		row(_('Web dashboard'), UICTL, [ 'store' ], modes, [ 'status' ]),
		out
	]);
}

function buildOffload() {
	var SETCTL = '/usr/libexec/clashwrt/setctl.sh';
	var state = E('span', {}, E('em', {}, _('checking…')));
	var out = E('div');
	var sel = E('select', { 'class': 'cbi-input-select' }, [
		E('option', { 'value': 'off' }, _('Off')),
		E('option', { 'value': 'sw' }, _('Software')),
		E('option', { 'value': 'hw' }, _('Software and hardware'))
	]);

	function show(text) {
		var cfg = (text.match(/^offload:\s*(\S+)/m) || [])[1] || 'off';
		var ft = (text.match(/^flowtable:\s*(\S+)/m) || [])[1] || 'none';
		sel.value = cfg;
		dom.content(state, ft === 'hardware' ? _('active, in hardware')
			: ft === 'software' ? _('active, in software') : _('not active'));
	}

	function refresh() {
		return fs.exec(SETCTL, ['offload']).then(function (r) { show(r.stdout || ''); })
			.catch(function () { dom.content(state, _('unknown')); });
	}

	var btn = E('button', {
		'class': 'cbi-button cbi-button-apply',
		'click': function (ev) {
			ev.preventDefault();
			btn.disabled = true;
			dom.content(out, E('em', {}, _('Reloading the firewall…')));
			fs.exec(SETCTL, ['offload', sel.value]).then(function (r) {
				if (r.code !== 0) throw r;
				show(r.stdout || '');
				dom.content(out, '');
			}).catch(function (e) {
				dom.content(out, E('div', { 'class': 'alert-message warning', 'style': 'white-space:pre-wrap' },
					[ _('Could not change flow offloading: %s').format(describe(e)) ]));
			}).finally(function () { btn.disabled = false; });
		}
	}, _('Apply'));

	refresh();
	return E('div', { 'class': 'cbi-value' }, [
		E('label', { 'class': 'cbi-value-title' }, _('Flow offloading')),
		E('div', { 'class': 'cbi-value-field' }, [
			sel, ' ', btn,
			E('div', { 'class': 'cbi-value-description' }, [
				_('Now: '), state, '. ',
				_('Speeds up what the bypass lets past mihomo; what goes through mihomo is not affected. Hardware offloading works only on chips that support it, and SQM does not work together with it.')
			]),
			out
		])
	]);
}

return view.extend({
	load: function () {
		return Promise.all([ uci.load('clashwrt'), uci.load('network').catch(function () {}) ]);
	},

	render: function (data) {
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
		s.tab('storage', _('Storage and memory'));
		s.tab('advanced', _('Advanced'));
		
		function basic()  { return s.taboption.apply(s, ['basic'].concat([].slice.call(arguments))); }
		function bypass() { return s.taboption.apply(s, ['bypass'].concat([].slice.call(arguments))); }
		function adv()    { return s.taboption.apply(s, ['advanced'].concat([].slice.call(arguments))); }

		/* ---------------- storage and memory ---------------- */

		customNode(s, 'storage', '_n_storage', function () { return buildStorage(); });

		o = s.taboption('storage', form.Value, 'core_mem_limit', _('Memory ceiling for mihomo'),
			_('A soft limit for the Go runtime: near it mihomo frees memory more often instead of growing; nothing is killed past it. Auto: 48 MB under 256 MB of RAM, 96 MB under 512 MB, none above. Takes effect when mihomo restarts.'));
		o.value('auto', _('Auto'));
		o.value('off', _('Off'));
		o.placeholder = 'auto';
		o.rmempty = true;
		o.validate = function (sid, v) {
			return (!v || v === 'auto' || v === 'off' || /^[1-9][0-9]{1,4}$/.test(v)) ? true
				: _('auto, off, or a number of megabytes');
		};

		o = s.taboption('storage', form.Flag, 'core_verify', _('Check the core download'),
			_('A downloaded core must match the SHA-256 GitHub lists for it, or it is not installed.'));
		o.default = '1';
		o.rmempty = false;

		/* ---------------- basic ---------------- */

		/* Basic holds what people actually change. The rest -- how traffic
		 * is caught, DNS hijack, QUIC, DoH -- has safe defaults and is
		 * created here with adv(), so it opens the Advanced tab instead;
		 * options render in creation order within their tab. */
		o = adv(form.ListValue, 'mode', _('Interception mode'));
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
			_('How LAN traffic is caught. The default works on every kernel; the setup wizard tests this router and picks TPROXY when it works.') +
			'<details><summary>' + _('Which one should I pick?') + '</summary>' +
			_('<strong>TPROXY</strong> is the correct transparent-proxy mechanism and the only one that preserves the original destination of UDP without a tun device — but on some kernels it is silently broken: the rule matches and marks the packet, yet it is never delivered to the transparent socket.') + ' ' +
			_('<strong>NAT redirect</strong> always works but cannot carry UDP at all (there is no SO_ORIGINAL_DST for datagrams), so it has to be paired with a tun device.') + ' ' +
			_('<strong>Tun</strong> works everywhere but every packet takes a trip through userspace, which costs throughput.') + ' ' +
			_('If unsure, try TPROXY first and fall back to NAT redirect + tun.') +
			'</details>';

		/* A list: guest and IoT networks can be intercepted too. Networks are
		 * offered by their names (lan, guest), which fw.sh resolves to
		 * devices; a device name typed in is taken as is. */
		o = basic(form.DynamicList, 'lan_device', _('LAN networks'),
			_('Only traffic arriving on these networks is intercepted. Add a guest or IoT network to proxy it too. Default: lan.'));
		uci.sections('network', 'interface').forEach(function (n) {
			var name = n['.name'];
			if (name !== 'loopback' && !/^wan/.test(name)) o.value(name, name);
		});
		o.default = 'auto';
		o.rmempty = false;

		o = adv(form.Flag, 'dns_hijack', _('Hijack LAN DNS'),
			_('Sends LAN DNS queries to mihomo. Default: off. Leave off if dnsmasq already forwards to mihomo.'));
		o.default = '0';

		o = adv(form.Flag, 'block_quic', _('Block QUIC'),
			_('Makes browsers fall back to TCP. Default: off. Only useful when UDP is not proxied well.'));
		o.default = '0';

		o = basic(form.Flag, 'block_ipv6', _('Block IPv6 past the proxy'),
			_('The proxy handles IPv4 only, so IPv6 from your devices would reach the internet directly, with your real address. Devices fall back to IPv4. Default: on. Turn off only if you need IPv6 and accept it goes direct.'));
		o.default = '1';
		o.rmempty = false;

		o = basic(form.Flag, 'block_dot', _('Block DNS-over-TLS'),
			_('Devices with their own encrypted DNS (Android Private DNS and the like) skip the router\'s DNS, so the bypass set never learns their sites. Blocking port 853 makes them fall back to it. Default: on.'));
		o.default = '1';
		o.rmempty = false;

		o = adv(form.Flag, 'block_doh', _('Block DNS-over-HTTPS'),
			_('The same for browsers\' built-in DoH: HTTPS to known public DoH resolvers is refused, from a list refreshed daily. Default: off.'));
		o.default = '0';
		o.rmempty = false;

		o = adv(form.DynamicList, 'doh_extra', _('More DoH resolvers'),
			_('Extra IPv4 addresses to treat as DoH resolvers.'));
		o.datatype = 'ip4addr';
		o.depends('block_doh', '1');

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

		o = basic(form.ListValue, 'watchdog_action', _('When the VPN fails'),
			_('What the watchdog does when the VPN stops working while the internet is fine. Default: let traffic go direct.'));
		o.value('direct', _('Let traffic go direct (the internet keeps working, without the VPN)'));
		o.value('block', _('Cut the network off (kill switch: nothing leaves without the VPN)'));
		o.default = 'direct';
		o.depends('watchdog', '1');

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
		/* Why this exists at all is not obvious from the option names: the
		 * point is not mihomo's speed but what the router can do with traffic
		 * mihomo never touches. */
		customNode(s, 'bypass', '_n_bypasswhy', function () {
			return E('div', { 'class': 'cbi-section', 'style': 'margin-bottom:0' }, [
				E('p', {}, [ _('Traffic that goes through mihomo is relayed by the router\'s CPU, one connection at a time. Traffic the kernel lets past mihomo stays an ordinary routed connection, so the router can treat it as such.') ]),
				E('details', { 'style': 'font-size:90%;opacity:0.85' }, [
					E('summary', {}, [ _('What that gives you') ]),
					E('ul', {}, [
						E('li', {}, [ _('Hardware and software flow offloading work for it: once a connection is set up, its packets skip most of the kernel (and with hardware offloading, the CPU altogether). Connections relayed by mihomo can never be offloaded.') ]),
						E('li', {}, [ _('SQM (cake, fq_codel) sees every device separately and keeps latency low under load. Through mihomo, all traffic leaves from the router itself, as if from one device.') ]),
						E('li', {}, [ _('Full line speed on a slow CPU, and less load and heat on a fast one.') ])
					]),
					E('p', {}, [ _('Only what would go direct anyway is let past: what the proxy has to carry still reaches mihomo.') ])
				])
			]);
		});

		/* fw4's flowtable is what turns "let past mihomo" into speed. Its
		 * switch lives in Network -> Firewall; it is shown here because this
		 * is where the reason for it is. Applied on its own, like the
		 * watchdog toggle: it reloads the firewall, not ClashWrt. */
		customNode(s, 'bypass', '_n_offload', function () { return buildOffload(); });

		o = bypass(form.ListValue, 'bypass_set_profile', _('Skip the proxy for'),
			_('Skips mihomo in the kernel, which is faster. Default: whatever config.yaml does not send to the proxy.'));
		o.value('off', _('Nothing — everything goes to mihomo'));
		o.value('ru', _('Russian networks (ipdeny)'));
		o.value('ru-geoip', _('Russian networks (meta-rules-dat)'));
		o.value('refilter', _('Everything except what is blocked in Russia (Re-filter)'));
		o.value('config', _('Whatever config.yaml does not send to the proxy'));
		o.value('custom', _('A list of your own'));
		o.default = 'config';

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
				dom.content(target, setStatusView(text));
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
				.then(function (r) { dom.content(out, setStatusView(r.stdout || '')); })
				.catch(function (e) { dom.content(out, E('pre', {}, [ String(e.message || e) ])); });
		};

		/* ---------------- advanced ---------------- */

		o = adv(form.Flag, 'providers_in_ram', _('Keep rule and proxy providers in RAM'),
			_('Their daily refreshes then cost the flash no writes. Only while RAM can spare it: on routers under 256 MB, or when free RAM or /tmp runs low, they stay on (or go back to) flash. Default: on.'));
		o.default = '1';
		o.rmempty = false;

		o = adv(form.DummyValue, '_provstatus', _('Providers now'));
		o.cfgvalue = function () {
			var node = E('span', {}, [ _('checking…') ]);
			fs.exec('/usr/libexec/clashwrt/provctl.sh', ['status']).then(function (r) {
				var t = ((r && r.stdout) || '').replace(/^providers:\s*/, '').trim();
				var m = /^ram (\d+) KB/.exec(t);
				dom.content(node, [ m ? _('in RAM, %d MB').format(Math.ceil(+m[1] / 1024))
					: /^flash/.test(t) ? _('on flash: %s').format(t.replace(/^flash:\s*/, ''))
					: t === 'none' ? _('the config names no providers') : t ]);
			}).catch(function () { dom.content(node, [ '?' ]); });
			return node;
		};

		o = adv(form.Flag, 'fetch_via_proxy', _('Download through the proxy'),
			_('The core, ClashWrt updates, dashboards and bypass lists are fetched through the proxy first, and directly only if that fails. Default: on.'));
		o.default = '1';
		o.rmempty = false;

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

		return m.render();
	}
});
