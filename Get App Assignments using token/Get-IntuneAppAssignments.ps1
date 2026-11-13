<#
.SYNOPSIS
    Lists Intune app assignments for a tenant using a Microsoft Graph bearer token.

.DESCRIPTION
    Uses a bearer token (for example, one copied from the Authorization header of a
    graph.microsoft.com request in the Intune portal's browser DevTools) to:
      1. Decode the token and show which tenant / user / scopes it carries, and when it expires
      2. Page through all mobile apps with their assignments
      3. Resolve group IDs and assignment filter IDs to display names
      4. Output one row per assignment (and optionally export to CSV / JSON)

    The token needs at least DeviceManagementApps.Read.All. Group names also need
    Group.Read.All or Directory.Read.All (otherwise the group ID is shown instead);
    filter names need DeviceManagementConfiguration.Read.All.

    Portal tokens usually live for 60-90 minutes. Treat them like a password.

.PARAMETER Token
    The bearer token, with or without the leading "Bearer ". If you leave it out,
    you will be prompted for it without it being echoed to the screen.

.PARAMETER AppName
    Optional wildcard filter on app display name, e.g. "*Chrome*".

.PARAMETER IncludeUnassigned
    Also list apps with no assignments (one row each, with TargetType "Unassigned").

.PARAMETER CsvPath
    Optional path to export the results as CSV.

.PARAMETER JsonPath
    Optional path to export the results as JSON.

.PARAMETER NoExport
    Don't prompt for an export location. When neither -CsvPath nor -JsonPath is
    given, the script asks where to save the results (a Save As dialog on Windows,
    a typed path elsewhere). The format follows the extension (.csv or .json).

.EXAMPLE
    .\Get-IntuneAppAssignments.ps1
    Prompts for the token, shows all assigned apps in a table, then asks where to save them.

.EXAMPLE
    .\Get-IntuneAppAssignments.ps1 -AppName "*Adobe*" -CsvPath .\adobe-assignments.csv

.EXAMPLE
    $rows = .\Get-IntuneAppAssignments.ps1 -Token $tok -PassThru
    $rows | Where-Object Intent -eq 'required' | Group-Object GroupName
#>
[CmdletBinding()]
param(
    [string]$Token,
    [string]$AppName = '*',
    [switch]$IncludeUnassigned,
    [string]$CsvPath,
    [string]$JsonPath,
    [switch]$NoExport,
    [switch]$PassThru
)

$ErrorActionPreference = 'Stop'
$GraphBeta = 'https://graph.microsoft.com/beta'
$GraphV1   = 'https://graph.microsoft.com/v1.0'

#region ---- Token handling ------------------------------------------------------

if (-not $Token) {
    $secure = Read-Host -Prompt 'Paste bearer token' -AsSecureString
    $bstr   = [Runtime.InteropServices.Marshal]::SecureStringToBSTR($secure)
    try     { $Token = [Runtime.InteropServices.Marshal]::PtrToStringBSTR($bstr) }
    finally { [Runtime.InteropServices.Marshal]::ZeroFreeBSTR($bstr) }
}

# Strip "Bearer " prefix, whitespace and line breaks picked up when copying from DevTools
$Token = ($Token -replace '^\s*Bearer\s+', '') -replace '\s', ''

function ConvertFrom-Base64Url([string]$s) {
    $s = $s.Replace('-', '+').Replace('_', '/')
    switch ($s.Length % 4) { 2 { $s += '==' } 3 { $s += '=' } }
    [Text.Encoding]::UTF8.GetString([Convert]::FromBase64String($s))
}

$parts = $Token.Split('.')
if ($parts.Count -lt 2) { throw 'That does not look like a JWT bearer token (expected header.payload.signature).' }

try   { $claims = ConvertFrom-Base64Url $parts[1] | ConvertFrom-Json }
catch { throw "Could not decode the token payload: $($_.Exception.Message)" }

$expiresUtc = [DateTimeOffset]::FromUnixTimeSeconds([int64]$claims.exp).UtcDateTime
$minutesLeft = [math]::Round(($expiresUtc - [DateTime]::UtcNow).TotalMinutes, 1)
$who = @($claims.upn, $claims.unique_name, $claims.preferred_username, $claims.app_displayname) |
       Where-Object { $_ } | Select-Object -First 1

Write-Host ''
Write-Host 'Token details' -ForegroundColor Cyan
Write-Host ("  Tenant ID : {0}" -f $claims.tid)
Write-Host ("  Identity  : {0}" -f $who)
Write-Host ("  Audience  : {0}" -f $claims.aud)
Write-Host ("  Scopes    : {0}" -f $(if ($claims.scp) { $claims.scp } else { ($claims.roles -join ' ') }))
Write-Host ("  Expires   : {0:yyyy-MM-dd HH:mm} local ({1} min left)" -f $expiresUtc.ToLocalTime(), $minutesLeft)
Write-Host ''

if ($minutesLeft -le 0) { throw 'The token has expired. Copy a fresh one from the portal (refresh the page first).' }
if ($claims.aud -notin @('https://graph.microsoft.com', 'https://graph.microsoft.com/', '00000003-0000-0000-c000-000000000000')) {
    Write-Warning "Token audience is '$($claims.aud)', not Microsoft Graph. Pick a request to graph.microsoft.com in DevTools (e.g. 'mobileApps' or 'managedDevices')."
}

$headers = @{
    Authorization    = "Bearer $Token"
    'Content-Type'   = 'application/json'
    ConsistencyLevel = 'eventual'
}

#endregion

#region ---- Graph helpers -------------------------------------------------------

function Invoke-Graph {
    param(
        [Parameter(Mandatory)][string]$Uri,
        [string]$Method = 'GET',
        $Body
    )
    $attempt = 0
    while ($true) {
        $attempt++
        try {
            $params = @{ Uri = $Uri; Method = $Method; Headers = $headers }
            if ($Body) { $params.Body = ($Body | ConvertTo-Json -Depth 10 -Compress) }
            return Invoke-RestMethod @params
        }
        catch {
            $resp   = $_.Exception.Response
            $status = if ($resp) { [int]$resp.StatusCode } else { 0 }

            if (($status -eq 429 -or $status -ge 500) -and $attempt -le 5) {
                $wait = 5 * $attempt
                try {
                    if ($resp.Headers.RetryAfter.Delta) { $wait = [int]$resp.Headers.RetryAfter.Delta.TotalSeconds }   # PowerShell 7
                    elseif ($resp.Headers['Retry-After']) { $wait = [int]$resp.Headers['Retry-After'] }                # Windows PowerShell 5.1
                } catch { }
                Write-Verbose "HTTP $status - retrying in $wait s (attempt $attempt)"
                Start-Sleep -Seconds $wait
                continue
            }

            $detail = $_.ErrorDetails.Message
            switch ($status) {
                401 { throw "401 Unauthorized calling $Uri. The token is expired or invalid. $detail" }
                403 { throw "403 Forbidden calling $Uri. The token lacks the needed permission/role. $detail" }
                default { throw "HTTP $status calling $Uri. $detail $($_.Exception.Message)" }
            }
        }
    }
}

function Get-GraphPaged([string]$Uri) {
    $items = New-Object System.Collections.Generic.List[object]
    while ($Uri) {
        $page = Invoke-Graph -Uri $Uri
        if ($page.value) { $items.AddRange([object[]]$page.value) }
        $Uri = $page.'@odata.nextLink'
    }
    $items
}

#endregion

#region ---- Collect data --------------------------------------------------------

Write-Host 'Fetching apps and assignments...' -ForegroundColor Cyan
$apps = Get-GraphPaged "$GraphBeta/deviceAppManagement/mobileApps?`$expand=assignments&`$top=999"
$apps = $apps | Where-Object { $_.displayName -like $AppName }
Write-Host ("  {0} apps matched '{1}'" -f @($apps).Count, $AppName)

# Assignment filters (id -> name). Non-fatal if the token can't read them.
$filterNames = @{}
try {
    Get-GraphPaged "$GraphBeta/deviceManagement/assignmentFilters?`$select=id,displayName" |
        ForEach-Object { $filterNames[$_.id] = $_.displayName }
} catch {
    Write-Warning "Could not read assignment filters, so filter IDs will be shown instead. $($_.Exception.Message)"
}

# Groups (id -> name), resolved in batches of 1000 via getByIds
$groupIds = @($apps.assignments.target.groupId | Where-Object { $_ } | Sort-Object -Unique)
$groupNames = @{}
if ($groupIds.Count) {
    Write-Host ("Resolving {0} group IDs..." -f $groupIds.Count) -ForegroundColor Cyan
    try {
        for ($i = 0; $i -lt $groupIds.Count; $i += 1000) {
            $batch = $groupIds[$i..([math]::Min($i + 999, $groupIds.Count - 1))]
            $res = Invoke-Graph -Method POST -Uri "$GraphV1/directoryObjects/getByIds" -Body @{ ids = @($batch); types = @('group') }
            $res.value | ForEach-Object { $groupNames[$_.id] = $_.displayName }
        }
    } catch {
        Write-Warning "Could not resolve group names, so group IDs will be shown instead. $($_.Exception.Message)"
    }
}

#endregion

#region ---- Shape output --------------------------------------------------------

$targetTypeMap = @{
    '#microsoft.graph.groupAssignmentTarget'            = 'Include group'
    '#microsoft.graph.exclusionGroupAssignmentTarget'   = 'Exclude group'
    '#microsoft.graph.allLicensedUsersAssignmentTarget' = 'All users'
    '#microsoft.graph.allDevicesAssignmentTarget'       = 'All devices'
}

$rows = foreach ($app in $apps) {
    $appType = ($app.'@odata.type' -replace '^#microsoft\.graph\.', '')
    $base = [ordered]@{
        AppName   = $app.displayName
        AppType   = $appType
        Publisher = $app.publisher
        Version   = $(if ($app.displayVersion) { $app.displayVersion } else { $app.version })
    }

    if (-not $app.assignments) {
        if ($IncludeUnassigned) {
            [pscustomobject]($base + [ordered]@{
                Intent = $null; TargetType = 'Unassigned'; GroupName = $null; GroupId = $null
                Filter = $null; FilterMode = $null; Notifications = $null
                AvailableFrom = $null; Deadline = $null; DeliveryOptimization = $null
                AppId = $app.id
            })
        }
        continue
    }

    foreach ($a in $app.assignments) {
        $t = $a.target
        $s = $a.settings
        $filterId = $t.deviceAndAppManagementAssignmentFilterId

        [pscustomobject]($base + [ordered]@{
            Intent        = $a.intent
            TargetType    = $(if ($targetTypeMap[$t.'@odata.type']) { $targetTypeMap[$t.'@odata.type'] } else { $t.'@odata.type' })
            GroupName     = $(if ($t.groupId) { if ($groupNames[$t.groupId]) { $groupNames[$t.groupId] } else { $t.groupId } })
            GroupId       = $t.groupId
            Filter        = $(if ($filterId) { if ($filterNames[$filterId]) { $filterNames[$filterId] } else { $filterId } })
            FilterMode    = $(if ($filterId -and $t.deviceAndAppManagementAssignmentFilterType -ne 'none') { $t.deviceAndAppManagementAssignmentFilterType })
            Notifications = $s.notifications
            AvailableFrom = $s.installTimeSettings.startDateTime
            Deadline      = $s.installTimeSettings.deadlineDateTime
            DeliveryOptimization = $s.deliveryOptimizationPriority
            AppId         = $app.id
        })
    }
}

$rows = @($rows | Sort-Object AppName, Intent, TargetType, GroupName)

Write-Host ''
Write-Host ("{0} assignment rows across {1} apps" -f $rows.Count, @($rows.AppName | Sort-Object -Unique).Count) -ForegroundColor Green

if (-not $PassThru) {
    $rows | Format-Table AppName, Intent, TargetType, GroupName, Filter, FilterMode, Notifications -AutoSize | Out-Host
}

#endregion

#region ---- Export --------------------------------------------------------------

function Get-ExportPath {
    param([string]$DefaultName)

    $docs = [Environment]::GetFolderPath('MyDocuments')
    if (-not $docs) { $docs = $HOME }

    # Windows: Save As dialog (falls back to a typed path if it can't be shown)
    if ($IsWindows -or $PSVersionTable.PSEdition -eq 'Desktop') {
        try {
            Add-Type -AssemblyName System.Windows.Forms
            $dlg = New-Object System.Windows.Forms.SaveFileDialog -Property @{
                Title            = 'Save Intune app assignments'
                Filter           = 'CSV file (*.csv)|*.csv|JSON file (*.json)|*.json'
                FileName         = $DefaultName
                InitialDirectory = $docs
                OverwritePrompt  = $true
            }
            # Owner window kept on top so the dialog doesn't open behind the console
            $owner = New-Object System.Windows.Forms.Form -Property @{ TopMost = $true; ShowInTaskbar = $false }
            try {
                if ($dlg.ShowDialog($owner) -eq [System.Windows.Forms.DialogResult]::OK) { return $dlg.FileName }
                return $null   # Cancel = skip export
            } finally { $owner.Dispose(); $dlg.Dispose() }
        } catch {
            Write-Verbose "Save dialog unavailable ($($_.Exception.Message)); asking in the console instead."
        }
    }

    $default = Join-Path $docs $DefaultName
    Write-Host ''
    Write-Host 'Where should the results be saved? Use a .csv or .json path, or a folder.' -ForegroundColor Cyan
    $answer = Read-Host "Path [Enter = $default, N = don't save]"
    if ($answer -match '^\s*n(o)?\s*$') { return $null }
    if ([string]::IsNullOrWhiteSpace($answer)) { return $default }

    $answer = [Environment]::ExpandEnvironmentVariables($answer.Trim().Trim('"'))
    if ($answer.StartsWith('~')) { $answer = Join-Path $HOME $answer.Substring(1).TrimStart('\', '/') }
    if ((Test-Path -LiteralPath $answer -PathType Container) -or $answer -match '[\\/]$') {
        $answer = Join-Path $answer $DefaultName
    }
    if (-not [IO.Path]::GetExtension($answer)) { $answer += '.csv' }
    $answer
}

if (-not $CsvPath -and -not $JsonPath -and -not $NoExport -and $rows.Count) {
    $tenantShort = "$($claims.tid)".Split('-')[0]
    $defaultName = 'IntuneAppAssignments_{0}_{1:yyyyMMdd-HHmm}.csv' -f $tenantShort, (Get-Date)
    $chosen = Get-ExportPath -DefaultName $defaultName
    if ($chosen) {
        if ([IO.Path]::GetExtension($chosen) -ieq '.json') { $JsonPath = $chosen } else { $CsvPath = $chosen }
    } else {
        Write-Host 'Export skipped.'
    }
}

foreach ($p in @($CsvPath, $JsonPath) | Where-Object { $_ }) {
    $dir = Split-Path -Parent $p
    if ($dir -and -not (Test-Path -LiteralPath $dir)) { New-Item -ItemType Directory -Path $dir -Force | Out-Null }
}

if ($CsvPath)  { $rows | Export-Csv -LiteralPath $CsvPath -NoTypeInformation -Encoding UTF8; Write-Host "CSV written to $((Resolve-Path -LiteralPath $CsvPath).Path)" -ForegroundColor Green }
if ($JsonPath) { $rows | ConvertTo-Json -Depth 5 | Set-Content -LiteralPath $JsonPath -Encoding UTF8; Write-Host "JSON written to $((Resolve-Path -LiteralPath $JsonPath).Path)" -ForegroundColor Green }

if ($PassThru) { $rows }

#endregion