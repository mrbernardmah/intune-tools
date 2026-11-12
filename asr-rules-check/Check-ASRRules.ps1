<#
.TITLE
    Check ASR Rules

.SYNOPSIS
    Checks that every Microsoft Defender attack surface reduction (ASR) rule GUID is set to Audit or Block.

.DESCRIPTION
    Reads the effective ASR configuration from Microsoft Defender Antivirus (Get-MpPreference) and compares
    it with the list of ASR rule GUIDs published in the Microsoft Defender for Endpoint "ASR rules reference"
    (the page the Intune attack surface reduction documentation points to for rule details).

    For each rule the script reports one of:
      Compliant      - rule action is one of -AcceptedModes (default: Block, Audit)
      NonCompliant   - rule is Disabled, Not configured, Warn (unless accepted), or has an unexpected value
      Skipped        - rule excluded with -ExcludeRuleId, or an Exchange-server-only rule on a non-Exchange host

    The script also lists any configured GUIDs that are not in its rule table (for example a rule Microsoft
    added after this script was written), so they are visible rather than silently ignored.

    Because Get-MpPreference returns the merged result of Intune, Group Policy, Configuration Manager and local
    settings, this checks what is actually enforced on the device, not what a single policy says.

    Exit codes:
      0 - every checked rule is Compliant
      1 - at least one checked rule is NonCompliant
      2 - the check could not run (for example Defender is not available)
          With -Detection, errors also return 1 so Intune treats the device as non-compliant.

.PARAMETER AcceptedModes
    Rule actions treated as compliant. Valid values: Block, Audit, Warn. Default: Block, Audit.

.PARAMETER ExcludeRuleId
    One or more rule GUIDs to skip (for example, rules not supported on your OS versions).

.PARAMETER IncludeExchangeServerRule
    Also check "Block Webshell creation for Servers". That rule applies to Exchange servers only, so it is
    skipped by default.

.PARAMETER CsvPath
    Optional path to export the per-rule results as CSV.

.PARAMETER Detection
    Intune Remediations mode. Writes a single status line and exits 0 (compliant) or 1 (needs attention).

.PARAMETER PassThru
    Return the per-rule result objects to the pipeline.

.EXAMPLE
    .\Check-ASRRules.ps1

.EXAMPLE
    .\Check-ASRRules.ps1 -AcceptedModes Block

.EXAMPLE
    .\Check-ASRRules.ps1 -ExcludeRuleId 'c0033c00-d16d-4114-a5a0-dc9b3a7d2ceb' -CsvPath C:\Temp\asr.csv

.EXAMPLE
    .\Check-ASRRules.ps1 -Detection

.NOTES
    Source of rule names and GUIDs:
    https://learn.microsoft.com/en-us/defender-endpoint/attack-surface-reduction-rules-reference
    Related Intune documentation:
    https://learn.microsoft.com/en-us/intune/device-configuration/endpoint-security/attack-surface-reduction

    Requires Windows with Microsoft Defender Antivirus as the primary antivirus. Run elevated for best results.
#>

[CmdletBinding()]
param(
    [ValidateSet('Block', 'Audit', 'Warn')]
    [string[]]$AcceptedModes = @('Block', 'Audit'),

    [string[]]$ExcludeRuleId = @(),

    [switch]$IncludeExchangeServerRule,

    [string]$CsvPath,

    [switch]$Detection,

    [switch]$PassThru
)

# ---------------------------------------------------------------------------
# ASR rule table (source: Microsoft Defender for Endpoint ASR rules reference)
# Scope = 'Exchange' marks rules that only apply to Exchange servers.
# ---------------------------------------------------------------------------
$AsrRules = @(
    [pscustomobject]@{ Name = 'Block abuse of exploited vulnerable signed drivers (Device)';                                   Guid = '56a863a9-875e-4185-98a7-b882c64b5ce5'; Scope = 'All' }
    [pscustomobject]@{ Name = 'Block credential stealing from the Windows local security authority subsystem';                 Guid = '9e6c4e1f-7d60-472f-ba1a-a39ef669e4b2'; Scope = 'All' }
    [pscustomobject]@{ Name = 'Block persistence through WMI event subscription';                                              Guid = 'e6db77e5-3df2-4cf1-b95a-636979351e5b'; Scope = 'All' }
    [pscustomobject]@{ Name = 'Block Adobe Reader from creating child processes';                                              Guid = '7674ba52-37eb-4a4f-a9a1-f0f9a1619a2c'; Scope = 'All' }
    [pscustomobject]@{ Name = 'Block all Office applications from creating child processes';                                   Guid = 'd4f940ab-401b-4efc-aadc-ad5f3c50688a'; Scope = 'All' }
    [pscustomobject]@{ Name = 'Block executable content from email client and webmail';                                        Guid = 'be9ba2d9-53ea-4cdc-84e5-9b1eeee46550'; Scope = 'All' }
    [pscustomobject]@{ Name = 'Block executable files from running unless they meet a prevalence, age, or trusted list criterion'; Guid = '01443614-cd74-433a-b99e-2ecdc07bfc25'; Scope = 'All' }
    [pscustomobject]@{ Name = 'Block execution of potentially obfuscated scripts';                                             Guid = '5beb7efe-fd9a-4556-801d-275e5ffc04cc'; Scope = 'All' }
    [pscustomobject]@{ Name = 'Block JavaScript or VBScript from launching downloaded executable content';                     Guid = 'd3e037e1-3eb8-44c8-a917-57927947596d'; Scope = 'All' }
    [pscustomobject]@{ Name = 'Block Office applications from creating executable content';                                    Guid = '3b576869-a4ec-4529-8536-b80a7769e899'; Scope = 'All' }
    [pscustomobject]@{ Name = 'Block Office applications from injecting code into other processes';                            Guid = '75668c1f-73b5-4cf0-bb93-3ecf5cb7cc84'; Scope = 'All' }
    [pscustomobject]@{ Name = 'Block Office communication application from creating child processes';                           Guid = '26190899-1602-49e8-8b27-eb1d0a1ce869'; Scope = 'All' }
    [pscustomobject]@{ Name = 'Block process creations originating from PSExec and WMI commands';                              Guid = 'd1e49aac-8f56-4280-b9ba-993a6d77406c'; Scope = 'All' }
    [pscustomobject]@{ Name = 'Block rebooting machine in Safe Mode';                                                          Guid = '33ddedf1-c6e0-47cb-833e-de6133960387'; Scope = 'All' }
    [pscustomobject]@{ Name = 'Block untrusted and unsigned processes that run from USB';                                      Guid = 'b2b3f03d-6a65-4f7b-a9c7-1c7ef74a9ba4'; Scope = 'All' }
    [pscustomobject]@{ Name = 'Block use of copied or impersonated system tools';                                              Guid = 'c0033c00-d16d-4114-a5a0-dc9b3a7d2ceb'; Scope = 'All' }
    [pscustomobject]@{ Name = 'Block Webshell creation for Servers';                                                           Guid = 'a8f5898e-1dc8-49a9-9878-85004b8a61e6'; Scope = 'Exchange' }
    [pscustomobject]@{ Name = 'Block Win32 API calls from Office macros';                                                      Guid = '92e97fa1-2edf-4476-bdd6-9dd0b4dddc7b'; Scope = 'All' }
    [pscustomobject]@{ Name = 'Use advanced protection against ransomware';                                                    Guid = 'c1db55ab-c21a-4637-bb3f-a12568109d35'; Scope = 'All' }
)

# Action values used by Defender: 0 = Disabled / Not configured, 1 = Block, 2 = Audit, 6 = Warn
$ActionNames = @{ 0 = 'Disabled'; 1 = 'Block'; 2 = 'Audit'; 6 = 'Warn' }

function Exit-WithError {
    param([string]$Message)
    if ($Detection) {
        Write-Output "ASR check could not run: $Message"
        exit 1
    }
    Write-Error "ASR check could not run: $Message"
    exit 2
}

# ---------------------------------------------------------------------------
# Read the effective Defender configuration
# ---------------------------------------------------------------------------
if (-not (Get-Command -Name Get-MpPreference -ErrorAction SilentlyContinue)) {
    Exit-WithError 'Get-MpPreference is not available. This requires Windows with Microsoft Defender Antivirus.'
}

try {
    $pref = Get-MpPreference -ErrorAction Stop
}
catch {
    Exit-WithError $_.Exception.Message
}

$configured = @{}
$ids = @($pref.AttackSurfaceReductionRules_Ids)
$actions = @($pref.AttackSurfaceReductionRules_Actions)
for ($i = 0; $i -lt $ids.Count; $i++) {
    if ($ids[$i]) {
        $key = $ids[$i].ToString().Trim().ToLowerInvariant()
        $configured[$key] = [int]$actions[$i]
    }
}

$excluded = @($ExcludeRuleId | ForEach-Object { $_.ToString().Trim().ToLowerInvariant() })
$accepted = @($AcceptedModes)

# ---------------------------------------------------------------------------
# Evaluate each known rule
# ---------------------------------------------------------------------------
$results = foreach ($rule in $AsrRules) {
    $key = $rule.Guid.ToLowerInvariant()

    if ($excluded -contains $key) {
        $status = 'Skipped'; $state = 'Excluded by -ExcludeRuleId'
    }
    elseif ($rule.Scope -eq 'Exchange' -and -not $IncludeExchangeServerRule) {
        $status = 'Skipped'; $state = 'Exchange servers only (use -IncludeExchangeServerRule)'
    }
    else {
        if ($configured.ContainsKey($key)) {
            $value = $configured[$key]
            $state = if ($ActionNames.ContainsKey($value)) { $ActionNames[$value] } else { "Unknown ($value)" }
        }
        else {
            $state = 'Not configured'
        }
        $status = if ($accepted -contains $state) { 'Compliant' } else { 'NonCompliant' }
    }

    [pscustomobject]@{
        Status = $status
        State  = $state
        Rule   = $rule.Name
        Guid   = $rule.Guid
    }
}

# Configured GUIDs that this script does not know about
$knownGuids = @($AsrRules | ForEach-Object { $_.Guid.ToLowerInvariant() })
$unknown = @($configured.Keys | Where-Object { $knownGuids -notcontains $_ } | ForEach-Object {
        $value = $configured[$_]
        [pscustomobject]@{
            Guid  = $_
            State = if ($ActionNames.ContainsKey($value)) { $ActionNames[$value] } else { "Unknown ($value)" }
        }
    })

$checked = @($results | Where-Object { $_.Status -ne 'Skipped' })
$bad = @($checked | Where-Object { $_.Status -eq 'NonCompliant' })
$skipped = @($results | Where-Object { $_.Status -eq 'Skipped' })

if ($CsvPath) {
    try {
        $results | Export-Csv -Path $CsvPath -NoTypeInformation -Encoding UTF8 -ErrorAction Stop
    }
    catch {
        Write-Warning "Could not write CSV to '$CsvPath': $($_.Exception.Message)"
    }
}

# ---------------------------------------------------------------------------
# Output
# ---------------------------------------------------------------------------
if ($Detection) {
    if ($bad.Count -eq 0) {
        Write-Output ("All {0} checked ASR rules are set to {1}." -f $checked.Count, ($accepted -join ' or '))
        exit 0
    }
    $names = ($bad | ForEach-Object { "$($_.Rule) [$($_.State)]" }) -join '; '
    $line = "{0} of {1} ASR rules not set to {2}: {3}" -f $bad.Count, $checked.Count, ($accepted -join ' or '), $names
    if ($line.Length -gt 2000) { $line = $line.Substring(0, 1997) + '...' }   # Intune keeps ~2048 characters
    Write-Output $line
    exit 1
}

Write-Host ''
Write-Host ("Accepted modes: {0}" -f ($accepted -join ', '))
$results | Sort-Object @{ Expression = { switch ($_.Status) { 'NonCompliant' { 0 } 'Compliant' { 1 } default { 2 } } } }, Rule |
    Format-Table Status, State, Rule, Guid -AutoSize -Wrap | Out-String | Write-Host

if ($unknown.Count -gt 0) {
    Write-Host 'Configured GUIDs not in this script''s rule table (review against the Microsoft reference):' -ForegroundColor Yellow
    $unknown | Format-Table Guid, State -AutoSize | Out-String | Write-Host
}

$summary = "{0} compliant, {1} non-compliant, {2} skipped (of {3} rules)." -f ($checked.Count - $bad.Count), $bad.Count, $skipped.Count, $results.Count
if ($bad.Count -eq 0) { Write-Host $summary -ForegroundColor Green } else { Write-Host $summary -ForegroundColor Red }

if ($PassThru) { $results }

if ($bad.Count -gt 0) { exit 1 }
exit 0
