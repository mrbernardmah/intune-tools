#!/usr/bin/env node
// Writes dist/index.html: index.html with wu-codes.js and generator.js inlined,
// so the tool is one file you can open from disk or drop on any static host.
'use strict';
const fs = require('fs');
const path = require('path');

function build() {
  const dir = __dirname;
  let html = fs.readFileSync(path.join(dir, 'index.html'), 'utf8');
  for (const file of ['wu-codes.js', 'generator.js']) {
    const tag = '<script src="' + file + '"></script>';
    if (!html.includes(tag)) throw new Error('index.html does not reference ' + file);
    const js = fs.readFileSync(path.join(dir, file), 'utf8').replace(/<\/script/gi, '<\\/script');
    html = html.replace(tag, () => '<script>\n' + js + '</script>');
  }
  return html;
}

if (require.main === module) {
  const out = path.join(__dirname, 'dist');
  fs.mkdirSync(out, { recursive: true });
  fs.writeFileSync(path.join(out, 'index.html'), build());
  console.log('Wrote ' + path.join('dist', 'index.html'));
}
module.exports = { build };
