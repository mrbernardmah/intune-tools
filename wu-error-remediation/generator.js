/*
 * Windows Update error -> Intune Remediation script generator.
 * Pure functions, no dependencies. Works in the browser (window.WUGen) and in Node (require).
 *
 * The generated scripts are Windows PowerShell 5.1 compatible, ASCII only, and follow the
 * Intune Remediations contract: detection is read-only and exits 1 when a fix is needed,
 * remediation is idempotent, and each script writes one status line.
 */
(function (root) {
  'use strict';

  const PLAYBOOKS = {
    policy: {
      title: 'Clear blocking Windows Update policy',
      summary: 'Removes leftover WSUS server settings and policies that block access to Windows Update, after exporting a .reg backup.',
      risk: 'Group Policy re-applies these values if the GPO is still linked. Do not assign to devices that should scan WSUS or Configuration Manager.'
    },
    services: {
      title: 'Repair update services',
      summary: 'Re-enables and starts wuauserv, BITS, CryptSvc, UsoSvc, TrustedInstaller and msiserver when they are disabled or stopped.',
      risk: 'Overrides any deliberate service hardening that disables these services.'
    },
    bits: {
      title: 'Clear failed BITS jobs',
      summary: 'Removes BITS jobs stuck in an error state for all users, then restarts BITS.',
      risk: 'Only jobs already in Error or TransientError are removed.'
    },
    reset: {
      title: 'Reset Windows Update components',
      summary: 'Stops the update services, renames SoftwareDistribution (and optionally catroot2) to a dated backup, removes older backups and starts the services again.',
      risk: 'The local update history list in Settings is cleared. Updates are downloaded again.'
    },
    network: {
      title: 'Network and endpoint check',
      summary: 'Flushes the DNS cache, optionally resets the WinHTTP proxy, and tests the Windows Update or WSUS endpoints. Results go into the status line.',
      risk: 'Cannot fix firewall or proxy rules; it reports which endpoints fail so you can.'
    },
    repair: {
      title: 'Repair the component store',
      summary: 'Runs DISM /RestoreHealth and, optionally, sfc /scannow.',
      risk: 'Can take 15-45 minutes. Intune stops a remediation after 60 minutes.'
    },
    reboot: {
      title: 'Handle a pending restart',
      summary: 'Detects a pending restart. If enabled, schedules one with a warning to the signed-in user.',
      risk: 'With restart scheduling off, the remediation only reports the pending restart.'
    },
    info: {
      title: 'Informational',
      summary: 'This code describes a normal or transient state; no device-side fix is expected.',
      risk: ''
    }
  };

  const PLAYBOOK_ORDER = ['policy', 'services', 'bits', 'reset', 'network', 'repair', 'scan', 'reboot'];

  const DEFAULTS = {
    org: 'IntuneTools',
    lookbackDays: 7,
    triggerMode: 'either',          // 'error' | 'state' | 'either'
    resetCatroot2: true,
    resetWinHttpProxy: false,
    policyRemoveWsus: true,
    policyRemoveBlocks: true,
    skipIfConfigMgr: true,
    runSfc: true,
    checkImageHealth: true,
    scheduleRestart: false,
    restartMinutes: 240,
    triggerScan: true,
    playbooks: null                  // null = derive from codes
  };

  function normalizeCode(input) {
    if (input == null) return null;
    let s = String(input).trim().toUpperCase().replace(/^0X/, '').replace(/^X/, '');
    if (/^-\d+$/.test(String(input).trim())) {
      // Decimal HRESULT such as -2147023838
      const n = (Number(String(input).trim()) >>> 0).toString(16).toUpperCase();
      s = n;
    }
    if (!/^[0-9A-F]{1,8}$/.test(s)) return null;
    return '0x' + s.padStart(8, '0');
  }

  function playbooksFor(codes, data) {
    const set = new Set();
    for (const c of codes) {
      const e = data.BY_CODE[c];
      if (!e) continue;
      for (const p of e.playbooks) set.add(p);
    }
    return PLAYBOOK_ORDER.concat(['info']).filter(p => set.has(p));
  }

  function resolve(codes, options, data) {
    const opts = Object.assign({}, DEFAULTS, options || {});
    const clean = [];
    for (const c of codes || []) {
      const n = normalizeCode(c);
      if (n && !clean.includes(n)) clean.push(n);
    }
    if (!clean.length) throw new Error('Select at least one error code.');
    opts.org = String(opts.org || DEFAULTS.org).replace(/[^A-Za-z0-9_-]/g, '') || DEFAULTS.org;
    opts.lookbackDays = clampInt(opts.lookbackDays, 1, 90, DEFAULTS.lookbackDays);
    opts.restartMinutes = clampInt(opts.restartMinutes, 5, 1440, DEFAULTS.restartMinutes);
    if (!['error', 'state', 'either'].includes(opts.triggerMode)) opts.triggerMode = DEFAULTS.triggerMode;

    let pbs = Array.isArray(opts.playbooks) ? opts.playbooks.slice() : playbooksFor(clean, data);
    pbs = PLAYBOOK_ORDER.filter(p => p !== 'scan' && pbs.includes(p));
    const id = clean.length === 1 ? clean[0] : clean[0] + '-plus' + (clean.length - 1);
    return { codes: clean, opts, playbooks: pbs, id };
  }

  function clampInt(v, min, max, dflt) {
    const n = parseInt(v, 10);
    if (!Number.isFinite(n)) return dflt;
    return Math.min(max, Math.max(min, n));
  }

  function psStr(s) { return "'" + String(s).replace(/'/g, "''") + "'"; }
  function psArr(a) { return '@(' + a.map(psStr).join(', ') + ')'; }
  function psBool(b) { return b ? '$true' : '$false'; }

  function describeCodes(codes, data) {
    return codes.map(c => {
      const e = data.BY_CODE[c];
      return '#   ' + c + (e ? '  ' + (e.name || '(no symbolic name)') + ' - ' + e.desc : '  (not in the Microsoft reference)');
    }).join('\n');
  }

  function header(kind, r, data, generatedOn) {
    const pbNames = r.playbooks.length ? r.playbooks.map(p => PLAYBOOKS[p].title).join('; ') : 'none (informational codes only)';
    return [
      '<#',
      '.SYNOPSIS',
      '    Intune Remediation ' + kind + ' script for Windows Update error(s): ' + r.codes.join(', '),
      '.DESCRIPTION',
      '    Generated by the Windows Update Error Remediation Builder (intune-tools) on ' + generatedOn + '.',
      '    Error reference: ' + data.SOURCE_URL,
      '    Fix playbooks: ' + pbNames,
      '',
      '    Intune settings: Run this script using the logged-on credentials = No (runs as SYSTEM),',
      '    Enforce script signature check = No (unless you sign it), Run script in 64-bit PowerShell = Yes.',
      '.NOTES',
      '    Codes covered:',
      describeCodes(r.codes, data).replace(/^#/gm, ''),
      '#>',
      ''
    ].join('\n');
  }

  // ---------------------------------------------------------------- shared PowerShell blocks

  function commonBlock(r) {
    const o = r.opts;
    return [
      "$ErrorActionPreference = 'Stop'",
      '$Codes        = ' + psArr(r.codes),
      '$PackageId    = ' + psStr(r.id),
      '$MarkerKey    = ' + psStr('HKLM:\\SOFTWARE\\' + o.org + '\\WUErrorRemediation\\' + r.id),
      '$LogDir       = Join-Path $env:ProgramData ' + psStr(o.org + '\\Logs'),
      '$WuPolicyKey  = ' + psStr('HKLM:\\SOFTWARE\\Policies\\Microsoft\\Windows\\WindowsUpdate'),
      '$AuPolicyKey  = ' + psStr('HKLM:\\SOFTWARE\\Policies\\Microsoft\\Windows\\WindowsUpdate\\AU'),
      '$WsusValues   = ' + (o.policyRemoveWsus ? "@(@{ K = $WuPolicyKey; N = 'WUServer' }, @{ K = $WuPolicyKey; N = 'WUStatusServer' }, @{ K = $WuPolicyKey; N = 'UpdateServiceUrlAlternate' }, @{ K = $AuPolicyKey; N = 'UseWUServer' })" : '@()'),
      '$BlockValues  = ' + (o.policyRemoveBlocks ? "@(@{ K = $WuPolicyKey; N = 'DisableWindowsUpdateAccess' }, @{ K = $WuPolicyKey; N = 'DoNotConnectToWindowsUpdateInternetLocations' }, @{ K = $WuPolicyKey; N = 'SetDisableUXWUAccess' }, @{ K = $AuPolicyKey; N = 'NoAutoUpdate' })" : '@()'),
      '$SkipIfConfigMgr = ' + psBool(o.skipIfConfigMgr),
      '$UpdateServices = @(',
      "    @{ Name = 'wuauserv';         StartType = 'Manual' },",
      "    @{ Name = 'BITS';             StartType = 'Manual' },",
      "    @{ Name = 'CryptSvc';         StartType = 'Automatic' },",
      "    @{ Name = 'UsoSvc';           StartType = 'Automatic' },",
      "    @{ Name = 'TrustedInstaller'; StartType = 'Manual' },",
      "    @{ Name = 'msiserver';        StartType = 'Manual' }",
      ')',
      '',
      'function Get-PolicyValue {',
      '    param([string]$Key, [string]$Name)',
      '    $item = Get-ItemProperty -Path $Key -Name $Name -ErrorAction SilentlyContinue',
      '    if ($null -eq $item) { return $null }',
      '    return $item.$Name',
      '}',
      '',
      'function Test-ConfigMgrClient {',
      "    return [bool](Get-Service -Name 'CcmExec' -ErrorAction SilentlyContinue)",
      '}',
      '',
      'function Get-BlockingPolicy {',
      '    $found = New-Object System.Collections.Generic.List[string]',
      '    $pairs = @()',
      '    if (-not ($SkipIfConfigMgr -and (Test-ConfigMgrClient))) { $pairs += $WsusValues }',
      '    $pairs += $BlockValues',
      '    foreach ($p in $pairs) {',
      '        $v = Get-PolicyValue -Key $p.K -Name $p.N',
      "        if ($null -ne $v -and ([string]$v) -ne '' -and ([string]$v) -ne '0') { $found.Add($p.N + '=' + $v) }",
      '    }',
      '    return ,$found',
      '}',
      '',
      'function Test-PendingReboot {',
      '    $reasons = New-Object System.Collections.Generic.List[string]',
      "    if (Test-Path 'HKLM:\\SOFTWARE\\Microsoft\\Windows\\CurrentVersion\\Component Based Servicing\\RebootPending') { $reasons.Add('CBS') }",
      "    if (Test-Path 'HKLM:\\SOFTWARE\\Microsoft\\Windows\\CurrentVersion\\WindowsUpdate\\Auto Update\\RebootRequired') { $reasons.Add('WindowsUpdate') }",
      '    return ,$reasons',
      '}',
      '',
      'function Get-ServiceProblems {',
      '    $problems = New-Object System.Collections.Generic.List[string]',
      '    foreach ($s in $UpdateServices) {',
      '        $svc = Get-Service -Name $s.Name -ErrorAction SilentlyContinue',
      '        if ($null -eq $svc) { continue }',
      "        if ($svc.StartType -eq 'Disabled') { $problems.Add($s.Name + ' disabled') }",
      '    }',
      '    return ,$problems',
      '}',
      ''
    ].join('\n');
  }

  // ---------------------------------------------------------------- detection

  function detectionScript(codes, options, data, generatedOn) {
    const r = resolve(codes, options, data);
    const o = r.opts;
    const pb = new Set(r.playbooks);
    const date = generatedOn || new Date().toISOString().slice(0, 10);

    const stateChecks = [];
    if (pb.has('services')) stateChecks.push(
      '    foreach ($p in (Get-ServiceProblems)) { $state.Add($p) }');
    if (pb.has('policy')) stateChecks.push(
      "    foreach ($p in (Get-BlockingPolicy)) { $state.Add('policy ' + $p) }");
    if (pb.has('reboot')) stateChecks.push(
      '    $pending = Test-PendingReboot',
      "    if ($pending.Count -gt 0) { $state.Add('restart pending (' + ($pending -join '+') + ')') }");
    if (pb.has('repair') && o.checkImageHealth) stateChecks.push(
      '    try {',
      '        $img = Repair-WindowsImage -Online -CheckHealth -ErrorAction Stop',
      "        if ([string]$img.ImageHealthState -ne 'Healthy') { $state.Add('image ' + $img.ImageHealthState) }",
      "    } catch { $notes.Add('image check skipped') }");

    const lines = [
      header('detection', r, data, date),
      commonBlock(r),
      '$LookbackDays = ' + o.lookbackDays,
      '$TriggerMode  = ' + psStr(o.triggerMode) + "   # 'error' = only recent occurrences, 'state' = only device state, 'either'",
      '',
      'function Get-Since {',
      '    $since = (Get-Date).ToUniversalTime().AddDays(-$LookbackDays)',
      "    $last = Get-PolicyValue -Key $MarkerKey -Name 'LastRemediatedUtc'",
      '    if ($last) {',
      '        $parsed = [datetime]::MinValue',
      "        if ([datetime]::TryParse($last, [Globalization.CultureInfo]::InvariantCulture, [Globalization.DateTimeStyles]::AdjustToUniversal -bor [Globalization.DateTimeStyles]::AssumeUniversal, [ref]$parsed)) {",
      '            if ($parsed -gt $since) { $since = $parsed }',
      '        }',
      '    }',
      '    return $since',
      '}',
      '',
      'function Get-ErrorOccurrences {',
      '    param([datetime]$SinceUtc)',
      '    $hits = @{}',
      '    foreach ($c in $Codes) { $hits[$c] = 0 }',
      '',
      '    # 1. Windows Update Agent history (install, uninstall and scan results with an HRESULT)',
      '    try {',
      '        $session  = New-Object -ComObject Microsoft.Update.Session',
      '        $searcher = $session.CreateUpdateSearcher()',
      '        $total    = $searcher.GetTotalHistoryCount()',
      '        if ($total -gt 0) {',
      '            foreach ($h in $searcher.QueryHistory(0, [Math]::Min($total, 300))) {',
      '                if ($h.Date -lt $SinceUtc) { continue }',
      "                foreach ($val in @($h.HResult, $h.UnmappedResultCode)) {",
      "                    $hex = '0x{0:X8}' -f [int]$val",
      '                    if ($hits.ContainsKey($hex)) { $hits[$hex]++ }',
      '                }',
      '            }',
      '        }',
      '    } catch { $notes.Add(\'history unavailable\') }',
      '',
      '    # 2. WindowsUpdateClient operational log (errors and warnings)',
      '    try {',
      "        $filter = @{ LogName = 'Microsoft-Windows-WindowsUpdateClient/Operational'; StartTime = $SinceUtc.ToLocalTime(); Level = 2, 3 }",
      '        $events = Get-WinEvent -FilterHashtable $filter -ErrorAction Stop',
      '        foreach ($e in $events) {',
      '            $msg = [string]$e.Message',
      '            foreach ($c in $Codes) {',
      '                if ($msg.IndexOf($c, [StringComparison]::OrdinalIgnoreCase) -ge 0) { $hits[$c]++ }',
      '            }',
      '        }',
      '    } catch {',
      "        if ($_.FullyQualifiedErrorId -notmatch 'NoMatchingEventsFound') { $notes.Add('event log unavailable') }",
      '    }',
      '    return $hits',
      '}',
      '',
      '$notes = New-Object System.Collections.Generic.List[string]',
      '$state = New-Object System.Collections.Generic.List[string]',
      'try {',
      '    $since = Get-Since',
      '    $hits  = Get-ErrorOccurrences -SinceUtc $since',
      "    $seen  = @($Codes | Where-Object { $hits[$_] -gt 0 } | ForEach-Object { $_ + ' x' + $hits[$_] })",
      '',
      stateChecks.length ? '    # Device state that causes these errors' : '    # No state checks apply to the selected codes',
      ...stateChecks,
      '',
      "    $errorTrigger = ($seen.Count -gt 0) -and ($TriggerMode -ne 'state')",
      "    $stateTrigger = ($state.Count -gt 0) -and ($TriggerMode -ne 'error')",
      "    $sinceText = $since.ToString('yyyy-MM-dd HH:mm') + 'Z'",
      '',
      '    $parts = New-Object System.Collections.Generic.List[string]',
      "    if ($seen.Count -gt 0) { $parts.Add('seen ' + ($seen -join ', ') + ' since ' + $sinceText) }",
      "    if ($state.Count -gt 0) { $parts.Add('state: ' + ($state -join ', ')) }",
      "    if ($notes.Count -gt 0) { $parts.Add('notes: ' + ($notes -join ', ')) }",
      '',
      '    if ($errorTrigger -or $stateTrigger) {',
      "        $line = 'NonCompliant [' + $PackageId + ']: ' + ($parts -join '; ')",
      "        if ($line.Length -gt 2000) { $line = $line.Substring(0, 2000) }",
      '        Write-Output $line',
      '        exit 1',
      '    }',
      "    $line = 'Compliant [' + $PackageId + ']: none of ' + ($Codes -join ', ') + ' since ' + $sinceText",
      "    if ($parts.Count -gt 0) { $line += '; ' + ($parts -join '; ') }",
      "    if ($line.Length -gt 2000) { $line = $line.Substring(0, 2000) }",
      '    Write-Output $line',
      '    exit 0',
      '} catch {',
      "    Write-Output ('DetectionError [' + $PackageId + ']: ' + $_.Exception.Message)",
      '    exit 1',
      '}',
      ''
    ];
    return lines.join('\n');
  }

  // ---------------------------------------------------------------- remediation

  function remediationScript(codes, options, data, generatedOn) {
    const r = resolve(codes, options, data);
    const o = r.opts;
    const pb = new Set(r.playbooks);
    const date = generatedOn || new Date().toISOString().slice(0, 10);
    const steps = [];

    if (pb.has('policy')) steps.push([
      "Invoke-Step 'policy' {",
      '    $removed = New-Object System.Collections.Generic.List[string]',
      '    $pairs = @()',
      '    if ($SkipIfConfigMgr -and (Test-ConfigMgrClient)) {',
      "        Write-Log 'Configuration Manager client found; WSUS server values left in place'",
      '    } else { $pairs += $WsusValues }',
      '    $pairs += $BlockValues',
      '    $present = @($pairs | Where-Object { $null -ne (Get-PolicyValue -Key $_.K -Name $_.N) })',
      "    if ($present.Count -eq 0) { return 'nothing to remove' }",
      "    $backup = Join-Path $LogDir ('WUPolicy-backup-' + (Get-Date -Format 'yyyyMMddHHmmss') + '.reg')",
      "    & reg.exe export 'HKLM\\SOFTWARE\\Policies\\Microsoft\\Windows\\WindowsUpdate' $backup /y | Out-Null",
      '    foreach ($p in $present) {',
      '        Remove-ItemProperty -Path $p.K -Name $p.N -Force',
      '        $removed.Add($p.N)',
      "        Write-Log ('Removed ' + $p.K + '\\' + $p.N)",
      '    }',
      "    Restart-Service -Name 'wuauserv' -Force -ErrorAction SilentlyContinue",
      "    return 'removed ' + ($removed -join ',') + ' (backup ' + (Split-Path $backup -Leaf) + ')'",
      '}'
    ].join('\n'));

    if (pb.has('services')) steps.push([
      "Invoke-Step 'services' {",
      '    $changed = New-Object System.Collections.Generic.List[string]',
      '    foreach ($s in $UpdateServices) {',
      '        $svc = Get-Service -Name $s.Name -ErrorAction SilentlyContinue',
      "        if ($null -eq $svc) { Write-Log ('Service not present: ' + $s.Name); continue }",
      "        if ($svc.StartType -eq 'Disabled') {",
      '            Set-Service -Name $s.Name -StartupType $s.StartType',
      "            $changed.Add($s.Name + '->' + $s.StartType)",
      "            Write-Log ('Set ' + $s.Name + ' start type to ' + $s.StartType)",
      '        }',
      '    }',
      "    foreach ($n in @('CryptSvc', 'BITS', 'wuauserv')) { Start-ServiceSafe $n }",
      "    if ($changed.Count -eq 0) { return 'services enabled; started' }",
      "    return 'enabled ' + ($changed -join ',') + '; started'",
      '}'
    ].join('\n'));

    if (pb.has('bits')) steps.push([
      "Invoke-Step 'bits' {",
      '    Import-Module BitsTransfer -ErrorAction Stop',
      "    $bad = @(Get-BitsTransfer -AllUsers -ErrorAction SilentlyContinue | Where-Object { $_.JobState -in @('Error', 'TransientError') })",
      '    foreach ($j in $bad) {',
      "        Write-Log ('Removing BITS job ' + $j.DisplayName + ' (' + $j.JobState + ')')",
      '        $j | Remove-BitsTransfer -ErrorAction SilentlyContinue',
      '    }',
      "    Restart-Service -Name 'BITS' -Force -ErrorAction SilentlyContinue",
      "    return 'removed ' + $bad.Count + ' failed job(s)'",
      '}'
    ].join('\n'));

    if (pb.has('reset')) steps.push([
      "Invoke-Step 'reset' {",
      "    $svcNames = @('wuauserv', 'UsoSvc', 'BITS', 'CryptSvc')",
      '    foreach ($n in $svcNames) { Stop-ServiceSafe $n }',
      "    $stamp = Get-Date -Format 'yyyyMMddHHmmss'",
      "    $targets = @(Join-Path $env:SystemRoot 'SoftwareDistribution')",
      o.resetCatroot2 ? "    $targets += (Join-Path $env:SystemRoot 'System32\\catroot2')" : '    # catroot2 reset disabled in the builder options',
      '    $done = New-Object System.Collections.Generic.List[string]',
      '    try {',
      '        foreach ($t in $targets) {',
      '            $parent = Split-Path $t -Parent',
      '            $leaf   = Split-Path $t -Leaf',
      "            Get-ChildItem -Path $parent -Directory -Filter ($leaf + '.bak-*') -ErrorAction SilentlyContinue |",
      '                Remove-Item -Recurse -Force -ErrorAction SilentlyContinue',
      '            if (Test-Path $t) {',
      "                $newName = $leaf + '.bak-' + $stamp",
      '                try { Rename-Item -Path $t -NewName $newName -Force }',
      '                catch { Start-Sleep -Seconds 5; Rename-Item -Path $t -NewName $newName -Force }',
      '                $done.Add($leaf)',
      "                Write-Log ('Renamed ' + $t + ' to ' + $newName)",
      '            }',
      '        }',
      '    } finally {',
      "        foreach ($n in @('CryptSvc', 'BITS', 'wuauserv', 'UsoSvc')) { Start-ServiceSafe $n }",
      '    }',
      "    return 'renamed ' + ($done -join ',')",
      '}'
    ].join('\n'));

    if (pb.has('network')) steps.push([
      "Invoke-Step 'network' {",
      '    Clear-DnsClientCache -ErrorAction SilentlyContinue',
      o.resetWinHttpProxy
        ? "    & netsh.exe winhttp reset proxy | Out-Null\n    Write-Log 'WinHTTP proxy reset to direct'"
        : '    # WinHTTP proxy left unchanged (enable the option in the builder to reset it)',
      "    $targets = @(@('sls.update.microsoft.com', 443), @('fe3cr.delivery.mp.microsoft.com', 443), @('dl.delivery.mp.microsoft.com', 443), @('download.windowsupdate.com', 80))",
      "    $wsus = Get-PolicyValue -Key $WuPolicyKey -Name 'WUServer'",
      "    $useWsus = Get-PolicyValue -Key $AuPolicyKey -Name 'UseWUServer'",
      "    if ($wsus -and ([string]$useWsus) -eq '1') {",
      '        try {',
      '            $u = [Uri]$wsus',
      '            $targets = @(@($u.Host, $u.Port))',
      '        } catch { }',
      '    }',
      '    $failed = New-Object System.Collections.Generic.List[string]',
      '    foreach ($t in $targets) {',
      '        $client = New-Object System.Net.Sockets.TcpClient',
      '        try {',
      '            $ar = $client.BeginConnect($t[0], [int]$t[1], $null, $null)',
      '            $ok = $ar.AsyncWaitHandle.WaitOne(4000) -and $client.Connected',
      "            if (-not $ok) { $failed.Add($t[0] + ':' + $t[1]) }",
      "        } catch { $failed.Add($t[0] + ':' + $t[1]) } finally { $client.Close() }",
      '    }',
      "    Restart-Service -Name 'wuauserv' -Force -ErrorAction SilentlyContinue",
      "    if ($failed.Count -gt 0) { $script:Warnings.Add('unreachable ' + ($failed -join ',')); return 'unreachable ' + ($failed -join ',') }",
      "    return 'endpoints reachable'",
      '}'
    ].join('\n'));

    if (pb.has('repair')) steps.push([
      "Invoke-Step 'repair' {",
      "    $dism = Start-Process -FilePath (Join-Path $env:SystemRoot 'System32\\dism.exe') -ArgumentList '/Online', '/Cleanup-Image', '/RestoreHealth', '/NoRestart' -Wait -PassThru -WindowStyle Hidden",
      "    Write-Log ('DISM exit code ' + $dism.ExitCode)",
      "    if ($dism.ExitCode -ne 0 -and $dism.ExitCode -ne 3010) { throw ('DISM RestoreHealth failed with exit code ' + $dism.ExitCode) }",
      "    $result = 'DISM ' + $dism.ExitCode",
      o.runSfc ? [
        "    $sfc = Start-Process -FilePath (Join-Path $env:SystemRoot 'System32\\sfc.exe') -ArgumentList '/scannow' -Wait -PassThru -WindowStyle Hidden",
        "    Write-Log ('SFC exit code ' + $sfc.ExitCode)",
        "    $result += ', SFC ' + $sfc.ExitCode"
      ].join('\n') : '    # sfc /scannow disabled in the builder options',
      '    return $result',
      '}'
    ].join('\n'));

    if (o.triggerScan) steps.push([
      "Invoke-Step 'scan' {",
      "    $uso = Join-Path $env:SystemRoot 'System32\\UsoClient.exe'",
      '    if (Test-Path $uso) {',
      "        Start-Process -FilePath $uso -ArgumentList 'StartScan' -WindowStyle Hidden",
      "        return 'scan started (UsoClient)'",
      '    }',
      '    (New-Object -ComObject Microsoft.Update.AutoUpdate).DetectNow()',
      "    return 'scan started (DetectNow)'",
      '}'
    ].join('\n'));

    if (pb.has('reboot')) steps.push([
      "Invoke-Step 'reboot' {",
      '    $pending = Test-PendingReboot',
      "    if ($pending.Count -eq 0) { return 'no restart pending' }",
      o.scheduleRestart ? [
        '    $seconds = ' + (o.restartMinutes * 60),
        "    $msg = 'Your IT team has scheduled a restart in " + o.restartMinutes + " minutes to finish installing Windows updates. Please save your work.'",
        "    & shutdown.exe /r /t $seconds /c $msg /d p:2:17 2>$null",
        "    if ($LASTEXITCODE -eq 1190) { return 'restart already scheduled' }",
        "    return 'restart scheduled in " + o.restartMinutes + " min (' + ($pending -join '+') + ')'"
      ].join('\n') : [
        "    $script:Warnings.Add('restart pending')",
        "    return 'restart pending (' + ($pending -join '+') + '); scheduling is off'"
      ].join('\n'),
      '}'
    ].join('\n'));

    const lines = [
      header('remediation', r, data, date),
      commonBlock(r),
      '$LogFile  = Join-Path $LogDir (\'WUErrorRemediation-\' + $PackageId + \'.log\')',
      '$Results  = New-Object System.Collections.Generic.List[string]',
      '$Warnings = New-Object System.Collections.Generic.List[string]',
      '$Failed   = $false',
      '',
      'function Write-Log {',
      '    param([string]$Message)',
      '    try {',
      '        if (-not (Test-Path $LogDir)) { New-Item -Path $LogDir -ItemType Directory -Force | Out-Null }',
      "        $stampText = (Get-Date).ToString('yyyy-MM-dd HH:mm:ss')",
      "        Add-Content -Path $LogFile -Value ($stampText + '  ' + $Message) -Encoding UTF8",
      '    } catch { }',
      '}',
      '',
      'function Invoke-Step {',
      '    param([string]$Name, [scriptblock]$Action)',
      "    Write-Log ('--- ' + $Name)",
      '    try {',
      '        $out = & $Action',
      "        $script:Results.Add($Name + ': ' + (@($out) -join ' '))",
      "        Write-Log ($Name + ' OK: ' + (@($out) -join ' '))",
      '    } catch {',
      '        $script:Failed = $true',
      "        $script:Results.Add($Name + ': FAILED ' + $_.Exception.Message)",
      "        Write-Log ($Name + ' FAILED: ' + $_.Exception.Message)",
      '    }',
      '}',
      '',
      'function Stop-ServiceSafe {',
      '    param([string]$Name)',
      '    $svc = Get-Service -Name $Name -ErrorAction SilentlyContinue',
      "    if ($null -eq $svc -or $svc.Status -eq 'Stopped') { return }",
      '    try {',
      '        Stop-Service -Name $Name -Force -ErrorAction Stop',
      "        $svc.WaitForStatus('Stopped', [TimeSpan]::FromSeconds(30))",
      "    } catch { Write-Log ('Could not stop ' + $Name + ': ' + $_.Exception.Message) }",
      '}',
      '',
      'function Start-ServiceSafe {',
      '    param([string]$Name)',
      '    $svc = Get-Service -Name $Name -ErrorAction SilentlyContinue',
      "    if ($null -eq $svc -or $svc.StartType -eq 'Disabled' -or $svc.Status -eq 'Running') { return }",
      "    try { Start-Service -Name $Name -ErrorAction Stop } catch { Write-Log ('Could not start ' + $Name + ': ' + $_.Exception.Message) }",
      '}',
      '',
      "Write-Log ('===== Remediation start for ' + ($Codes -join ', '))",
      '',
      r.playbooks.length || o.triggerScan ? '' : "Write-Log 'Informational codes only; nothing to change'",
      steps.join('\n\n'),
      '',
      '# Record the run so detection only counts errors that happen after this fix.',
      'if (-not $Failed) {',
      '    try {',
      '        if (-not (Test-Path $MarkerKey)) { New-Item -Path $MarkerKey -Force | Out-Null }',
      "        Set-ItemProperty -Path $MarkerKey -Name 'LastRemediatedUtc' -Value ((Get-Date).ToUniversalTime().ToString('o'))",
      "        Set-ItemProperty -Path $MarkerKey -Name 'Codes' -Value ($Codes -join ',')",
      "    } catch { Write-Log ('Could not write marker: ' + $_.Exception.Message) }",
      '}',
      '',
      "$status = 'Remediated'",
      "if ($Failed) { $status = 'RemediationFailed' } elseif ($Warnings.Count -gt 0) { $status = 'RemediatedWithWarnings' }",
      "if ($Results.Count -eq 0) { $Results.Add('informational codes only; no change made') }",
      "$line = $status + ' [' + $PackageId + ']: ' + ($Results -join '; ')",
      "if ($line.Length -gt 2000) { $line = $line.Substring(0, 2000) }",
      'Write-Log $line',
      'Write-Output $line',
      'if ($Failed) { exit 1 }',
      'exit 0',
      ''
    ];
    return lines.filter(l => l !== null).join('\n');
  }

  function fileNames(codes, options, data) {
    const r = resolve(codes, options, data);
    return {
      detection: 'Detect-WUError-' + r.id + '.ps1',
      remediation: 'Remediate-WUError-' + r.id + '.ps1',
      id: r.id
    };
  }

  function summarize(codes, options, data) {
    const r = resolve(codes, options, data);
    const unknown = r.codes.filter(c => !data.BY_CODE[c]);
    const infoOnly = r.playbooks.length === 0;
    return {
      id: r.id,
      codes: r.codes,
      unknown,
      infoOnly,
      playbooks: r.playbooks.map(p => Object.assign({ id: p }, PLAYBOOKS[p])),
      options: r.opts
    };
  }

  const api = { PLAYBOOKS, PLAYBOOK_ORDER, DEFAULTS, normalizeCode, playbooksFor, resolve,
    detectionScript, remediationScript, fileNames, summarize };
  if (typeof module === 'object' && module.exports) module.exports = api;
  else root.WUGen = api;
})(typeof self !== 'undefined' ? self : this);
