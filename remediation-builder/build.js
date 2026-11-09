'use strict';
// Builds the standalone site into remediation-builder/dist:
//   index.html   - one self-contained file (builder.js inlined), safe to host anywhere or open from disk
//   sitemap.xml  - for submitting to Google Search Console
// Usage: node remediation-builder/build.js
const fs = require('fs');
const path = require('path');

const SRC = __dirname;
const DIST = path.join(SRC, 'dist');

function build() {
  const template = fs.readFileSync(path.join(SRC, 'index.html'), 'utf8');
  const js = fs.readFileSync(path.join(SRC, 'builder.js'), 'utf8');

  if (/<\/script/i.test(js)) throw new Error('builder.js contains "</script", which would break inlining.');
  const tag = '<script src="builder.js"></script>';
  if (!template.includes(tag)) throw new Error('index.html is missing ' + tag);

  const html = template.replace(tag, function () { return '<script>\n' + js + '\n</script>'; });

  const m = template.match(/<link rel="canonical" href="([^"]+)"/);
  if (!m) throw new Error('index.html is missing a canonical link.');
  const url = m[1];

  // lastmod comes from the source files, so the output is reproducible and the up-to-date test is stable.
  const newest = ['index.html', 'builder.js'].map(function (f) { return fs.statSync(path.join(SRC, f)).mtime; })
    .reduce(function (a, b) { return a > b ? a : b; });
  const lastmod = process.env.SITEMAP_LASTMOD || newest.toISOString().slice(0, 10);

  const sitemap = '<?xml version="1.0" encoding="UTF-8"?>\n' +
    '<urlset xmlns="http://www.sitemaps.org/schemas/sitemap/0.9">\n' +
    '  <url>\n    <loc>' + url + '</loc>\n    <lastmod>' + lastmod + '</lastmod>\n  </url>\n' +
    '</urlset>\n';

  return { html: html, sitemap: sitemap, url: url };
}

if (require.main === module) {
  const out = build();
  fs.mkdirSync(DIST, { recursive: true });
  fs.writeFileSync(path.join(DIST, 'index.html'), out.html);
  fs.writeFileSync(path.join(DIST, 'sitemap.xml'), out.sitemap);
  console.log('Built ' + path.join('remediation-builder', 'dist') + ' for ' + out.url);
}

module.exports = { build: build };
