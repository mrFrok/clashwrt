'use strict';
/* Every page address the JS and the installer link to is one the LuCI menu
 * registers. 1.5.0/1.5.1 linked to the view's file name (setup-wizard)
 * instead of its route (wizard), which is a 404. */
var assert = require('assert');
var fs = require('fs');
var path = require('path');

var root = path.join(__dirname, '..');
var menu = JSON.parse(fs.readFileSync(path.join(root, 'luci-app-clashwrt/root/usr/share/luci/menu.d/luci-app-clashwrt.json'), 'utf8'));
var routes = Object.keys(menu);
var n = 0;

function check(where, route) {
	route = route.replace(/^\/+|\/+$/g, '');
	if (!/^admin\/services\/clashwrt/.test(route)) return;
	assert.ok(routes.indexOf(route) >= 0, where + ': no menu entry for ' + route);
	n++;
}

var dir = path.join(root, 'luci-app-clashwrt/htdocs/luci-static/resources');
(function walk(d) {
	fs.readdirSync(d).forEach(function (f) {
		var p = path.join(d, f);
		if (fs.statSync(p).isDirectory()) return walk(p);
		if (!/\.js$/.test(f)) return;
		var src = fs.readFileSync(p, 'utf8'), m;
		/* L.url('admin', 'services', ...) and L.url('admin/services/...') */
		var re = /L\.url\(([^)]*)\)/g;
		while ((m = re.exec(src))) {
			var parts = m[1].match(/'([^']*)'/g);
			if (parts) check(f, parts.map(function (s) { return s.slice(1, -1); }).join('/'));
		}
	});
})(dir);

var inst = fs.readFileSync(path.join(root, 'install.sh'), 'utf8'), m2;
var re2 = /cgi-bin\/luci\/([A-Za-z0-9\/_-]+)/g;
while ((m2 = re2.exec(inst))) check('install.sh', m2[1]);

assert.ok(n >= 4, 'found only ' + n + ' links');
console.log('ok - ' + n + ' links all point at registered pages');
