'use strict';
const test = require('node:test');
const assert = require('node:assert');
const fs = require('fs');
const path = require('path');
const vm = require('vm');
const { build } = require('../build.js');

const DIST = path.join(__dirname, '..', 'dist');

test('standalone page has no external scripts or stylesheets', () => {
  const { html } = build();
  assert.ok(!/<script[^>]+\ssrc=/i.test(html), 'page must not load a script by src');
  assert.ok(!/<link[^>]+rel="stylesheet"/i.test(html), 'page must not load external CSS');
  assert.ok(!html.includes('builder.js"'), 'builder.js reference should be inlined');
});

test('standalone page carries the SEO essentials', () => {
  const { html, url } = build();
  const title = html.match(/<title>([^<]+)<\/title>/)[1];
  assert.ok(title.length >= 30 && title.length <= 70, 'title length ' + title.length);
  const desc = html.match(/<meta name="description" content="([^"]+)"/)[1];
  assert.ok(desc.length >= 70 && desc.length <= 170, 'description length ' + desc.length);
  assert.ok(html.includes('<link rel="canonical" href="' + url + '">'));
  assert.ok(html.includes('property="og:title"'));
  assert.ok(!/noindex/i.test(html), 'page must not be noindex');
  assert.strictEqual((html.match(/<h1[ >]/g) || []).length, 1, 'exactly one h1');
  const ld = html.match(/<script type="application\/ld\+json">([\s\S]*?)<\/script>/)[1];
  const data = JSON.parse(ld);
  assert.strictEqual(data['@type'], 'WebApplication');
  assert.strictEqual(data.url, url);
  assert.ok(html.includes('id="about"'), 'crawlable about text must be in the HTML');
});

test('sitemap lists the canonical URL', () => {
  const { sitemap, url } = build();
  assert.ok(sitemap.includes('<loc>' + url + '</loc>'));
  assert.ok(/<lastmod>\d{4}-\d{2}-\d{2}<\/lastmod>/.test(sitemap));
});

test('inlined script still exposes the builder API', () => {
  const { html } = build();
  const scripts = [...html.matchAll(/<script>([\s\S]*?)<\/script>/g)].map((m) => m[1]);
  const lib = scripts.find((s) => s.includes('RemediationBuilder'));
  assert.ok(lib, 'inlined library script not found');
  const sandbox = { self: {} };
  sandbox.globalThis = sandbox.self;
  vm.runInNewContext(lib, sandbox);
  assert.strictEqual(typeof sandbox.self.RemediationBuilder.runPipeline, 'function');
});

test('committed dist/index.html is up to date (run: node remediation-builder/build.js)', () => {
  const { html } = build();
  assert.strictEqual(fs.readFileSync(path.join(DIST, 'index.html'), 'utf8'), html);
  assert.ok(fs.existsSync(path.join(DIST, 'sitemap.xml')));
});
