'use strict';
/* Loads a shipped LuCI module (written for the LuCI loader) under plain node. */
var fs = require('fs');
var path = require('path');

var ROOT = path.join(__dirname, '..', 'luci-app-clashwrt', 'htdocs', 'luci-static', 'resources');

exports.ROOT = ROOT;

exports.load = function (rel, scope) {
	var src = fs.readFileSync(path.join(ROOT, rel), 'utf8');
	var names = Object.keys(scope || {});
	var fn = new Function(names.join(','), src);
	return fn.apply(null, names.map(function (n) { return scope[n]; }));
};

exports.baseclass = { extend: function (o) { return o; } };

exports.gen = function () {
	return exports.load('clashwrt/generator.js', { baseclass: exports.baseclass });
};
