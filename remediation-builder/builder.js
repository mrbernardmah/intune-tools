/*
 * Remediation Builder - core logic.
 * Works in the browser (window.RemediationBuilder) and in Node (module.exports) so it can be unit tested.
 *
 * Pipeline: describe -> Claude generates detection + remediation scripts -> static lint
 *           -> Claude "virtual test" (simulated runs against scenarios) -> auto-fix loop -> final bundle.
 *
 * IMPORTANT: the virtual test is Claude reasoning about what the scripts would do. It is NOT real execution.
 * Always pilot on a small device group before wide assignment.
 */
(function (root, factory) {
  if (typeof module === 'object' && module.exports) module.exports = factory();
  else root.RemediationBuilder = factory();
})(typeof self !== 'undefined' ? self : this, function () {
  'use strict';

  var API_URL = 'https://api.anthropic.com/v1/messages';
  var API_VERSION = '2023-06-01';
  var MAX_SCRIPT_BYTES = 200 * 1024; // Intune script size limit

  // ---------------------------------------------------------------------------
  // Prompts
  // ---------------------------------------------------------------------------

  var INTUNE_RULES = [
    'Microsoft Intune Remediations (Proactive Remediations) rules you MUST follow:',
    '- A detection script and a remediation script are a pair. Detection runs first.',
    '- Detection exit code 0 = compliant (remediation is NOT run). Exit code 1 = issue found (remediation runs).',
    '- Detection must be strictly read-only: it must never change the device.',
    '- Remediation must be idempotent, safe to re-run, and must exit 0 on success and 1 on failure.',
    '- After remediation, Intune runs detection again to verify. The remediation must make detection return 0.',
    '- Only the last line written to standard output is shown reliably in the Intune portal, and output is truncated at 2048 characters. Emit one concise status line using Write-Output.',
    '- No interactive input of any kind (Read-Host, pause, Out-GridView, Get-Credential, message boxes).',
    '- Scripts run non-interactively with a 30 minute timeout; keep them fast.',
    '- Scripts may run as SYSTEM or as the signed-in user, and in 32-bit or 64-bit PowerShell (Windows PowerShell 5.1). Respect the requested context. As SYSTEM, HKCU and user profile paths do not point at the user; enumerate loaded user hives or profiles instead if needed.',
    '- Wrap risky operations in try/catch, set $ErrorActionPreference = "Stop" where appropriate, and always finish with an explicit exit code.',
    '- Never hard-code secrets, never download and execute remote code, never disable security controls, never run destructive wildcard deletes outside a narrowly scoped path.',
    '- Do not restart or shut down the device unless the user explicitly asked for it.',
    '- Keep each script under 200 KB. Add brief comments. Prefer built-in cmdlets and no extra module dependencies.'
  ].join('\n');

  var GENERATE_SYSTEM = [
    'You are a senior Microsoft Intune / Windows endpoint engineer who writes production-grade Intune Remediation script pairs in Windows PowerShell 5.1.',
    INTUNE_RULES,
    '',
    'Respond with ONE JSON object and nothing else (no markdown fences, no commentary). Schema:',
    '{',
    '  "title": string,                       // short name, e.g. "Clear Teams cache"',
    '  "summary": string,                     // 1-3 sentences: what is detected and what is fixed',
    '  "runAs": "system" | "user",            // recommended Intune run context',
    '  "run64Bit": boolean,                   // recommended "Run script in 64-bit PowerShell"',
    '  "detection": string,                   // full detection.ps1 contents',
    '  "remediation": string,                 // full remediation.ps1 contents',
    '  "assumptions": string[],               // anything you assumed because the request was ambiguous',
    '  "scenarios": [                         // 4-6 virtual test scenarios the pair must handle',
    '    { "name": string, "deviceState": string, "expectedDetectionExit": 0 | 1,',
    '      "expectedDetectionOutput": string, "expectedRemediation": string }',
    '  ]',
    '}',
    'Scenarios must include: a compliant device, a non-compliant device that remediation can fix, a device where the target feature or path does not exist at all, and one failure case (for example access denied or service missing).'
  ].join('\n');

  var TEST_SYSTEM = [
    'You are a meticulous PowerShell reviewer acting as a virtual test harness for Intune Remediation scripts.',
    'You cannot execute code. Instead, mentally execute the scripts line by line against each scenario, as Windows PowerShell 5.1 would on a Windows 11 device, in the stated run context.',
    'Be strict and honest: report real syntax errors, wrong cmdlet names or parameters, wrong registry/WMI/CIM paths, StrictMode/null problems, wrong exit codes, output longer than 2048 characters, detection that modifies state, remediation that does not make detection pass afterwards, SYSTEM-vs-user context mistakes, and anything unsafe.',
    'For each scenario simulate: (1) detection trace, exit code and output; (2) if exit code is 1, remediation trace, exit code and output; (3) detection run again after remediation. Mark passed only if actual behaviour matches the scenario expectation and Intune semantics.',
    'Respond with ONE JSON object and nothing else. Schema:',
    '{',
    '  "verdict": "pass" | "fail",',
    '  "summary": string,',
    '  "results": [ { "scenario": string, "detectionExit": number, "detectionOutput": string,',
    '                 "remediationExit": number | null, "remediationOutput": string | null,',
    '                 "postRemediationDetectionExit": number | null, "passed": boolean, "notes": string } ],',
    '  "issues": [ { "severity": "error" | "warning", "script": "detection" | "remediation", "line": number | null,',
    '                "problem": string, "fix": string } ]',
    '}',
    'verdict is "fail" if any scenario fails or any issue has severity "error".'
  ].join('\n');

  var FIX_SYSTEM = [
    'You are a senior Microsoft Intune / Windows endpoint engineer fixing Intune Remediation scripts after review.',
    INTUNE_RULES,
    'You will receive the current scripts, deterministic lint findings and a virtual test report. Fix every error and every failed scenario with the smallest sensible change; keep behaviour that already works.',
    'Respond with ONE JSON object and nothing else, using the same schema as the original generation (title, summary, runAs, run64Bit, detection, remediation, assumptions, scenarios). Update scenarios only if they were wrong.'
  ].join('\n');

  function describeOptions(opts) {
    opts = opts || {};
    var lines = [];
    lines.push('Run context: ' + (opts.runAs === 'user' ? 'signed-in user' : opts.runAs === 'system' ? 'SYSTEM' : 'choose the best fit and justify in assumptions'));
    lines.push('64-bit PowerShell: ' + (opts.run64Bit === false ? 'no (32-bit)' : opts.run64Bit === true ? 'yes' : 'choose the best fit'));
    if (opts.notes) lines.push('Extra constraints from the engineer: ' + String(opts.notes).trim());
    return lines.join('\n');
  }

  function buildGeneratePrompt(input, opts) {
    return [
      'Create an Intune Remediation script pair for this request.',
      '',
      'REQUEST:',
      String(input || '').trim(),
      '',
      describeOptions(opts)
    ].join('\n');
  }

  function buildTestPrompt(bundle, opts) {
    return [
      'Virtually test this Intune Remediation pair.',
      '',
      describeOptions({ runAs: bundle.runAs, run64Bit: bundle.run64Bit, notes: opts && opts.notes }),
      '',
      'SCENARIOS (you may add more if you spot gaps):',
      JSON.stringify(bundle.scenarios || [], null, 2),
      '',
      '=== detection.ps1 ===',
      numberLines(bundle.detection),
      '',
      '=== remediation.ps1 ===',
      numberLines(bundle.remediation)
    ].join('\n');
  }

  function buildFixPrompt(bundle, lintFindings, testReport, input) {
    return [
      'ORIGINAL REQUEST:',
      String(input || '').trim(),
      '',
      'CURRENT BUNDLE (JSON):',
      JSON.stringify(bundle, null, 2),
      '',
      'DETERMINISTIC LINT FINDINGS:',
      JSON.stringify(lintFindings, null, 2),
      '',
      'VIRTUAL TEST REPORT:',
      JSON.stringify(testReport, null, 2),
      '',
      'Return the corrected bundle JSON.'
    ].join('\n');
  }

  function numberLines(code) {
    return String(code || '').split(/\r?\n/).map(function (l, i) { return (i + 1) + ': ' + l; }).join('\n');
  }

  // ---------------------------------------------------------------------------
  // JSON extraction / bundle validation
  // ---------------------------------------------------------------------------

  function extractJson(text) {
    if (typeof text !== 'string') throw new Error('Model returned no text.');
    var t = text.trim();
    var fence = t.match(/```(?:json)?\s*([\s\S]*?)```/i);
    if (fence) t = fence[1].trim();
    try { return JSON.parse(t); } catch (e) { /* fall through to brace scan */ }
    var start = t.indexOf('{');
    if (start < 0) throw new Error('No JSON object found in model output.');
    var depth = 0, inStr = false, esc = false;
    for (var i = start; i < t.length; i++) {
      var c = t[i];
      if (inStr) {
        if (esc) esc = false;
        else if (c === '\\') esc = true;
        else if (c === '"') inStr = false;
      } else if (c === '"') inStr = true;
      else if (c === '{') depth++;
      else if (c === '}') {
        depth--;
        if (depth === 0) return JSON.parse(t.slice(start, i + 1));
      }
    }
    throw new Error('Unterminated JSON object in model output (response may have been cut off).');
  }

  function normaliseBundle(b) {
    if (!b || typeof b !== 'object') throw new Error('Bundle is not an object.');
    if (typeof b.detection !== 'string' || !b.detection.trim()) throw new Error('Bundle is missing the detection script.');
    if (typeof b.remediation !== 'string' || !b.remediation.trim()) throw new Error('Bundle is missing the remediation script.');
    return {
      title: String(b.title || 'Untitled remediation'),
      summary: String(b.summary || ''),
      runAs: b.runAs === 'user' ? 'user' : 'system',
      run64Bit: b.run64Bit !== false,
      detection: b.detection.replace(/\r?\n/g, '\r\n'),
      remediation: b.remediation.replace(/\r?\n/g, '\r\n'),
      assumptions: Array.isArray(b.assumptions) ? b.assumptions.map(String) : [],
      scenarios: Array.isArray(b.scenarios) ? b.scenarios : []
    };
  }

  function normaliseTestReport(r) {
    if (!r || typeof r !== 'object') throw new Error('Test report is not an object.');
    var issues = Array.isArray(r.issues) ? r.issues : [];
    var results = Array.isArray(r.results) ? r.results : [];
    var failedScenario = results.some(function (x) { return x && x.passed === false; });
    var hasError = issues.some(function (x) { return x && x.severity === 'error'; });
    // Never trust a "pass" verdict that contradicts the detail.
    var verdict = (r.verdict === 'pass' && !failedScenario && !hasError) ? 'pass' : 'fail';
    return { verdict: verdict, summary: String(r.summary || ''), results: results, issues: issues };
  }

  // ---------------------------------------------------------------------------
  // Deterministic static lint (no AI involved)
  // ---------------------------------------------------------------------------

  function maskBlockComments(code) {
    return code.replace(/<#[\s\S]*?#>/g, function (m) { return m.replace(/[^\r\n]/g, ' '); });
  }

  function lintScript(kind, code) {
    var findings = [];
    var text = String(code || '');
    var masked = maskBlockComments(text);
    var lines = masked.split(/\r?\n/);

    function add(sev, rule, msg, line) { findings.push({ severity: sev, script: kind, rule: rule, line: line || null, message: msg }); }
    function scan(re, sev, rule, msg) {
      for (var i = 0; i < lines.length; i++) {
        var ln = lines[i];
        if (/^\s*#/.test(ln)) continue;
        if (re.test(ln)) add(sev, rule, msg, i + 1);
      }
    }

    if (Buffer_byteLength(text) > MAX_SCRIPT_BYTES) add('error', 'size', 'Script is larger than the 200 KB Intune limit.');

    scan(/\b(Read-Host|Out-GridView|Get-Credential|\$Host\.UI\.Prompt|\[Console\]::ReadKey|\[System\.Windows\.Forms\.MessageBox\]|\bpause\b)/i,
      'error', 'interactive', 'Interactive input or UI is not allowed in Remediations.');
    scan(/\b(Invoke-Expression|iex)\b/i, 'warning', 'invoke-expression', 'Avoid Invoke-Expression; it hides intent and is flagged by security tooling.');
    scan(/(DownloadString|DownloadFile|Invoke-WebRequest|Invoke-RestMethod|Start-BitsTransfer)[\s\S]*\b(iex|Invoke-Expression)\b/i,
      'error', 'remote-exec', 'Downloading and executing remote code is not allowed.');
    scan(/(password|passwd|pwd|secret|apikey|api_key|token)\s*=\s*['"][^'"\s]{4,}['"]/i,
      'error', 'hardcoded-secret', 'Possible hard-coded secret.');
    scan(/\b(Format-Volume|Clear-Disk|Remove-Partition|Initialize-Disk)\b/i, 'error', 'destructive-disk', 'Disk-destroying cmdlet detected.');
    scan(/Remove-Item[^\n]*-Recurse[^\n]*['"]?[A-Za-z]:\\['"]?\s*($|[-|;)])/i, 'error', 'destructive-delete', 'Recursive delete at a drive root.');
    scan(/Set-MpPreference[^\n]*-Disable\w+\s+\$true/i, 'error', 'disable-security', 'Disabling Defender protections is not allowed.');
    scan(/\b(Restart-Computer|Stop-Computer)\b|\bshutdown(\.exe)?\s+\//i, 'warning', 'reboot', 'Restarts or shutdowns should only happen if explicitly requested.');
    scan(/Start-Sleep\s+(-Seconds\s+)?([3-9]\d{2}|\d{4,})\b/i, 'warning', 'long-sleep', 'Long sleep; Remediations time out after 30 minutes.');
    scan(/\bWrite-Host\b/i, 'warning', 'write-host', 'Use Write-Output so the status line reaches the Intune portal reliably.');
    scan(/-Confirm\s*(:\s*\$true)?\b(?!\s*:\s*\$false)/i, 'warning', 'confirm-prompt', 'A -Confirm prompt would hang a non-interactive run.');

    var body = lines.filter(function (l) { return !/^\s*#/.test(l); }).join('\n');

    if (!/\bexit\s+\d+|\bexit\s+\$/i.test(body)) add('error', 'no-exit', 'No explicit exit code. Intune relies on exit codes.');
    if (!/\bWrite-Output\b/i.test(body)) add('warning', 'no-output', 'No Write-Output, so the portal will show no status text.');

    var exitCodes = [];
    var re = /\bexit\s+(\d+)/gi, m;
    while ((m = re.exec(body)) !== null) exitCodes.push(parseInt(m[1], 10));
    exitCodes.forEach(function (c) {
      if (c !== 0 && c !== 1) add('warning', 'exit-code', 'Exit code ' + c + ' used; Intune only distinguishes 0 (ok) and non-zero.');
    });

    if (kind === 'detection') {
      if (exitCodes.length && exitCodes.indexOf(0) < 0) add('error', 'detection-no-compliant-path', 'Detection never exits 0, so it can never report compliant.');
      if (exitCodes.length && exitCodes.indexOf(1) < 0) add('error', 'detection-no-issue-path', 'Detection never exits 1, so remediation can never run.');
      scan(/\b(Set-ItemProperty|New-ItemProperty|Remove-ItemProperty|Remove-Item|New-Item|Set-Service|Stop-Service|Start-Service|Set-Content|Add-Content|Out-File|Stop-Process|Start-Process|Install-\w+|Uninstall-\w+|Set-MpPreference|Enable-\w+|Disable-\w+)\b/i,
        'warning', 'detection-writes', 'Detection should be read-only; this looks like it changes state.');
    }

    if (kind === 'remediation') {
      if (!/\btry\s*\{/i.test(body)) add('warning', 'no-try-catch', 'No try/catch around changes; failures may go unreported.');
      if (exitCodes.length && exitCodes.indexOf(0) < 0) add('warning', 'remediation-no-success-path', 'Remediation never exits 0.');
    }

    return findings;
  }

  function Buffer_byteLength(s) {
    if (typeof Buffer !== 'undefined') return Buffer.byteLength(s, 'utf8');
    return new Blob([s]).size;
  }

  function lintBundle(bundle) {
    return lintScript('detection', bundle.detection).concat(lintScript('remediation', bundle.remediation));
  }

  function hasErrors(findings) {
    return findings.some(function (f) { return f.severity === 'error'; });
  }

  // ---------------------------------------------------------------------------
  // Claude API
  // ---------------------------------------------------------------------------

  function callClaude(o) {
    var f = o.fetchImpl || (typeof fetch !== 'undefined' ? fetch.bind(globalThis) : null);
    if (!f) return Promise.reject(new Error('fetch is not available.'));
    if (!o.apiKey) return Promise.reject(new Error('Enter your Anthropic API key first.'));
    var body = {
      model: o.model,
      max_tokens: o.maxTokens || 8000,
      system: o.system,
      messages: [{ role: 'user', content: o.user }]
    };
    return f(API_URL, {
      method: 'POST',
      headers: {
        'content-type': 'application/json',
        'x-api-key': o.apiKey,
        'anthropic-version': API_VERSION,
        'anthropic-dangerous-direct-browser-access': 'true'
      },
      body: JSON.stringify(body),
      signal: o.signal
    }).then(function (res) {
      return res.text().then(function (txt) {
        var data;
        try { data = JSON.parse(txt); } catch (e) { data = null; }
        if (!res.ok) {
          var msg = (data && data.error && data.error.message) || txt.slice(0, 300) || ('HTTP ' + res.status);
          throw new Error('Claude API error (' + res.status + '): ' + msg);
        }
        if (!data || !Array.isArray(data.content)) throw new Error('Unexpected API response.');
        if (data.stop_reason === 'max_tokens') throw new Error('Claude hit the output limit before finishing. Shorten the request and try again.');
        return data.content.filter(function (b) { return b.type === 'text'; }).map(function (b) { return b.text; }).join('');
      });
    });
  }

  // ---------------------------------------------------------------------------
  // Pipeline
  // ---------------------------------------------------------------------------

  function runPipeline(o) {
    var input = String(o.input || '').trim();
    if (!input) return Promise.reject(new Error('Describe what you want to detect and remediate.'));
    var maxRounds = typeof o.maxFixRounds === 'number' ? o.maxFixRounds : 2;
    var progress = o.onProgress || function () {};
    var claude = function (system, user) {
      return callClaude({ apiKey: o.apiKey, model: o.model, system: system, user: user, fetchImpl: o.fetchImpl, signal: o.signal, maxTokens: o.maxTokens });
    };
    var history = [];

    progress({ step: 'generate', message: 'Generating detection and remediation scripts...' });
    return claude(GENERATE_SYSTEM, buildGeneratePrompt(input, o.options)).then(function (txt) {
      var bundle = normaliseBundle(extractJson(txt));
      return loop(bundle, 0);
    });

    function loop(bundle, round) {
      var lint = lintBundle(bundle);
      progress({ step: 'lint', round: round, message: 'Static checks: ' + countBy(lint, 'error') + ' error(s), ' + countBy(lint, 'warning') + ' warning(s).', findings: lint });
      progress({ step: 'test', round: round, message: 'Virtual test ' + (round ? '(re-test ' + round + ')' : '') + ' running scenarios...' });
      return claude(TEST_SYSTEM, buildTestPrompt(bundle, o.options)).then(function (txt) {
        var report = normaliseTestReport(extractJson(txt));
        history.push({ round: round, lint: lint, report: report });
        var ok = report.verdict === 'pass' && !hasErrors(lint);
        progress({ step: 'result', round: round, message: ok ? 'All scenarios passed.' : 'Issues found.', report: report });
        if (ok || round >= maxRounds) {
          return { bundle: bundle, lint: lint, report: report, passed: ok, rounds: round, history: history };
        }
        progress({ step: 'fix', round: round + 1, message: 'Fixing issues (round ' + (round + 1) + ' of ' + maxRounds + ')...' });
        return claude(FIX_SYSTEM, buildFixPrompt(bundle, lint, report, input)).then(function (fixTxt) {
          var fixed = normaliseBundle(extractJson(fixTxt));
          return loop(fixed, round + 1);
        });
      });
    }
  }

  function countBy(findings, sev) {
    return findings.filter(function (f) { return f.severity === sev; }).length;
  }

  function safeFileName(title) {
    return String(title || 'remediation').toLowerCase().replace(/[^a-z0-9]+/g, '-').replace(/^-+|-+$/g, '').slice(0, 60) || 'remediation';
  }

  return {
    API_URL: API_URL,
    GENERATE_SYSTEM: GENERATE_SYSTEM,
    TEST_SYSTEM: TEST_SYSTEM,
    FIX_SYSTEM: FIX_SYSTEM,
    buildGeneratePrompt: buildGeneratePrompt,
    buildTestPrompt: buildTestPrompt,
    buildFixPrompt: buildFixPrompt,
    extractJson: extractJson,
    normaliseBundle: normaliseBundle,
    normaliseTestReport: normaliseTestReport,
    lintScript: lintScript,
    lintBundle: lintBundle,
    hasErrors: hasErrors,
    callClaude: callClaude,
    runPipeline: runPipeline,
    safeFileName: safeFileName
  };
});
