/* SPDX-License-Identifier: GPL-3.0-or-later */
'use strict';
'require view';
'require fs';
'require ui';
'require dom';

var STAGING = '/tmp/clashwrt-staging';
var FILECTL = '/usr/libexec/clashwrt/filectl.sh';

function filectl(args) { return fs.exec(FILECTL, args); }

function parseList(text) {
	return (text || '').split('\n')
		.filter(function (l) { return l.trim().length; })
		.map(function (l) {
			var p = l.split('\t');
			return { name: p[0], bytes: parseInt(p[1] || '0', 10), lines: parseInt(p[2] || '0', 10) };
		});
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
			filectl(['list']).catch(function () { return { stdout: '' }; }),
			filectl(['dir']).catch(function () { return { stdout: '' }; })
		]);
	},

	render: function (data) {
		var files = parseList(data[0] && data[0].stdout);
		var dir = ((data[1] && data[1].stdout) || '').trim();

		var self = this;
		var out = E('div', { 'id': 'clashwrt-files-out' });
		var current = E('span', { 'style': 'font-weight:bold' }, _('nothing open'));

		var area = E('textarea', {
			'style': 'width:100%;min-height:45vh;font-family:monospace;font-size:12px;white-space:pre;overflow-wrap:normal;overflow-x:auto',
			'spellcheck': 'false',
			'disabled': 'disabled'
		}, '');

		var openName = null;

		function openFile(name) {
			return filectl(['read', name]).then(function (res) {
				openName = name;
				area.value = res.stdout || '';
				area.disabled = false;
				dom.content(current, name);
				dom.content(out, '');
			}).catch(function (e) {
				say(out, false, (e.stderr || e.stdout || String(e)));
			});
		}

		/* Rows are replaced inside the <table> itself. Wrapping them in a
		 * container element instead breaks the table layout: a <div> between
		 * <table> and <tr> is not valid table content, so the browser hoists
		 * the rows out and the columns stop lining up. */
		function refresh() {
			return filectl(['list']).then(function (res) {
				var rows = parseList(res.stdout);
				while (table.rows.length > 1)
					table.deleteRow(table.rows.length - 1);
				rows.forEach(function (f) { table.appendChild(rowFor(f)); });
			});
		}

		function rowFor(f) {
			return E('tr', { 'class': 'tr' }, [
				E('td', { 'class': 'td left' },
					E('a', {
						'href': '#',
						'click': function (ev) { ev.preventDefault(); openFile(f.name); }
					}, f.name)),
				E('td', { 'class': 'td left', 'style': 'width:6em' }, String(f.lines)),
				E('td', { 'class': 'td left', 'style': 'width:8em' }, String(f.bytes)),
				E('td', { 'class': 'td right', 'style': 'width:8em' },
					E('button', {
						'class': 'cbi-button cbi-button-remove',
						'click': function () {
							ui.showModal(_('Delete file'), [
								E('p', {}, _('Delete %s? A config that still refers to it will fail to load.').format(f.name)),
								E('div', { 'class': 'right' }, [
									E('button', { 'class': 'cbi-button', 'click': ui.hideModal }, _('Cancel')),
									' ',
									E('button', {
										'class': 'cbi-button cbi-button-negative',
										'click': function () {
											ui.hideModal();
											filectl(['delete', f.name])
												.then(function (res) {
													say(out, true, res.stdout || _('Deleted.'));
													if (openName === f.name) {
														openName = null;
														area.value = '';
														area.disabled = true;
														dom.content(current, _('nothing open'));
													}
													return refresh();
												})
												.catch(function (e) { say(out, false, (e.stderr || String(e))); });
										}
									}, _('Delete'))
								])
							]);
						}
					}, _('Delete')))
			]);
		}

		var table = E('table', { 'class': 'table' }, [
			E('tr', { 'class': 'tr table-titles' }, [
				E('th', { 'class': 'th left' }, _('File')),
				E('th', { 'class': 'th left', 'style': 'width:6em' }, _('Lines')),
				E('th', { 'class': 'th left', 'style': 'width:8em' }, _('Bytes')),
				E('th', { 'class': 'th right', 'style': 'width:8em' }, '')
			])
		]);
		files.forEach(function (f) { table.appendChild(rowFor(f)); });

		var newName = E('input', {
			'type': 'text',
			'class': 'cbi-input-text',
			'placeholder': 'mylist.txt',
			'style': 'width:16em'
		});

		var btnNew = E('button', {
			'class': 'cbi-button cbi-button-add',
			'style': 'margin-left:6px',
			'click': function () {
				var n = (newName.value || '').trim();
				if (!n) { say(out, false, _('Enter a file name first.')); return; }
				openName = n;
				area.value = '';
				area.disabled = false;
				dom.content(current, n);
				say(out, true, _('New file staged. It is created on the router when you save.'));
			}
		}, _('New file'));

		var btnSave = E('button', {
			'class': 'cbi-button cbi-button-positive',
			'click': function (ev) {
				if (!openName) { say(out, false, _('Open or create a file first.')); return; }
				var b = ev.target;
				b.disabled = true;
				fs.write(STAGING, area.value)
					.then(function () { return filectl(['save', openName]); })
					.then(function (res) {
						say(out, true, res.stdout || _('Saved.'));
						return refresh();
					})
					.catch(function (e) { say(out, false, (e.stderr || e.stdout || String(e))); })
					.finally(function () { b.disabled = false; });
			}
		}, _('Save file'));

		return E('div', { 'class': 'cbi-map' }, [
			E('h2', {}, _('Rule files')),
			E('div', { 'class': 'cbi-map-descr' },
				_('Hand-maintained lists that a config refers to as file-backed rule providers, for example <code>{ behavior: classical, type: file, format: text, path: ./lst/mylist.txt }</code>. One rule per line, such as <code>DOMAIN-SUFFIX,example.com</code>.')),

			E('div', { 'class': 'cbi-section' }, [
				E('h3', {}, _('Files in %s').format(dir || '?')),
				table,
				E('div', { 'style': 'margin-top:8px' }, [ newName, btnNew ])
			]),

			E('div', { 'class': 'cbi-section' }, [
				E('h3', {}, [ _('Editing: '), current ]),
				area,
				E('div', { 'style': 'margin-top:8px' }, [ btnSave ]),
				out
			])
		]);
	},

	handleSave: null,
	handleSaveApply: null,
	handleReset: null
});
