'use strict';
const test = require('node:test');
const assert = require('node:assert');
const fs = require('node:fs');
const path = require('node:path');
const { build } = require('../build.js');

test('standalone build inlines both scripts', () => {
  const html = build();
  assert.ok(!html.includes('<script src='), 'external script tag left in the build');
  assert.ok(html.includes('WU_DATA'));
  assert.ok(html.includes('WUGen'));
});

test('dist/index.html is up to date (run: node wu-error-remediation/build.js)', () => {
  const dist = fs.readFileSync(path.join(__dirname, '..', 'dist', 'index.html'), 'utf8');
  assert.strictEqual(dist, build());
});
