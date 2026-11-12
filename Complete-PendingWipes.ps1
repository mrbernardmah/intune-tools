<#
.SYNOPSIS
    Finishes "Wipe then Delete" offboarding safely: issues wipes, waits until each device has
    actually picked up the wipe, and only then removes it from Intune, Autopilot and Entra ID.

.DESCRIPTION
    Why this exists
    ---------------
    Device Offboarding Manager 0.3.2 sends the Intune wipe and then deletes the Intune, Entra ID and
    Autopilot records about two seconds later. That breaks the wipe:
      * Intune's Delete action takes precedence over a pending Wipe (a device with several pending
        actions only carries out one of Retire/Wipe/Delete), and Delete triggers a Retire instead.
      * Deleting the Entra ID device object stops the device authenticating to the MDM service,
        so it can never check in to receive the wipe.
    Result: the wipe sits at "Pending" forever and the device is never reset.

    This tool splits the job into two phases:
      1. Wipe     - send the wipe and record the device in a local queue. Nothing is deleted.
      2. Complete - for each queued device, check whether the device has picked up the wipe
                    (managementState wipeIssued, wipe action done, or a check-in after the wipe was
                    sent). Once it has, delete it from Intune -> Autopilot -> Entra ID (or disable
                    in Entra ID). Devices still pending are left alone and reported.

    The patched DeviceOffboardingManager.ps1 writes to the same queue, so devices wiped from the
    GUI are finished by running this script with -Complete.

.PARAMETER Wipe
    Issue a wipe for the given serial numbers and add them to the queue.
.PARAMETER Complete
    Process the queue: delete records for devices whose wipe has been picked up.
.PARAMETER Status
    Show the queue with each device's current wipe state. Changes nothing.
.PARAMETER SerialNumber
    One or more serial numbers (used with -Wipe).
.PARAMETER CsvPath
    CSV with a SerialNumber column (used with -Wipe).
.PARAMETER KeepEnrollmentData / KeepUserData / UseProtectedWipe
    Passed through to the Graph wipe action. Defaults: all false (full factory reset).
.PARAMETER EntraAction
    Delete (default), Disable, or None. Used with -Wipe.
.PARAMETER SkipAutopilot / SkipIntune
    Leave the Autopilot registration / Intune record in place. Used with -Wipe.
.PARAMETER ForceAfterHours
    With -Complete: delete records for devices still pending after this many hours (e.g. lost or
    permanently offline). Off by default because it guarantees the wipe will never run.
.PARAMETER QueuePath
    Defaults to %LOCALAPPDATA%\DeviceOffboardingManager\PendingWipes.json (same file the GUI uses).
.PARAMETER TenantId / ClientId / CertificateThumbprint
    Optional app-only auth (for scheduled runs). Without these, signs in interactively.

.EXAMPLE
    .\Complete-PendingWipes.ps1 -Wipe -SerialNumber 5CG3495H4T
.EXAMPLE
    .\Complete-PendingWipes.ps1 -Status
.EXAMPLE
    .\Complete-PendingWipes.ps1 -Complete -WhatIf
.EXAMPLE
    .\Complete-PendingWipes.ps1 -Complete -TenantId <tid> -ClientId <appid> -CertificateThumbprint <thumb>

.NOTES
    Requires Microsoft.Graph.Authentication. Permissions:
      DeviceManagementManagedDevices.PrivilegedOperations.All, DeviceManagementManagedDevices.ReadWrite.All,
      DeviceManagementServiceConfig.ReadWrite.All, Device.ReadWrite.All
    Delegated sign-in also needs an Entra role that can delete devices (e.g. Intune Administrator).
#>
[CmdletBinding(SupportsShouldProcess = $true, DefaultParameterSetName = 'Status')]
param(
    [Parameter(ParameterSetName = 'Wipe', Mandatory = $true)][switch]$Wipe,
    [Parameter(ParameterSetName = 'Complete', Mandatory = $true)][switch]$Complete,
    [Parameter(ParameterSetName = 'Status')][switch]$Status,

    [Parameter(ParameterSetName = 'Wipe')][string[]]$SerialNumber,
    [Parameter(ParameterSetName = 'Wipe')][string]$CsvPath,
    [Parameter(ParameterSetName = 'Wipe')][switch]$KeepEnrollmentData,
    [Parameter(ParameterSetName = 'Wipe')][switch]$KeepUserData,
    [Parameter(ParameterSetName = 'Wipe')][switch]$UseProtectedWipe,
    [Parameter(ParameterSetName = 'Wipe')][ValidateSet('Delete', 'Disable', 'None')][string]$EntraAction = 'Delete',
    [Parameter(ParameterSetName = 'Wipe')][switch]$SkipAutopilot,
    [Parameter(ParameterSetName = 'Wipe')][switch]$SkipIntune,

    [Parameter(ParameterSetName = 'Complete')][int]$ForceAfterHours = 0,

    [string]$QueuePath = (Join-Path $env:LOCALAPPDATA 'DeviceOffboardingManager\PendingWipes.json'),
    [string]$TenantId,
    [string]$ClientId,
    [string]$CertificateThumbprint
)

$ErrorActionPreference = 'Stop'
$Graph = 'https://graph.microsoft.com/beta'
$LogPath = Join-Path (Split-Path $QueuePath) ('PendingWipes_{0:yyyyMMdd}.log' -f (Get-Date))

#region helpers
function Write-Log {
    param([string]$Message, [ValidateSet('INFO', 'WARN', 'ERROR', 'AUDIT')][string]$Severity = 'INFO')
    $line = '{0:yyyy-MM-dd HH:mm:ss} [{1}] {2}' -f (Get-Date), $Severity, $Message
    $colour = @{ INFO = 'Gray'; WARN = 'Yellow'; ERROR = 'Red'; AUDIT = 'Cyan' }[$Severity]
    Write-Host $line -ForegroundColor $colour
    try { Add-Content -Path $LogPath -Value $line -Encoding UTF8 } catch { }
}

function Connect-ToGraph {
    if (-not (Get-Module -ListAvailable Microsoft.Graph.Authentication)) {
        throw "Microsoft.Graph.Authentication is not installed. Run: Install-Module Microsoft.Graph.Authentication -Scope CurrentUser"
    }
    Import-Module Microsoft.Graph.Authentication
    $ctx = Get-MgContext
    if ($ctx -and (-not $TenantId -or $ctx.TenantId -eq $TenantId)) { return $ctx }
    if ($ClientId -and $CertificateThumbprint -and $TenantId) {
        Connect-MgGraph -TenantId $TenantId -ClientId $ClientId -CertificateThumbprint $CertificateThumbprint -NoWelcome
    } else {
        $scopes = @(
            'DeviceManagementManagedDevices.PrivilegedOperations.All',
            'DeviceManagementManagedDevices.ReadWrite.All',
            'DeviceManagementServiceConfig.ReadWrite.All',
            'Device.ReadWrite.All'
        )
        $p = @{ Scopes = $scopes; NoWelcome = $true }
        if ($TenantId) { $p.TenantId = $TenantId }
        Connect-MgGraph @p
    }
    return (Get-MgContext)
}

function Invoke-Graph {
    param([string]$Method = 'GET', [string]$Uri, $Body)
    $p = @{ Method = $Method; Uri = $Uri; OutputType = 'PSObject' }
    if ($null -ne $Body) { $p.Body = ($Body | ConvertTo-Json -Depth 5); $p.ContentType = 'application/json' }
    for ($attempt = 1; $attempt -le 4; $attempt++) {
        try { return Invoke-MgGraphRequest @p }
        catch {
            $code = $_.Exception.Response.StatusCode.value__
            if ($code -in 429, 500, 502, 503, 504 -and $attempt -lt 4) { Start-Sleep -Seconds ([math]::Pow(2, $attempt)); continue }
            throw
        }
    }
}

function ConvertTo-UtcDate($value) {
    if ($value -is [datetime]) { return $value.ToUniversalTime() }
    return [datetime]::Parse([string]$value, [Globalization.CultureInfo]::InvariantCulture, [Globalization.DateTimeStyles]::RoundtripKind).ToUniversalTime()
}

function Get-StatusCode($err) { try { [int]$err.Exception.Response.StatusCode } catch { 0 } }

function Read-Queue {
    if (-not (Test-Path $QueuePath)) { return @() }
    $raw = Get-Content -Path $QueuePath -Raw
    if (-not $raw) { return @() }
    return @($raw | ConvertFrom-Json)
}

function Save-Queue([object[]]$Queue) {
    $dir = Split-Path $QueuePath
    if (-not (Test-Path $dir)) { New-Item -ItemType Directory -Path $dir -Force | Out-Null }
    ConvertTo-Json -InputObject @($Queue) -Depth 5 | Set-Content -Path $QueuePath -Encoding UTF8
}

function Get-WipeState($entry) {
    # Returns @{ State = 'PickedUp'|'Pending'|'Failed'|'Gone'; Detail = '...'; LastSync = [datetime] }
    try {
        $d = Invoke-Graph -Uri "$Graph/deviceManagement/managedDevices/$($entry.IntuneDeviceId)?`$select=id,deviceName,managementState,lastSyncDateTime,deviceActionResults"
    } catch {
        if ((Get-StatusCode $_) -eq 404) { return @{ State = 'Gone'; Detail = 'Intune record no longer exists' } }
        throw
    }
    $issued = (ConvertTo-UtcDate $entry.WipeIssuedUtc)
    $lastSync = if ($d.lastSyncDateTime) { (ConvertTo-UtcDate $d.lastSyncDateTime) } else { [datetime]::MinValue }
    $wipe = @($d.deviceActionResults) | Where-Object { $_.actionName -eq 'wipe' } |
        Sort-Object { [datetime]$_.startDateTime } -Descending | Select-Object -First 1
    $actionState = if ($wipe) { $wipe.actionState } else { 'none' }
    $detail = "managementState=$($d.managementState); wipe=$actionState; lastSync=$('{0:u}' -f $lastSync)"

    if ($d.managementState -in 'wipeFailed' -or $actionState -eq 'failed') { return @{ State = 'Failed'; Detail = $detail; LastSync = $lastSync } }
    if ($d.managementState -eq 'wipeCanceled' -or $actionState -eq 'canceled') { return @{ State = 'Failed'; Detail = "$detail (canceled)"; LastSync = $lastSync } }
    # Windows often resets before acknowledging, so the action can stay 'pending' even after the
    # device has received it. Any of these signals means the device has the command:
    if ($d.managementState -eq 'wipeIssued' -or $actionState -eq 'done' -or $lastSync -gt $issued.AddMinutes(1)) {
        return @{ State = 'PickedUp'; Detail = $detail; LastSync = $lastSync }
    }
    return @{ State = 'Pending'; Detail = $detail; LastSync = $lastSync }
}

function Remove-DeviceRecords($entry) {
    $name = "$($entry.DeviceName) ($($entry.SerialNumber))"
    $ok = $true

    # 1. Intune (must go before Autopilot / Entra: Autopilot devices can't be removed from Entra while in Intune)
    if ($entry.DeleteIntune -and $entry.IntuneDeviceId) {
        if ($PSCmdlet.ShouldProcess($name, 'Delete Intune managed device')) {
            try { Invoke-Graph -Method DELETE -Uri "$Graph/deviceManagement/managedDevices/$($entry.IntuneDeviceId)" | Out-Null; Write-Log "Deleted $name from Intune" AUDIT }
            catch { if ((Get-StatusCode $_) -ne 404) { $ok = $false; Write-Log "Intune delete failed for ${name}: $($_.Exception.Message)" ERROR } }
        }
    }

    # 2. Autopilot
    if ($entry.DeleteAutopilot) {
        $apId = $entry.AutopilotIdentityId
        if (-not $apId -and $entry.SerialNumber) {
            $ap = Invoke-Graph -Uri "$Graph/deviceManagement/windowsAutopilotDeviceIdentities?`$filter=contains(serialNumber,'$($entry.SerialNumber)')"
            $apId = @($ap.value | Where-Object { $_.serialNumber -eq $entry.SerialNumber })[0].id
        }
        if ($apId -and $PSCmdlet.ShouldProcess($name, 'Delete Autopilot registration')) {
            $deleted = $false
            for ($i = 1; $i -le 6 -and -not $deleted; $i++) {
                try { Invoke-Graph -Method DELETE -Uri "$Graph/deviceManagement/windowsAutopilotDeviceIdentities/$apId" | Out-Null; $deleted = $true }
                catch {
                    $code = Get-StatusCode $_
                    if ($code -eq 404) { $deleted = $true }
                    elseif ($i -lt 6) { Start-Sleep -Seconds 20 }   # Intune deletion takes a moment to clear the association
                    else { $ok = $false; Write-Log "Autopilot delete failed for ${name}: $($_.Exception.Message)" ERROR }
                }
            }
            if ($deleted) { Write-Log "Deleted $name from Autopilot" AUDIT }
        }
    }

    # 3. Entra ID
    if ($entry.EntraAction -in 'Delete', 'Disable') {
        $objId = $entry.EntraObjectId
        if (-not $objId -and $entry.EntraDeviceId) {
            $e = Invoke-Graph -Uri "https://graph.microsoft.com/v1.0/devices?`$filter=deviceId eq '$($entry.EntraDeviceId)'&`$select=id"
            $objId = @($e.value)[0].id
        }
        if ($objId) {
            if ($entry.EntraAction -eq 'Delete' -and $PSCmdlet.ShouldProcess($name, 'Delete Entra ID device')) {
                try { Invoke-Graph -Method DELETE -Uri "https://graph.microsoft.com/v1.0/devices/$objId" | Out-Null; Write-Log "Deleted $name from Entra ID" AUDIT }
                catch { if ((Get-StatusCode $_) -ne 404) { $ok = $false; Write-Log "Entra delete failed for ${name}: $($_.Exception.Message)" ERROR } }
            } elseif ($entry.EntraAction -eq 'Disable' -and $PSCmdlet.ShouldProcess($name, 'Disable Entra ID device')) {
                try { Invoke-Graph -Method PATCH -Uri "https://graph.microsoft.com/v1.0/devices/$objId" -Body @{ accountEnabled = $false } | Out-Null; Write-Log "Disabled $name in Entra ID" AUDIT }
                catch { $ok = $false; Write-Log "Entra disable failed for ${name}: $($_.Exception.Message)" ERROR }
            }
        }
    }
    return $ok
}
#endregion

$ctx = Connect-ToGraph
Write-Log "Connected to tenant $($ctx.TenantId) as $($ctx.Account)$($ctx.AppName)"

switch ($PSCmdlet.ParameterSetName) {

    'Wipe' {
        $serials = @($SerialNumber)
        if ($CsvPath) { $serials += (Import-Csv $CsvPath).SerialNumber }
        $serials = @($serials | Where-Object { $_ } | ForEach-Object { $_.Trim() } | Select-Object -Unique)
        if (-not $serials) { throw 'Provide -SerialNumber or -CsvPath.' }

        $queue = [System.Collections.Generic.List[object]]::new()
        Read-Queue | ForEach-Object { $queue.Add($_) }

        foreach ($sn in $serials) {
            $md = Invoke-Graph -Uri "$Graph/deviceManagement/managedDevices?`$filter=serialNumber eq '$sn'&`$select=id,deviceName,serialNumber,azureADDeviceId,lastSyncDateTime"
            $devices = @($md.value)
            if ($devices.Count -eq 0) { Write-Log "$sn not found in Intune - nothing to wipe" WARN; continue }
            if ($devices.Count -gt 1) { Write-Log "$sn matches $($devices.Count) Intune records - skipping, resolve duplicates first" WARN; continue }
            $d = $devices[0]

            $entraObjId = $null
            if ($d.azureADDeviceId -and $d.azureADDeviceId -ne '00000000-0000-0000-0000-000000000000') {
                $e = Invoke-Graph -Uri "https://graph.microsoft.com/v1.0/devices?`$filter=deviceId eq '$($d.azureADDeviceId)'&`$select=id"
                $entraObjId = @($e.value)[0].id
            }
            $ap = Invoke-Graph -Uri "$Graph/deviceManagement/windowsAutopilotDeviceIdentities?`$filter=contains(serialNumber,'$sn')"
            $apId = @($ap.value | Where-Object { $_.serialNumber -eq $sn })[0].id

            if ($PSCmdlet.ShouldProcess("$($d.deviceName) ($sn)", 'Wipe device')) {
                try {
                    Invoke-Graph -Method POST -Uri "$Graph/deviceManagement/managedDevices/$($d.id)/wipe" -Body @{
                        keepEnrollmentData = [bool]$KeepEnrollmentData
                        keepUserData       = [bool]$KeepUserData
                        useProtectedWipe   = [bool]$UseProtectedWipe
                    } | Out-Null
                } catch {
                    Write-Log "Wipe failed for $($d.deviceName) ($sn): $($_.Exception.Message)" ERROR
                    continue
                }
                Write-Log "Wipe sent to $($d.deviceName) ($sn). Last check-in: $($d.lastSyncDateTime)" AUDIT
                for ($i = $queue.Count - 1; $i -ge 0; $i--) { if ($queue[$i].IntuneDeviceId -eq $d.id) { $queue.RemoveAt($i) } }
                $queue.Add([pscustomobject][ordered]@{
                    TenantId            = $ctx.TenantId
                    DeviceName          = $d.deviceName
                    SerialNumber        = $sn
                    IntuneDeviceId      = $d.id
                    EntraObjectId       = $entraObjId
                    EntraDeviceId       = $d.azureADDeviceId
                    AutopilotIdentityId = $apId
                    WipeIssuedUtc       = (Get-Date).ToUniversalTime().ToString('o')
                    EntraAction         = $EntraAction
                    DeleteIntune        = -not $SkipIntune
                    DeleteAutopilot     = (-not $SkipAutopilot) -and [bool]$apId
                })
            }
        }
        if (-not $WhatIfPreference) { Save-Queue $queue }
        Write-Log "Queue saved to $QueuePath. Run with -Complete once devices have checked in (they must be online)."
    }

    'Complete' {
        $queue = Read-Queue
        if (-not $queue) { Write-Log 'Queue is empty - nothing to do.'; return }
        $remaining = [System.Collections.Generic.List[object]]::new()
        foreach ($entry in $queue) {
            $name = "$($entry.DeviceName) ($($entry.SerialNumber))"
            if ($entry.TenantId -and $entry.TenantId -ne $ctx.TenantId) { $remaining.Add($entry); Write-Log "$name belongs to tenant $($entry.TenantId) - skipped" WARN; continue }

            $state = Get-WipeState $entry
            $ageH = [math]::Round(((Get-Date).ToUniversalTime() - (ConvertTo-UtcDate $entry.WipeIssuedUtc)).TotalHours, 1)

            $proceed = $false
            switch ($state.State) {
                'PickedUp' { $proceed = $true; Write-Log "$name picked up the wipe ($($state.Detail)) - removing records" AUDIT }
                'Gone'     { $proceed = $true; Write-Log "$name is already gone from Intune - cleaning up Autopilot/Entra" AUDIT }
                'Failed'   { Write-Log "$name wipe FAILED ($($state.Detail)). Re-issue the wipe or reset the device locally; records kept." ERROR }
                'Pending'  {
                    if ($ForceAfterHours -gt 0 -and $ageH -ge $ForceAfterHours) {
                        $proceed = $true
                        Write-Log "$name still pending after $ageH h - forcing deletion (-ForceAfterHours $ForceAfterHours). THE WIPE WILL NOT RUN." WARN
                    } else {
                        Write-Log "$name still pending ($ageH h, $($state.Detail)). Device must come online and sync." INFO
                    }
                }
            }

            if ($proceed -and (Remove-DeviceRecords $entry) -and -not $WhatIfPreference) { continue }
            $remaining.Add($entry)
        }
        if (-not $WhatIfPreference) { Save-Queue $remaining }
        Write-Log "$($queue.Count - $remaining.Count) completed, $($remaining.Count) still in queue."
    }

    default {
        $queue = Read-Queue
        if (-not $queue) { Write-Host "Queue is empty ($QueuePath)."; return }
        $queue | ForEach-Object {
            $s = if ($_.TenantId -and $_.TenantId -ne $ctx.TenantId) { @{ State = 'OtherTenant'; Detail = $_.TenantId } } else { Get-WipeState $_ }
            [pscustomobject]@{
                Device      = $_.DeviceName
                Serial      = $_.SerialNumber
                WipeSentUtc = (ConvertTo-UtcDate $_.WipeIssuedUtc).ToString('yyyy-MM-dd HH:mm')
                State       = $s.State
                Detail      = $s.Detail
            }
        } | Format-Table -AutoSize -Wrap
    }
}