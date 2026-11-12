'use strict';
const test = require('node:test');
const assert = require('node:assert');
const data = require('../wu-codes.js');
const gen = require('../generator.js');

test('every code is unique, well formed and mapped to known playbooks', () => {
  assert.ok(data.CODES.length > 240, 'expected the full reference, got ' + data.CODES.length);
  const known = new Set(Object.keys(gen.PLAYBOOKS));
  for (const e of data.CODES) {
    assert.match(e.code, /^0x[0-9A-F]{8}$/, e.code);
    assert.ok(e.desc.length > 5, e.code + ' needs a description');
    assert.ok(e.playbooks.length > 0, e.code + ' needs a playbook');
    for (const p of e.playbooks) assert.ok(known.has(p), e.code + ' has unknown playbook ' + p);
  }
});

test('reference spot checks', () => {
  assert.strictEqual(data.BY_CODE['0x80070422'].playbooks[0], 'services');
  assert.deepStrictEqual(data.BY_CODE['0x8024402C'].playbooks, ['network']);
  assert.ok(data.BY_CODE['0x8024400A'], 'typo x8024400A in the source page is normalised');
  assert.strictEqual(data.BY_CODE['0x80243FFF'].component, 'Windows Update UI');
});

test('normalizeCode accepts hex in several forms and decimal HRESULTs', () => {
  assert.strictEqual(gen.normalizeCode('0x80070422'), '0x80070422');
  assert.strictEqual(gen.normalizeCode('80070422'), '0x80070422');
  assert.strictEqual(gen.normalizeCode(' 0x8024a000 '), '0x8024A000');
  assert.strictEqual(gen.normalizeCode('-2147023838'), '0x80070422');
  assert.strictEqual(gen.normalizeCode('240005'), '0x00240005');
  assert.strictEqual(gen.normalizeCode('not a code'), null);
  assert.strictEqual(gen.normalizeCode('0x123456789'), null);
});

test('playbooks are derived from the codes, ordered, without info', () => {
  const r = gen.resolve(['0x8024402C', '0x80070422', '0x80240024'], {}, data);
  assert.deepStrictEqual(r.playbooks, ['services', 'network']);
  assert.strictEqual(r.id, '0x8024402C-plus2');
});

test('resolve rejects an empty selection and sanitises options', () => {
  assert.throws(() => gen.resolve([], {}, data), /at least one/);
  const r = gen.resolve(['0x80070422'], { org: 'Con toso;rm', lookbackDays: 999, restartMinutes: 1, triggerMode: 'bogus' }, data);
  assert.strictEqual(r.opts.org, 'Contosorm');
  assert.strictEqual(r.opts.lookbackDays, 90);
  assert.strictEqual(r.opts.restartMinutes, 5);
  assert.strictEqual(r.opts.triggerMode, 'either');
});

test('detection is read-only', () => {
  const all = data.CODES.map(e => e.code).slice(0, 60);
  const s = gen.detectionScript(all, {}, data, '2026-11-12');
  for (const verb of ['Set-ItemProperty', 'Remove-ItemProperty', 'Set-Service', 'Start-Service', 'Stop-Service',
    'Restart-Service', 'Rename-Item', 'Remove-Item', 'New-Item', 'Start-Process', 'shutdown.exe', 'netsh']) {
    assert.ok(!s.includes(verb), 'detection must not call ' + verb);
  }
  assert.match(s, /exit 1/);
  assert.match(s, /exit 0/);
});

test('scripts are ASCII, carry the codes, and stay well under the 200 KB limit', () => {
  const codes = data.CODES.map(e => e.code);
  for (const fn of [gen.detectionScript, gen.remediationScript]) {
    const s = fn(codes, { scheduleRestart: true, resetWinHttpProxy: true }, data, '2026-11-12');
    assert.ok(/^[\x00-\x7F]*$/.test(s), 'non-ASCII character found');
    assert.ok(s.length < 200 * 1024);
    assert.ok(s.includes("'0x80070422'"));
    assert.ok(!s.includes('${'), 'stray JS interpolation');
    assert.ok(!s.includes('undefined'), 'undefined leaked into the script');
  }
});

test('options switch the right blocks on and off', () => {
  const codes = ['0x80248003', '0x8024402C', '0x80242017', '0x80240016'];
  const on = gen.remediationScript(codes, { scheduleRestart: true, resetWinHttpProxy: true }, data);
  const off = gen.remediationScript(codes, { resetCatroot2: false, runSfc: false, triggerScan: false }, data);
  assert.match(on, /shutdown\.exe \/r/);
  assert.match(on, /winhttp reset proxy/);
  assert.match(on, /catroot2/);
  assert.match(on, /sfc\.exe/);
  assert.match(on, /UsoClient/);
  assert.ok(!off.includes('shutdown.exe'));
  assert.ok(!off.includes("'System32\\catroot2'"));
  assert.ok(!off.includes('sfc.exe'));
  assert.ok(!off.includes('UsoClient'));
});

test('explicit playbook override wins over the mapping', () => {
  const s = gen.remediationScript(['0x80070422'], { playbooks: ['reset'] }, data);
  assert.match(s, /Invoke-Step 'reset'/);
  assert.ok(!s.includes("Invoke-Step 'services'"));
});

test('file names follow the package id', () => {
  assert.deepStrictEqual(gen.fileNames(['0x80070422'], {}, data), {
    detection: 'Detect-WUError-0x80070422.ps1', remediation: 'Remediate-WUError-0x80070422.ps1', id: '0x80070422' });
});

test('unknown codes are allowed and flagged', () => {
  const sum = gen.summarize(['0x800F0922'], {}, data);
  assert.deepStrictEqual(sum.unknown, ['0x800F0922']);
  assert.ok(sum.infoOnly);
});
