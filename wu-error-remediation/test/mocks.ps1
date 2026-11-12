# Test harness: stands in for the Windows-only commands the generated scripts call,
# so the scripts can run under PowerShell 7 on any OS. Scenario comes from $env:WU_SCENARIO.
# Used by test/scripts.test.js; never deployed.

$root = $env:WU_TEST_ROOT
$env:SystemRoot  = Join-Path $root 'Windows'
$env:ProgramData = Join-Path $root 'ProgramData'
$global:Calls = New-Object System.Collections.Generic.List[string]
$global:LASTEXITCODE = 0

$scenario = $env:WU_SCENARIO
$global:Svc = @{}
foreach ($n in 'wuauserv', 'BITS', 'CryptSvc', 'UsoSvc', 'TrustedInstaller', 'msiserver') {
    $global:Svc[$n] = @{ Status = 'Running'; StartType = 'Manual' }
}
$global:Reg = @{}
$global:History = @()
$global:Image = 'Healthy'

$wuKey = 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\WindowsUpdate'
$auKey = 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\WindowsUpdate\AU'
switch -Wildcard ($scenario) {
    '*svc-disabled*'  { $global:Svc['wuauserv'] = @{ Status = 'Stopped'; StartType = 'Disabled' } }
    '*wsus*'          { $global:Reg[$wuKey] = @{ WUServer = 'http://wsus.contoso.local:8530'; DisableWindowsUpdateAccess = 1 }; $global:Reg[$auKey] = @{ UseWUServer = 1 } }
    '*configmgr*'     { $global:Svc['CcmExec'] = @{ Status = 'Running'; StartType = 'Automatic' } }
    '*reboot*'        { $global:Reg['HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\WindowsUpdate\Auto Update\RebootRequired'] = @{} }
    '*image-bad*'     { $global:Image = 'Repairable' }
    '*history-old*'   { $global:History = @([pscustomobject]@{ Date = (Get-Date).ToUniversalTime().AddDays(-30); HResult = [Convert]::ToInt32('80246009', 16); UnmappedResultCode = 0 }) }
    '*history-new*'   { $global:History = @([pscustomobject]@{ Date = (Get-Date).ToUniversalTime().AddHours(-2); HResult = [Convert]::ToInt32('80246009', 16); UnmappedResultCode = 0 }) }
}
if ($env:WU_MARKER) { $global:Reg['HKLM:\SOFTWARE\IntuneTools\WUErrorRemediation\' + $env:WU_PACKAGE] = @{ LastRemediatedUtc = $env:WU_MARKER } }

foreach ($d in @((Join-Path $env:SystemRoot 'SoftwareDistribution'), (Join-Path $env:SystemRoot 'System32\catroot2'), (Join-Path $env:SystemRoot 'System32'))) {
    if (-not (Microsoft.PowerShell.Management\Test-Path $d)) { Microsoft.PowerShell.Management\New-Item -ItemType Directory -Path $d -Force | Out-Null }
}

function Get-Service { param([string]$Name, $ErrorAction)
    $s = $global:Svc[$Name]; if ($null -eq $s) { return $null }
    $o = [pscustomobject]@{ Name = $Name; Status = $s.Status; StartType = $s.StartType }
    $o | Add-Member -MemberType ScriptMethod -Name WaitForStatus -Value { param($a, $b) }
    return $o }
function Set-Service { param([string]$Name, [string]$StartupType) $global:Svc[$Name].StartType = $StartupType; $global:Calls.Add("Set-Service $Name $StartupType") }
function Start-Service { param([string]$Name, $ErrorAction) $global:Svc[$Name].Status = 'Running'; $global:Calls.Add("Start-Service $Name") }
function Stop-Service { param([string]$Name, [switch]$Force, $ErrorAction) $global:Svc[$Name].Status = 'Stopped'; $global:Calls.Add("Stop-Service $Name") }
function Restart-Service { param([string]$Name, [switch]$Force, $ErrorAction) $global:Calls.Add("Restart-Service $Name") }

function Test-Path { param([Parameter(Position = 0)][string]$Path)
    if ($Path -like 'HKLM:*') { return $global:Reg.ContainsKey($Path) }
    return Microsoft.PowerShell.Management\Test-Path $Path }
function Get-ItemProperty { param([string]$Path, [string]$Name, $ErrorAction)
    $k = $global:Reg[$Path]; if ($null -eq $k -or -not $k.ContainsKey($Name)) { return $null }
    return [pscustomobject]@{ $Name = $k[$Name] } }
function Set-ItemProperty { param([string]$Path, [string]$Name, $Value) $global:Reg[$Path][$Name] = $Value; $global:Calls.Add("Set-ItemProperty $Name") }
function Remove-ItemProperty { param([string]$Path, [string]$Name, [switch]$Force) $global:Reg[$Path].Remove($Name); $global:Calls.Add("Remove-ItemProperty $Name") }
function New-Item { param([string]$Path, [string]$ItemType, [switch]$Force)
    if ($Path -like 'HKLM:*') { $global:Reg[$Path] = @{}; return }
    Microsoft.PowerShell.Management\New-Item -Path $Path -ItemType $ItemType -Force:$Force }

function New-Object { param([string]$TypeName, [string]$ComObject)
    if ($ComObject -eq 'Microsoft.Update.Session') {
        $searcher = [pscustomobject]@{}
        $searcher | Add-Member ScriptMethod GetTotalHistoryCount { $global:History.Count }
        $searcher | Add-Member ScriptMethod QueryHistory { param($s, $c) $global:History }
        $session = [pscustomobject]@{ Searcher = $searcher }
        $session | Add-Member ScriptMethod CreateUpdateSearcher { $this.Searcher }
        return $session }
    if ($ComObject -eq 'Microsoft.Update.AutoUpdate') {
        $au = [pscustomobject]@{}; $au | Add-Member ScriptMethod DetectNow { $global:Calls.Add('DetectNow') }; return $au }
    return Microsoft.PowerShell.Utility\New-Object -TypeName $TypeName }
function Get-WinEvent { param($FilterHashtable, $ErrorAction) return @() }
function Repair-WindowsImage { param([switch]$Online, [switch]$CheckHealth, $ErrorAction) [pscustomobject]@{ ImageHealthState = $global:Image } }
function Start-Process { param([string]$FilePath, $ArgumentList, [switch]$Wait, [switch]$PassThru, $WindowStyle)
    $global:Calls.Add('Start-Process ' + (Split-Path $FilePath -Leaf)); [pscustomobject]@{ ExitCode = 0 } }
function Clear-DnsClientCache { param($ErrorAction) $global:Calls.Add('Clear-DnsClientCache') }
function Import-Module { param([string]$Name, $ErrorAction) }
function Get-BitsTransfer { param([switch]$AllUsers, $ErrorAction) @([pscustomobject]@{ DisplayName = 'WU Client Download'; JobState = 'Error' }, [pscustomobject]@{ DisplayName = 'Other'; JobState = 'Transferring' }) }
function Remove-BitsTransfer { param($ErrorAction) process { $global:Calls.Add('Remove-BitsTransfer ' + $_.DisplayName) } }
function reg.exe { $global:Calls.Add('reg export'); $global:LASTEXITCODE = 0 }
function netsh.exe { $global:Calls.Add('netsh ' + ($args -join ' ')); $global:LASTEXITCODE = 0 }
function shutdown.exe { $global:Calls.Add('shutdown ' + ($args[0..2] -join ' ')); $global:LASTEXITCODE = 0 }

