'use strict';
// Runs the generated PowerShell against mocked Windows commands (test/mocks.ps1).
// Needs pwsh on PATH (preinstalled on GitHub's ubuntu runners); skipped otherwise.
const test = require('node:test');
const assert = require('node:assert');
const fs = require('node:fs');
const os = require('node:os');
const path = require('node:path');
const { execFileSync, spawnSync } = require('node:child_process');
const data = require('../wu-codes.js');
const gen = require('../generator.js');

const PWSH = process.env.PWSH || 'pwsh';
const hasPwsh = spawnSync(PWSH, ['-NoProfile', '-Command', '1'], { encoding: 'utf8' }).status === 0;
const opts = { skip: hasPwsh ? false : 'pwsh not found' };

function run(kind, codes, options, scenario, env = {}) {
  const dir = fs.mkdtempSync(path.join(os.tmpdir(), 'wu-'));
  const file = path.join(dir, kind + '.ps1');
  const fn = kind === 'detect' ? gen.detectionScript : gen.remediationScript;
  fs.writeFileSync(file, fn(codes, options, data, '2026-11-12'));
  const outText = execFileSync(PWSH, ['-NoProfile', '-NonInteractive', '-File', path.join(__dirname, 'run-script.ps1'), '-Script', file], {
    encoding: 'utf8',
    env: Object.assign({}, process.env, { WU_TEST_ROOT: dir, WU_SCENARIO: scenario, WU_PACKAGE: gen.fileNames(codes, options, data).id }, env)
  });
  const res = JSON.parse(outText.trim().split('\n').pop());
  res.dir = dir;
  return res;
}

test('every generated script parses in PowerShell', opts, () => {
  const dir = fs.mkdtempSync(path.join(os.tmpdir(), 'wu-parse-'));
  const sets = [['0x80070422'], ['0x8024002E', '0x80246009', '0x80248003', '0x8024402C', '0x80242017', '0x80240016'], ['0x80240024'], ['0x800F0922']];
  const variants = [{}, { scheduleRestart: true, resetWinHttpProxy: true, resetCatroot2: false, runSfc: false, triggerScan: false, policyRemoveWsus: false, policyRemoveBlocks: false, triggerMode: 'state' }];
  let i = 0;
  for (const c of sets) for (const o of variants) {
    fs.writeFileSync(path.join(dir, 'd' + i + '.ps1'), gen.detectionScript(c, o, data));
    fs.writeFileSync(path.join(dir, 'r' + i + '.ps1'), gen.remediationScript(c, o, data));
    i++;
  }
  const check = "$bad=0; foreach($f in Get-ChildItem '" + dir + "' -Filter *.ps1){$t=$null;$e=$null;[void][System.Management.Automation.Language.Parser]::ParseFile($f.FullName,[ref]$t,[ref]$e); if($e.Count){$bad++; Write-Output ($f.Name+': '+$e[0].Message)}}; Write-Output \"bad=$bad\"";
  const out = execFileSync(PWSH, ['-NoProfile', '-Command', check], { encoding: 'utf8' });
  assert.match(out, /bad=0/, out);
});

test('detection: healthy device is compliant', opts, () => {
  const r = run('detect', ['0x80070422'], {}, 'healthy');
  assert.strictEqual(r.exit, 0, r.out);
  assert.match(r.out, /^Compliant/);
});

test('detection: disabled wuauserv triggers 0x80070422 fix', opts, () => {
  const r = run('detect', ['0x80070422'], {}, 'svc-disabled');
  assert.strictEqual(r.exit, 1, r.out);
  assert.match(r.out, /NonCompliant.*wuauserv disabled/);
});

test('detection: state checks are ignored in error-only mode', opts, () => {
  const r = run('detect', ['0x80070422'], { triggerMode: 'error' }, 'svc-disabled');
  assert.strictEqual(r.exit, 0, r.out);
});

test('detection: recent history entry is found, old one is not', opts, () => {
  assert.strictEqual(run('detect', ['0x80246009'], {}, 'history-new').exit, 1);
  assert.strictEqual(run('detect', ['0x80246009'], {}, 'history-old').exit, 0);
});

test('detection: errors before the last remediation are not counted again', opts, () => {
  const marker = new Date(Date.now() - 60 * 60 * 1000).toISOString();
  const r = run('detect', ['0x80246009'], {}, 'history-new', { WU_MARKER: marker });
  assert.strictEqual(r.exit, 0, r.out);
});

test('detection: WSUS leftovers flagged, but not on Configuration Manager clients', opts, () => {
  const a = run('detect', ['0x8024002E'], { policyRemoveBlocks: false }, 'wsus');
  assert.strictEqual(a.exit, 1, a.out);
  assert.match(a.out, /policy WUServer=/);
  const b = run('detect', ['0x8024002E'], { policyRemoveBlocks: false }, 'wsus-configmgr');
  assert.strictEqual(b.exit, 0, b.out);
});

test('detection: pending restart and unhealthy image are reported', opts, () => {
  assert.match(run('detect', ['0x80240016'], {}, 'reboot').out, /restart pending/);
  assert.match(run('detect', ['0x80242017'], {}, 'image-bad').out, /image Repairable/);
});

test('remediation: services re-enabled and started, marker written', opts, () => {
  const r = run('remed', ['0x80070422'], {}, 'svc-disabled');
  assert.strictEqual(r.exit, 0, r.out);
  assert.strictEqual(r.svc.wuauserv.StartType, 'Manual');
  assert.strictEqual(r.svc.wuauserv.Status, 'Running');
  const marker = r.reg['HKLM:\\SOFTWARE\\IntuneTools\\WUErrorRemediation\\0x80070422'];
  assert.ok(marker && marker.LastRemediatedUtc, 'marker missing');
  assert.match(r.out, /^Remediated \[0x80070422\]/);
});

test('remediation: WSUS values removed with a backup', opts, () => {
  const r = run('remed', ['0x8024002E'], {}, 'wsus');
  assert.strictEqual(r.exit, 0, r.out);
  assert.ok(r.calls.includes('reg export'));
  assert.deepStrictEqual(r.reg['HKLM:\\SOFTWARE\\Policies\\Microsoft\\Windows\\WindowsUpdate'], {});
  assert.deepStrictEqual(r.reg['HKLM:\\SOFTWARE\\Policies\\Microsoft\\Windows\\WindowsUpdate\\AU'], {});
});

test('remediation: reset renames SoftwareDistribution and catroot2, restarts services', opts, () => {
  const r = run('remed', ['0x80248003'], { triggerScan: false }, 'healthy');
  assert.strictEqual(r.exit, 0, r.out);
  assert.ok(r.dirs.some(d => d.startsWith('SoftwareDistribution.bak-')), r.dirs.join(','));
  assert.ok(r.dirs.some(d => d.startsWith('catroot2.bak-')), r.dirs.join(','));
  assert.ok(!r.dirs.includes('SoftwareDistribution'));
  assert.strictEqual(r.svc.wuauserv.Status, 'Running');
});

test('remediation: only failed BITS jobs are removed', opts, () => {
  const r = run('remed', ['0x80246009'], { triggerScan: false }, 'healthy');
  assert.ok(r.calls.includes('Remove-BitsTransfer WU Client Download'));
  assert.ok(!r.calls.includes('Remove-BitsTransfer Other'));
});

test('remediation: restart only scheduled when enabled', opts, () => {
  const off = run('remed', ['0x80240016'], {}, 'reboot');
  assert.ok(!off.calls.some(c => c.startsWith('shutdown')));
  assert.match(off.out, /RemediatedWithWarnings.*scheduling is off/);
  const on = run('remed', ['0x80240016'], { scheduleRestart: true, restartMinutes: 60 }, 'reboot');
  assert.ok(on.calls.some(c => c.startsWith('shutdown /r /t')), on.calls.join('|'));
  assert.match(on.out, /restart scheduled in 60 min/);
});

test('remediation: component repair runs DISM and SFC', opts, () => {
  const r = run('remed', ['0x80242017'], { triggerScan: false }, 'healthy');
  assert.ok(r.calls.includes('Start-Process dism.exe'));
  assert.ok(r.calls.includes('Start-Process sfc.exe'));
});
