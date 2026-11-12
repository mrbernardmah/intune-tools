<#
.TITLE
    Wipe Devices

.SYNOPSIS
    Perform remote wipe operations on specific managed devices in Intune or devices in an Entra ID group.

.DESCRIPTION
    This script connects to Microsoft Graph and triggers remote wipe operations on targeted devices.
    You can target devices by specific names, serial numbers, device IDs, or by Entra ID group membership.
    The script provides options for selective wipe (remove company data) or full wipe (factory reset).
    All operations include confirmation prompts to prevent accidental data loss.

.TAGS
    Operational,Devices

.MINROLE
    Intune Administrator

.PERMISSIONS
    DeviceManagementManagedDevices.PrivilegedOperations.All,DeviceManagementManagedDevices.Read.All,GroupMember.Read.All,Device.Read.All,DeviceManagementServiceConfig.ReadWrite.All

.AUTHOR
    Ugur Koc

.VERSION
    2.1

.CHANGELOG
    2.1 - Added -RemoveAutopilot: after the wipe, waits for each device to leave Intune and then deletes its Windows Autopilot record; added -AutopilotCleanupCsv to finish removals later from an export CSV
    2.0 - Local runs export a CSV of every target device and its outcome, plus a transcript log, to -ExportPath (default C:\ProgramData\Devicie\logs)
    1.9 - -EntraGroupName now targets device members of the group directly (matched to Intune by Entra device ID, most recently synced record if duplicated) as well as the devices of user members; added Device.Read.All; group name escaped in the filter
    1.8 - Added -SerialNumbers target; serial number shown in device details
    1.7 - Let the finally block own Graph disconnection so early exits do not emit a second-disconnect error
    1.6 - Ignore empty string-array values supplied by Azure Automation when validating the selected target
    1.5 - Added a portal-safe DryRun mode and records an empty target group as a successful no-op
    1.4 - Added Azure Automation contract validation, portal-safe boolean parameters, beta Graph endpoints, and terminating paging errors
    1.3 - Azure Automation now records script progress, outcomes, and summaries in job history
    1.2 - Added -WhatIf dry run support; Azure Automation now requires -Force instead of hanging on a prompt; exit code 1 when any wipe fails; 429 retry with 60s wait on wipe calls; PIN now applies only to macOS devices with a warning otherwise; group lookup failures abort with a distinct error; list-based result accumulation; added $select to managed device queries
    1.1 - Local runs now use MgGraphCommunity for WAM-free interactive sign-in (auto-installed if missing); added DeviceManagementManagedDevices.PrivilegedOperations.All scope required by the Graph action (calls previously always failed with 403)
    1.0 - Initial release

.LASTUPDATE
    2026-11-12

.EXAMPLE
    .\wipe-devices.ps1 -DeviceNames "LAPTOP001","DESKTOP002" -WipeType Selective
    Performs selective wipe on specific devices by name

.EXAMPLE
    .\wipe-devices.ps1 -SerialNumbers "5CG3495H4T","5CG3495H4X" -WipeType Full
    Performs full wipe on specific devices by serial number

.EXAMPLE
    .\wipe-devices.ps1 -DeviceIds "12345678-1234-1234-1234-123456789012" -WipeType Full -Force "true"
    Performs full wipe on a specific device by ID without confirmation

.EXAMPLE
    .\wipe-devices.ps1 -EntraGroupName "Compromised Devices" -WipeType Selective
    Performs selective wipe on the devices in the specified group: device members directly, and
    for user members, every managed device whose primary user is that user

.EXAMPLE
    .\wipe-devices.ps1 -DeviceNames "LAPTOP001" -WipeType Full -KeepEnrollmentData "true" -PIN "123456"
    Performs full wipe while keeping enrollment data and using a PIN for device unlock

.EXAMPLE
    .\wipe-devices.ps1 -EntraGroupName "Compromised Devices" -WipeType Selective -DryRun "true"
    Lists the target devices without sending a wipe action

.EXAMPLE
    .\wipe-devices.ps1 -EntraGroupName "Compromised Devices" -WipeType Full -RemoveAutopilot "true"
    Performs full wipe, then waits (up to -AutopilotWaitMinutes) for each device to leave Intune and
    deletes its Windows Autopilot record

.EXAMPLE
    .\wipe-devices.ps1 -AutopilotCleanupCsv "C:\ProgramData\Devicie\logs\Wipe-Devices_20261112-153000_Full.csv"
    Wipes nothing. Re-checks the wiped devices in an earlier export and deletes the Autopilot record of each
    one that has now left Intune; the CSV is updated in place, so it can be run again later

.EXAMPLE
    .\wipe-devices.ps1 -EntraGroupName "Compromised Devices" -WipeType Full -ExportPath "D:\WipeLogs"
    Performs full wipe and writes the CSV export and transcript log to D:\WipeLogs

.NOTES
    - Supports both local execution and Azure Automation Runbook environments
    - Automatically detects execution environment and uses appropriate authentication method
    - Local execution: Uses interactive authentication with specified scopes
    - Azure Automation: Uses Managed Identity authentication
    - Requires Microsoft.Graph.Authentication module (auto-installs if missing in local environment)
    - Use -ForceModuleInstall to skip installation prompts in local environment
    - Requires appropriate permissions in Entra ID
    - CAUTION: Full wipe will completely reset the device to factory settings
    - Selective wipe removes only company data and apps
    - Operations cannot be undone - use with extreme caution
    - Confirmation prompts are shown unless -Force parameter is used
    - -SerialNumbers: if a serial has several Intune records (duplicates from re-enrollment), only the
      most recently synced record is wiped and the others are listed as a warning
    - -EntraGroupName: device members are matched to Intune by Entra device ID (same duplicate rule as
      serial numbers); user members add all of their managed devices; nested groups are not expanded;
      device members with no Intune record are listed as a warning and skipped
    - Export (local runs only): each run writes Wipe-Devices_<timestamp>_<WipeType>.csv with one row per
      target device and its result (Dry run, Wipe initiated, Failed, Cancelled, WhatIf), and a matching .log
      transcript, to -ExportPath (default C:\ProgramData\Devicie\logs). Azure Automation runs skip the export
      because the sandbox disk is not kept; use the job output there
    - -RemoveAutopilot (Windows only): the Autopilot record is found by serial number before the wipe. After
      the wipe it is deleted only once the wiped Intune record is gone and no other Intune record has that
      serial (a device that re-enrolled before the record was removed is reported, not touched). Devices
      still in Intune after -AutopilotWaitMinutes are left for -AutopilotCleanupCsv. Deleting the record is
      permanent: re-registering the device needs its hardware hash again
    - Azure Automation jobs have a 3 hour limit, so keep -AutopilotWaitMinutes well under that there
    - Local interactive sign-in uses the MgGraphCommunity module to avoid the Graph SDK's mandatory WAM broker on Windows
#>

[CmdletBinding(SupportsShouldProcess = $true)]
param(
    [Parameter(Mandatory = $false)]
    [string[]]$DeviceNames,

    [Parameter(Mandatory = $false)]
    [string[]]$SerialNumbers,

    [Parameter(Mandatory = $false)]
    [string[]]$DeviceIds,

    [Parameter(Mandatory = $false)]
    [string]$EntraGroupName,

    [Parameter(Mandatory = $false, HelpMessage = "Required unless -AutopilotCleanupCsv is used")]
    [ValidateSet('Selective', 'Full')]
    [string]$WipeType,

    [Parameter(Mandatory = $false)]
    [ValidateSet("true", "false", "1", "0", '$true', '$false')]
    [string]$Force,

    [Parameter(Mandatory = $false, HelpMessage = "Preview target devices without wiping them")]
    [ValidateSet("true", "false", "1", "0", '$true', '$false')]
    [string]$DryRun,

    [Parameter(Mandatory = $false)]
    [ValidateSet("true", "false", "1", "0", '$true', '$false')]
    [string]$KeepEnrollmentData,

    [Parameter(Mandatory = $false)]
    [string]$PIN,

    [Parameter(Mandatory = $false)]
    [int]$WipeDelaySeconds = 3,

    [Parameter(Mandatory = $false, HelpMessage = "After the wipe, wait for each device to leave Intune, then delete its Windows Autopilot record")]
    [ValidateSet("true", "false", "1", "0", '$true', '$false')]
    [string]$RemoveAutopilot,

    [Parameter(Mandatory = $false, HelpMessage = "How long to wait for wiped devices to leave Intune before giving up (0 = check once)")]
    [ValidateRange(0, 1440)]
    [int]$AutopilotWaitMinutes = 120,

    [Parameter(Mandatory = $false, HelpMessage = "Seconds between checks while waiting")]
    [ValidateRange(30, 3600)]
    [int]$AutopilotPollSeconds = 300,

    [Parameter(Mandatory = $false, HelpMessage = "Export CSV from an earlier run: remove Autopilot records for wiped devices that have now left Intune. Wipes nothing.")]
    [string]$AutopilotCleanupCsv,

    [Parameter(Mandatory = $false, HelpMessage = "Folder for the CSV export and transcript log (local runs only)")]
    [string]$ExportPath = 'C:\ProgramData\Devicie\logs',

    [Parameter(Mandatory = $false, HelpMessage = "Force module installation without prompting")]
    [ValidateSet("true", "false", "1", "0", '$true', '$false')]
    [string]$ForceModuleInstall
)

# Normalize the local module-install override for Azure Automation parameter binding.
$forceModuleInstallRaw = [string]$ForceModuleInstall
Remove-Variable -Name ForceModuleInstall
if ([string]::IsNullOrWhiteSpace($forceModuleInstallRaw)) {
    $ForceModuleInstall = $false
}
elseif ($forceModuleInstallRaw.Trim().ToLowerInvariant() -in @("true", "1", '$true')) {
    $ForceModuleInstall = $true
}
elseif ($forceModuleInstallRaw.Trim().ToLowerInvariant() -in @("false", "0", '$false')) {
    $ForceModuleInstall = $false
}
else {
    throw "Parameter 'ForceModuleInstall' accepts only true, false, 1, 0, $true, or $false."
}

# Azure Automation supplies portal parameter values as strings. Normalize the
# public boolean parameters once so local and runbook execution use real booleans.
foreach ($runbookBooleanParameter in @('Force', 'DryRun', 'KeepEnrollmentData', 'RemoveAutopilot')) {
    $runbookBooleanRaw = [string](Get-Variable -Name $runbookBooleanParameter -ValueOnly)
    Remove-Variable -Name $runbookBooleanParameter

    if ([string]::IsNullOrWhiteSpace($runbookBooleanRaw)) {
        Set-Variable -Name $runbookBooleanParameter -Value $false
        continue
    }

    switch ($runbookBooleanRaw.Trim().ToLowerInvariant()) {
        { $_ -in @("true", "1", '$true') } {
            Set-Variable -Name $runbookBooleanParameter -Value $true
        }
        { $_ -in @("false", "0", '$false') } {
            Set-Variable -Name $runbookBooleanParameter -Value $false
        }
        default {
            throw "Parameter '$runbookBooleanParameter' accepts only true, false, 1, 0, $true, or $false."
        }
    }
}

$DeviceNames = @($DeviceNames | Where-Object { -not [string]::IsNullOrWhiteSpace([string]$_) })
$DeviceIds = @($DeviceIds | Where-Object { -not [string]::IsNullOrWhiteSpace([string]$_) })
# Serial numbers never contain commas, so also split "A,B" (pwsh -File and the Automation portal can pass the list as one string)
$SerialNumbers = @($SerialNumbers | ForEach-Object { ([string]$_) -split ',' } | ForEach-Object { $_.Trim().Trim('"', "'", '[', ']').Trim() } | Where-Object { $_ } | Select-Object -Unique)

$selectedTargets = @(
    if ($DeviceNames.Count -gt 0) { 'DeviceNames' }
    if ($DeviceIds.Count -gt 0) { 'DeviceIds' }
    if ($SerialNumbers.Count -gt 0) { 'SerialNumbers' }
    if (-not [string]::IsNullOrWhiteSpace($EntraGroupName)) { 'EntraGroup' }
)
if (-not [string]::IsNullOrWhiteSpace($AutopilotCleanupCsv)) {
    # Cleanup-only mode: works from an earlier export, never wipes
    if ($selectedTargets.Count -gt 0) {
        throw "-AutopilotCleanupCsv cannot be combined with DeviceNames, SerialNumbers, DeviceIds, or EntraGroupName."
    }
    if (-not (Test-Path -Path $AutopilotCleanupCsv -PathType Leaf)) {
        throw "CSV not found: $AutopilotCleanupCsv"
    }
    $AutopilotCleanupCsv = (Resolve-Path -Path $AutopilotCleanupCsv).Path
    $TargetMode = 'AutopilotCleanup'
    $RemoveAutopilot = $true
}
else {
    if ($selectedTargets.Count -ne 1) {
        throw "Specify exactly one target: DeviceNames, SerialNumbers, DeviceIds, or EntraGroupName."
    }
    if ([string]::IsNullOrWhiteSpace($WipeType)) {
        throw "-WipeType (Selective or Full) is required."
    }
    $TargetMode = $selectedTargets[0]
}

# ============================================================================
# ENVIRONMENT DETECTION AND SETUP
# ============================================================================

function Initialize-RequiredModule {
    <#
    .SYNOPSIS
    Ensures required modules are available and loaded
    #>
    param(
        [string[]]$ModuleNames,
        [bool]$IsAutomationEnvironment,
        [bool]$ForceInstall = $false
    )

    foreach ($ModuleName in $ModuleNames) {
        Write-Verbose "Checking module: $ModuleName"

        # Check if module is available
        $module = Get-Module -ListAvailable -Name $ModuleName | Select-Object -First 1

        if (-not $module) {
            if ($IsAutomationEnvironment) {
                $errorMessage = @"
Module '$ModuleName' is not available in this Azure Automation Account.

To resolve this issue:
1. Go to Azure Portal
2. Navigate to your Automation Account
3. Go to 'Modules' > 'Browse Gallery'
4. Search for '$ModuleName'
5. Click 'Import' and wait for installation to complete

Alternative: Use PowerShell to import the module:
Import-Module Az.Automation
Import-AzAutomationModule -AutomationAccountName "YourAccount" -ResourceGroupName "YourRG" -Name "$ModuleName"
"@
                throw $errorMessage
            }
            else {
                # Local environment - attempt to install
                Write-Information "Module '$ModuleName' not found. Attempting to install..." -InformationAction Continue

                if (-not $ForceInstall) {
                    $response = Read-Host "Install module '$ModuleName'? (Y/N)"
                    if ($response -notmatch '^[Yy]') {
                        throw "Module '$ModuleName' is required but installation was declined."
                    }
                }

                try {
                    # Check if running as administrator for AllUsers scope
                    $isAdmin = ([Security.Principal.WindowsPrincipal] [Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole] "Administrator")
                    $scope = if ($isAdmin) { "AllUsers" } else { "CurrentUser" }

                    Write-Information "Installing '$ModuleName' in scope '$scope'..." -InformationAction Continue
                    Install-Module -Name $ModuleName -Scope $scope -Force -AllowClobber -Repository PSGallery
                    Write-Information "[OK] Successfully installed '$ModuleName'" -InformationAction Continue
                }
                catch {
                    throw "Failed to install module '$ModuleName': $($_.Exception.Message)"
                }
            }
        }

        # Import the module
        try {
            Write-Verbose "Importing module: $ModuleName"
            Import-Module -Name $ModuleName -Force -ErrorAction Stop
            Write-Verbose "[OK] Successfully imported '$ModuleName'"
        }
        catch {
            throw "Failed to import module '$ModuleName': $($_.Exception.Message)"
        }
    }
}

# Detect execution environment
if ($PSPrivateMetadata.JobId.Guid) {
    Write-Output "Running inside Azure Automation Runbook"
    $IsAzureAutomation = $true
}
else {
    Write-Output "Running locally in IDE or terminal"
    $IsAzureAutomation = $false
}

# Azure Automation runs are unattended - require -Force so the script cannot hang on a confirmation prompt
if ($IsAzureAutomation -and -not $Force -and -not $DryRun) {
    Write-Error "-Force is required for unattended wipe in Azure Automation"
    exit 1
}

# Initialize required modules
$RequiredModules = @(
    "Microsoft.Graph.Authentication"
)

# MgGraphCommunity gives WAM-free interactive sign-in for local runs
if (-not $IsAzureAutomation) {
    $RequiredModules += "MgGraphCommunity"
}

try {
    Initialize-RequiredModule -ModuleNames $RequiredModules -IsAutomationEnvironment $IsAzureAutomation -ForceInstall $ForceModuleInstall
    Write-Verbose "[OK] All required modules are available"
}
catch {
    Write-Error "Module initialization failed: $_"
    exit 1
}

# ============================================================================
# AUTHENTICATION
# ============================================================================

try {
    if ($IsAzureAutomation) {
        # Azure Automation - Use Managed Identity
        Write-Output "Connecting to Microsoft Graph using Managed Identity..."
        Connect-MgGraph -Identity -NoWelcome -ErrorAction Stop
        Write-Output "[OK] Successfully connected to Microsoft Graph using Managed Identity"
    }
    else {
        # Local execution - WAM-free interactive sign-in via MgGraphCommunity
        Write-Output "Connecting to Microsoft Graph with interactive authentication..."
        $scopes = @("DeviceManagementManagedDevices.Read.All")
        if ($TargetMode -ne 'AutopilotCleanup') {
            $scopes += "DeviceManagementManagedDevices.PrivilegedOperations.All"
        }
        if ($RemoveAutopilot) {
            $scopes += "DeviceManagementServiceConfig.ReadWrite.All"
        }
        if ($TargetMode -eq 'EntraGroup') {
            # Device.Read.All is needed to read the deviceId of device members (without it Graph returns them with limited properties)
            $scopes += "GroupMember.Read.All", "Device.Read.All"
        }
        Connect-MgGraphCommunity -Scopes $scopes -NoWelcome -ErrorAction Stop
        Write-Output "[OK] Successfully connected to Microsoft Graph"
    }
}
catch {
    Write-Error "Failed to connect to Microsoft Graph: $($_.Exception.Message)"
    exit 1
}

# Function to get all pages of results
function Get-MgGraphAllPage {
    param(
        [string]$Uri,
        [int]$DelayMs = 100
    )

    [System.Collections.Generic.List[PSCustomObject]]$allResults = @()
    $nextLink = $Uri
    $requestCount = 0

    do {
        try {
            # Add delay to respect rate limits
            if ($requestCount -gt 0) {
                Start-Sleep -Milliseconds $DelayMs
            }

            $response = Invoke-MgGraphRequest -Uri $nextLink -Method GET
            $requestCount++

            if ($null -ne $response.value) {
                $response.value | ForEach-Object {
                    $allResults.Add($_)
                }
            }
            else {
                $allResults.Add($response)
            }

            $nextLink = $response.'@odata.nextLink'
        }
        catch {
            if ($_.Exception.Message -like "*429*" -or $_.Exception.Message -like "*throttled*") {
                Write-Information "`nRate limit hit, waiting 60 seconds..." -InformationAction Continue
                Start-Sleep -Seconds 60
                continue
            }
            throw "Error fetching data from $nextLink : $($_.Exception.Message)"
        }
    } while ($nextLink)

    return $allResults
}

# Function to trigger device wipe
function Invoke-DeviceWipe {
    param(
        [string]$DeviceId,
        [string]$DeviceName,
        [string]$WipeType,
        [bool]$KeepEnrollmentData,
        [string]$PIN,
        [string]$OperatingSystem
    )

    $script:LastWipeError = ''

    try {
        # Prepare wipe request body
        $wipeBody = @{
            keepEnrollmentData = $KeepEnrollmentData
        }

        # Add PIN if provided for full wipe (macOsUnlockCode applies to macOS devices only)
        if ($WipeType -eq 'Full' -and -not [string]::IsNullOrEmpty($PIN)) {
            if ($OperatingSystem -eq 'macOS') {
                $wipeBody['useProtectedWipe'] = $true
                $wipeBody['macOsUnlockCode'] = $PIN
            }
            else {
                Write-Warning "PIN applies only to macOS devices and will be ignored for $DeviceName ($OperatingSystem)"
            }
        }

        # Determine endpoint based on wipe type
        if ($WipeType -eq 'Selective') {
            $wipeUri = "https://graph.microsoft.com/beta/deviceManagement/managedDevices('$DeviceId')/retire"
        }
        else {
            $wipeUri = "https://graph.microsoft.com/beta/deviceManagement/managedDevices('$DeviceId')/wipe"
        }

        Invoke-MgGraphRequest -Uri $wipeUri -Method POST -Body ($wipeBody | ConvertTo-Json)
        Write-Information "[OK] $WipeType wipe initiated for device: $DeviceName" -InformationAction Continue
        return $true
    }
    catch {
        if ($_.Exception.Message -like "*429*" -or $_.Exception.Message -like "*throttled*") {
            Write-Information "Rate limit hit for device $DeviceName, waiting 60 seconds before retry..." -InformationAction Continue
            Start-Sleep -Seconds 60
            try {
                Invoke-MgGraphRequest -Uri $wipeUri -Method POST -Body ($wipeBody | ConvertTo-Json)
                Write-Information "[OK] $WipeType wipe initiated for device: $DeviceName" -InformationAction Continue
                return $true
            }
            catch {
                $script:LastWipeError = "After retry: $($_.Exception.Message)"
                Write-Information "[FAIL] Failed to wipe device $DeviceName after retry: $($_.Exception.Message)" -InformationAction Continue
                return $false
            }
        }
        $script:LastWipeError = $_.Exception.Message
        Write-Information "[FAIL] Failed to wipe device $DeviceName : $($_.Exception.Message)" -InformationAction Continue
        return $false
    }
}

# Function to get devices by Entra ID group
function Get-DevicesByEntraGroup {
    param([string]$GroupName)

    try {
        Write-Information "Finding Entra ID group: $GroupName..." -InformationAction Continue

        # Find the group
        $escapedGroupName = $GroupName -replace "'", "''"
        $groupUri = "https://graph.microsoft.com/beta/groups?`$filter=displayName eq '$escapedGroupName'"
        $groups = @(Get-MgGraphAllPage -Uri $groupUri)

        if ($groups.Count -eq 0) {
            throw "Group '$GroupName' not found"
        }
        elseif ($groups.Count -gt 1) {
            throw "Multiple groups found with name '$GroupName'. Please use a more specific name."
        }

        $group = $groups[0]
        Write-Information "[OK] Found group: $($group.displayName) (ID: $($group.id))" -InformationAction Continue

        # Get group members
        Write-Information "Retrieving group members..." -InformationAction Continue
        $membersUri = "https://graph.microsoft.com/beta/groups/$($group.id)/members"
        $members = @(Get-MgGraphAllPage -Uri $membersUri)

        # Split members by type: device members are targeted directly, user members by the devices they own
        $deviceMembers = @($members | Where-Object { $_.'@odata.type' -eq '#microsoft.graph.device' })
        $userMembers = @($members | Where-Object { $_.'@odata.type' -eq '#microsoft.graph.user' })
        $otherMemberCount = $members.Count - $deviceMembers.Count - $userMembers.Count

        Write-Information "[OK] Found $($members.Count) members in group: $($deviceMembers.Count) device(s), $($userMembers.Count) user(s)" -InformationAction Continue
        if ($otherMemberCount -gt 0) {
            Write-Warning "$otherMemberCount member(s) are neither devices nor users (for example nested groups) and are ignored. Nested groups are not expanded."
        }

        # Get all managed devices
        Write-Information "Retrieving managed devices..." -InformationAction Continue
        $devicesUri = "https://graph.microsoft.com/beta/deviceManagement/managedDevices?`$select=id,deviceName,serialNumber,azureADDeviceId,userPrincipalName,operatingSystem,osVersion,model,lastSyncDateTime"
        $allDevices = @(Get-MgGraphAllPage -Uri $devicesUri)

        # Index managed devices by Entra device ID and by primary user UPN (hashtable keys are case-insensitive)
        $emptyGuid = '00000000-0000-0000-0000-000000000000'
        $devicesByEntraDeviceId = @{}
        $devicesByUpn = @{}
        foreach ($device in $allDevices) {
            $entraDeviceId = [string]$device.azureADDeviceId
            if ($entraDeviceId -and $entraDeviceId -ne $emptyGuid) {
                if (-not $devicesByEntraDeviceId.ContainsKey($entraDeviceId)) { $devicesByEntraDeviceId[$entraDeviceId] = [System.Collections.Generic.List[object]]::new() }
                $devicesByEntraDeviceId[$entraDeviceId].Add($device)
            }
            $upn = [string]$device.userPrincipalName
            if ($upn) {
                if (-not $devicesByUpn.ContainsKey($upn)) { $devicesByUpn[$upn] = [System.Collections.Generic.List[object]]::new() }
                $devicesByUpn[$upn].Add($device)
            }
        }

        [System.Collections.Generic.List[PSCustomObject]]$targetDevices = @()
        $targetIds = @{}
        $fromDeviceMembers = 0
        $fromUserMembers = 0

        # Device members: Entra device object's deviceId equals the Intune record's azureADDeviceId
        [System.Collections.Generic.List[string]]$notInIntune = @()
        foreach ($member in $deviceMembers) {
            $entraDeviceId = [string]$member.deviceId
            if (-not $entraDeviceId) {
                Write-Warning "Device member $($member.displayName) [$($member.id)] returned no deviceId. Check that the Device.Read.All permission is granted."
                continue
            }
            if (-not $devicesByEntraDeviceId.ContainsKey($entraDeviceId)) {
                $notInIntune.Add([string]$member.displayName)
                continue
            }

            # Several Intune records for one Entra device are stale re-enrollments: target only the most recently synced one
            $sortedDevices = @($devicesByEntraDeviceId[$entraDeviceId] | Sort-Object -Property { if ($_.lastSyncDateTime) { [DateTime]$_.lastSyncDateTime } else { [DateTime]::MinValue } } -Descending)
            $device = $sortedDevices[0]
            if ($sortedDevices.Count -gt 1) {
                $skipped = ($sortedDevices | Select-Object -Skip 1 | ForEach-Object { "$($_.deviceName) [$($_.id), last sync $($_.lastSyncDateTime)]" }) -join '; '
                Write-Warning "Device $($member.displayName) has $($sortedDevices.Count) Intune records. Targeting the most recently synced one; skipped: $skipped"
            }
            if (-not $targetIds.ContainsKey($device.id)) {
                $targetIds[$device.id] = $true
                $targetDevices.Add($device)
                $fromDeviceMembers++
            }
        }

        if ($notInIntune.Count -gt 0) {
            Write-Warning "$($notInIntune.Count) device member(s) have no Intune record and will not be wiped: $($notInIntune -join ', ')"
        }

        # User members: every managed device whose primary user is in the group (previous behaviour)
        foreach ($member in $userMembers) {
            $keys = @([string]$member.userPrincipalName, [string]$member.mail) | Where-Object { $_ } | Select-Object -Unique
            foreach ($key in $keys) {
                if (-not $devicesByUpn.ContainsKey($key)) { continue }
                foreach ($device in $devicesByUpn[$key]) {
                    if (-not $targetIds.ContainsKey($device.id)) {
                        $targetIds[$device.id] = $true
                        $targetDevices.Add($device)
                        $fromUserMembers++
                    }
                }
            }
        }

        Write-Information "[OK] Found $($targetDevices.Count) managed device(s): $fromDeviceMembers from device members, $fromUserMembers from user members' devices" -InformationAction Continue
        return $targetDevices
    }
    catch {
        throw "Failed to get devices by Entra ID group: $($_.Exception.Message)"
    }
}

# Function to display device information
function Show-DeviceDetail {
    param([array]$Devices)

    Write-Information "`nDEVICE DETAILS" -InformationAction Continue
    Write-Information "=================" -InformationAction Continue

    foreach ($device in $Devices) {
        $lastSeen = if ($device.lastSyncDateTime) {
            [DateTime]$device.lastSyncDateTime
        }
        else {
            "Never"
        }

        Write-Information "Device: $($device.deviceName)" -InformationAction Continue
        Write-Information "  User: $($device.userPrincipalName)" -InformationAction Continue
        Write-Information "  OS: $($device.operatingSystem) $($device.osVersion)" -InformationAction Continue
        Write-Information "  Model: $($device.model)" -InformationAction Continue
        Write-Information "  Serial: $($device.serialNumber)" -InformationAction Continue
        Write-Information "  Last Seen: $lastSeen" -InformationAction Continue
        Write-Information "  ID: $($device.id)" -InformationAction Continue
        Write-Information "" -InformationAction Continue
    }
}

# ============================================================================
# EXPORT SETUP (local runs only)
# ============================================================================

# One row per target device; the Result column is filled in as the run progresses and written out in the finally block
[System.Collections.Generic.List[PSCustomObject]]$exportRows = @()
$exportCsvFile = $null
$transcriptStarted = $false

if (-not $IsAzureAutomation) {
    try {
        if (-not (Test-Path -Path $ExportPath -PathType Container)) {
            New-Item -Path $ExportPath -ItemType Directory -Force -ErrorAction Stop | Out-Null
        }
        $runStamp = Get-Date -Format 'yyyyMMdd-HHmmss'
        $runLabel = if ($TargetMode -eq 'AutopilotCleanup') { 'AutopilotCleanup' } elseif ($DryRun) { "$($WipeType)_DryRun" } else { $WipeType }
        $exportBaseName = "Wipe-Devices_$($runStamp)_$runLabel"
        # Cleanup mode updates the CSV it was given, so it can be run again until every record is removed
        $exportCsvFile = if ($TargetMode -eq 'AutopilotCleanup') { $AutopilotCleanupCsv } else { Join-Path $ExportPath "$exportBaseName.csv" }

        Start-Transcript -Path (Join-Path $ExportPath "$exportBaseName.log") -ErrorAction Stop | Out-Null
        $transcriptStarted = $true
        Write-Output "Logging to $ExportPath"
    }
    catch {
        Write-Warning "Export folder '$ExportPath' is not usable, so no CSV or log will be written: $($_.Exception.Message)"
        $exportCsvFile = $null
    }
}

function Set-ExportResult {
    param([string]$Result, [string]$DeviceId, [string]$ErrorMessage = '')

    foreach ($row in $exportRows) {
        if (-not $DeviceId -or $row.IntuneDeviceId -eq $DeviceId) {
            $row.Result = $Result
            $row.Error = $ErrorMessage
            $row.Timestamp = (Get-Date).ToString('yyyy-MM-dd HH:mm:ss')
        }
    }
}

function Save-ExportFile {
    param([switch]$Quiet)

    if (-not $exportCsvFile -or $exportRows.Count -eq 0) { return }
    try {
        $exportRows | Export-Csv -Path $exportCsvFile -NoTypeInformation -Encoding UTF8 -ErrorAction Stop
        if (-not $Quiet) {
            Write-Output "[OK] Exported $($exportRows.Count) device row(s) to $exportCsvFile"
        }
    }
    catch {
        Write-Warning "Could not write export to $exportCsvFile : $($_.Exception.Message)"
    }
}

function Test-GraphNotFound {
    param($ErrorRecord)
    return ("$($ErrorRecord.Exception.Message)" -match 'NotFound|Not Found|404|ResourceNotFound')
}

function Get-AutopilotIdentity {
    <#
    .SYNOPSIS
    Finds the Windows Autopilot record for a serial number. Returns @{ Identity; Status }.
    #>
    param([string]$SerialNumber, [string]$ManagedDeviceId)

    if ([string]::IsNullOrWhiteSpace($SerialNumber)) {
        return @{ Identity = $null; Status = 'No serial number - skipped' }
    }

    try {
        $escapedSerial = $SerialNumber -replace "'", "''"
        $autopilotUri = "https://graph.microsoft.com/beta/deviceManagement/windowsAutopilotDeviceIdentities?`$filter=contains(serialNumber,'$escapedSerial')"
        # contains() can match longer serials, so keep exact matches only
        $found = @(Get-MgGraphAllPage -Uri $autopilotUri | Where-Object { [string]$_.serialNumber -eq $SerialNumber })
    }
    catch {
        return @{ Identity = $null; Status = "Lookup failed: $($_.Exception.Message)" }
    }

    if ($found.Count -eq 0) {
        return @{ Identity = $null; Status = 'No Autopilot record' }
    }
    if ($ManagedDeviceId) {
        $linked = @($found | Where-Object { $_.managedDeviceId -eq $ManagedDeviceId })
        if ($linked.Count -eq 1) {
            return @{ Identity = $linked[0]; Status = 'Found' }
        }
    }
    if ($found.Count -eq 1) {
        return @{ Identity = $found[0]; Status = 'Found' }
    }
    return @{ Identity = $null; Status = "Ambiguous - $($found.Count) Autopilot records with this serial, remove manually" }
}

function Set-AutopilotLookup {
    <#
    .SYNOPSIS
    Fills AutopilotId / AutopilotResult on export rows that do not have an Autopilot record yet.
    #>
    param([object[]]$Rows)

    foreach ($row in $Rows) {
        if ($row.AutopilotId) { continue }
        if ($row.OperatingSystem -and $row.OperatingSystem -ne 'Windows') {
            $row.AutopilotResult = 'Not Windows - skipped'
            continue
        }
        $lookup = Get-AutopilotIdentity -SerialNumber $row.SerialNumber -ManagedDeviceId $row.IntuneDeviceId
        if ($lookup.Identity) {
            $row.AutopilotId = $lookup.Identity.id
            $row.AutopilotResult = 'Pending removal'
        }
        else {
            $row.AutopilotResult = $lookup.Status
        }
        Write-Output "  $($row.DeviceName) ($($row.SerialNumber)): $($row.AutopilotResult)"
    }
}

function Invoke-AutopilotRemoval {
    <#
    .SYNOPSIS
    Waits for each wiped device to leave Intune, then deletes its Autopilot record.
    A device counts as gone when its wiped Intune record returns 404 and no other Intune record has its serial.
    #>
    param(
        [object[]]$Rows,
        [int]$WaitMinutes,
        [int]$PollSeconds
    )

    $pending = [System.Collections.Generic.List[object]]::new()
    foreach ($row in $Rows) { $pending.Add($row) }
    $deadline = (Get-Date).AddMinutes($WaitMinutes)

    while ($pending.Count -gt 0) {
        foreach ($row in @($pending)) {
            # 1. Is the wiped Intune record still there? Then the wipe has not been picked up or finished yet.
            try {
                Invoke-MgGraphRequest -Method GET -Uri "https://graph.microsoft.com/beta/deviceManagement/managedDevices/$($row.IntuneDeviceId)?`$select=id" | Out-Null
                continue
            }
            catch {
                if (-not (Test-GraphNotFound $_)) {
                    Write-Warning "Could not check $($row.DeviceName) in Intune, will retry: $($_.Exception.Message)"
                    continue
                }
            }

            # 2. Has the device already re-enrolled under a new Intune record?
            try {
                $escapedSerial = ([string]$row.SerialNumber) -replace "'", "''"
                $current = @(Get-MgGraphAllPage -Uri "https://graph.microsoft.com/beta/deviceManagement/managedDevices?`$filter=serialNumber eq '$escapedSerial'&`$select=id,deviceName")
            }
            catch {
                Write-Warning "Could not check serial $($row.SerialNumber) in Intune, will retry: $($_.Exception.Message)"
                continue
            }
            if ($current.Count -gt 0) {
                $row.AutopilotResult = "Not removed - device re-enrolled in Intune as $($current[0].deviceName); remove manually if still needed"
                Write-Warning "$($row.DeviceName) ($($row.SerialNumber)) has re-enrolled in Intune; its Autopilot record was left in place"
                [void]$pending.Remove($row)
                continue
            }

            # 3. Gone from Intune: delete the Autopilot record
            try {
                Invoke-MgGraphRequest -Method DELETE -Uri "https://graph.microsoft.com/beta/deviceManagement/windowsAutopilotDeviceIdentities/$($row.AutopilotId)" | Out-Null
                $row.AutopilotResult = 'Removed'
                Write-Output "[OK] Removed Autopilot record for $($row.DeviceName) ($($row.SerialNumber))"
                [void]$pending.Remove($row)
            }
            catch {
                if (Test-GraphNotFound $_) {
                    $row.AutopilotResult = 'Already removed'
                    Write-Output "[OK] Autopilot record for $($row.DeviceName) ($($row.SerialNumber)) was already removed"
                    [void]$pending.Remove($row)
                }
                elseif ($_.Exception.Message -like "*429*" -or $_.Exception.Message -like "*throttled*") {
                    Write-Warning "Throttled removing Autopilot record for $($row.DeviceName), will retry"
                }
                else {
                    $row.AutopilotResult = "Failed: $($_.Exception.Message)"
                    Write-Information "[FAIL] Could not remove Autopilot record for $($row.DeviceName): $($_.Exception.Message)" -InformationAction Continue
                    [void]$pending.Remove($row)
                }
            }
        }

        Save-ExportFile -Quiet

        if ($pending.Count -eq 0) { break }
        if ((Get-Date).AddSeconds($PollSeconds) -gt $deadline) { break }

        Write-Output "Waiting for $($pending.Count) device(s) to pick up the wipe and leave Intune. Next check in $PollSeconds s; giving up at $($deadline.ToString('HH:mm'))."
        Start-Sleep -Seconds $PollSeconds
    }

    foreach ($row in $pending) {
        $row.AutopilotResult = "Not removed - still in Intune after $WaitMinutes min; run again with -AutopilotCleanupCsv"
    }
}

function Write-AutopilotSummary {
    $autopilotRows = @($exportRows | Where-Object { $_.AutopilotResult })
    if ($autopilotRows.Count -eq 0) { return }

    $removed = @($autopilotRows | Where-Object { $_.AutopilotResult -in @('Removed', 'Already removed') }).Count
    $failed = @($autopilotRows | Where-Object { $_.AutopilotResult -like 'Failed*' }).Count
    $waiting = @($autopilotRows | Where-Object { $_.AutopilotResult -like 'Not removed - still in Intune*' }).Count
    $other = $autopilotRows.Count - $removed - $failed - $waiting

    Write-Output "`nAUTOPILOT SUMMARY"
    Write-Output "========================="
    Write-Output "Removed: $removed"
    Write-Output "Failed: $failed"
    Write-Output "Still in Intune (not removed yet): $waiting"
    Write-Output "Skipped (no record, not Windows, re-enrolled, ambiguous or not wiped): $other"
    if ($waiting -gt 0 -and $exportCsvFile) {
        Write-Output "To finish later: .\Wipe-Devices-V1.ps1 -AutopilotCleanupCsv `"$exportCsvFile`""
    }
}

# ============================================================================
# MAIN SCRIPT LOGIC
# ============================================================================

try {
    # Cleanup-only mode: finish Autopilot removals for devices wiped in an earlier run
    if ($TargetMode -eq 'AutopilotCleanup') {
        Write-Output "Autopilot cleanup from $AutopilotCleanupCsv"
        foreach ($row in @(Import-Csv -Path $AutopilotCleanupCsv)) {
            foreach ($column in @('AutopilotId', 'AutopilotResult')) {
                if ($row.PSObject.Properties.Name -notcontains $column) {
                    $row | Add-Member -NotePropertyName $column -NotePropertyValue ''
                }
            }
            $exportRows.Add($row)
        }

        $candidates = @($exportRows | Where-Object {
                $_.Result -eq 'Wipe initiated' -and
                $_.AutopilotResult -notin @('Removed', 'Already removed') -and
                $_.AutopilotResult -ne 'Not Windows - skipped'
            })
        if ($candidates.Count -eq 0) {
            Write-Output "Nothing to do: no wiped devices in this CSV still need their Autopilot record removed."
            exit 0
        }

        Write-Output "`nLooking up Windows Autopilot records for $($candidates.Count) wiped device(s)..."
        Set-AutopilotLookup -Rows @($candidates | Where-Object { -not $_.AutopilotId })
        $toRemove = @($candidates | Where-Object { $_.AutopilotId })
        if ($toRemove.Count -gt 0) {
            Invoke-AutopilotRemoval -Rows $toRemove -WaitMinutes $AutopilotWaitMinutes -PollSeconds $AutopilotPollSeconds
        }

        Write-AutopilotSummary
        $autopilotFailures = @($exportRows | Where-Object { $_.AutopilotResult -like 'Failed*' }).Count
        if ($autopilotFailures -gt 0) { exit 1 }
        exit 0
    }

    # Get target devices based on parameter set
    $targetDevices = @()

    switch ($TargetMode) {
        'DeviceNames' {
            Write-Output "Retrieving devices by names..."
            $devicesUri = "https://graph.microsoft.com/beta/deviceManagement/managedDevices?`$select=id,deviceName,serialNumber,azureADDeviceId,userPrincipalName,operatingSystem,osVersion,model,lastSyncDateTime"
            $allDevices = @(Get-MgGraphAllPage -Uri $devicesUri)

            foreach ($deviceName in $DeviceNames) {
                $matchingDevices = $allDevices | Where-Object { $_.deviceName -eq $deviceName }
                if ($matchingDevices) {
                    $targetDevices += $matchingDevices
                    Write-Output "[OK] Found device: $deviceName"
                }
                else {
                    Write-Warning "Device not found: $deviceName"
                }
            }
        }

        'SerialNumbers' {
            Write-Output "Retrieving devices by serial numbers..."
            foreach ($serialNumber in $SerialNumbers) {
                $escapedSerial = $serialNumber -replace "'", "''"
                $serialUri = "https://graph.microsoft.com/beta/deviceManagement/managedDevices?`$filter=serialNumber eq '$escapedSerial'&`$select=id,deviceName,serialNumber,azureADDeviceId,userPrincipalName,operatingSystem,osVersion,model,lastSyncDateTime"
                $matchingDevices = @(Get-MgGraphAllPage -Uri $serialUri)

                if ($matchingDevices.Count -eq 0) {
                    Write-Warning "Device not found with serial number: $serialNumber"
                    continue
                }

                # Duplicate Intune records for one serial are usually stale re-enrollments: wipe only the most recently synced one
                $sortedDevices = @($matchingDevices | Sort-Object -Property { if ($_.lastSyncDateTime) { [DateTime]$_.lastSyncDateTime } else { [DateTime]::MinValue } } -Descending)
                $device = $sortedDevices[0]
                if ($targetDevices | Where-Object { $_.id -eq $device.id }) { continue }
                $targetDevices += $device
                Write-Output "[OK] Found device: $($device.deviceName) (Serial: $serialNumber)"

                if ($sortedDevices.Count -gt 1) {
                    $skipped = ($sortedDevices | Select-Object -Skip 1 | ForEach-Object { "$($_.deviceName) [$($_.id), last sync $($_.lastSyncDateTime)]" }) -join '; '
                    Write-Warning "Serial $serialNumber has $($sortedDevices.Count) Intune records. Targeting the most recently synced one; skipped: $skipped"
                }
            }
        }

        'DeviceIds' {
            Write-Output "Retrieving devices by IDs..."
            foreach ($deviceId in $DeviceIds) {
                try {
                    $deviceUri = "https://graph.microsoft.com/beta/deviceManagement/managedDevices/$deviceId`?`$select=id,deviceName,serialNumber,azureADDeviceId,userPrincipalName,operatingSystem,osVersion,model,lastSyncDateTime"
                    $device = Invoke-MgGraphRequest -Uri $deviceUri -Method GET
                    $targetDevices += $device
                    Write-Output "[OK] Found device: $($device.deviceName)"
                }
                catch {
                    Write-Warning "Device not found with ID: $deviceId"
                }
            }
        }

        'EntraGroup' {
            $targetDevices = @(Get-DevicesByEntraGroup -GroupName $EntraGroupName)
        }
    }

    if ($targetDevices.Count -eq 0) {
        Write-Output "No target devices found. No wipe action is required."
        exit 0
    }

    # Display target information
    Write-Output "`nDEVICE WIPE OPERATION"
    Write-Output "========================="
    Write-Output "Wipe Type: $WipeType"
    Write-Output "Total devices to process: $($targetDevices.Count)"
    Write-Output "Keep Enrollment Data: $KeepEnrollmentData"

    if ($WipeType -eq 'Full') {
        Write-Output "WARNING: Full wipe will completely erase all data on these devices!"
    }
    else {
        Write-Output "Selective wipe will remove only company data and apps"
    }

    # Show device details
    Show-DeviceDetail -Devices $targetDevices

    $targetDescription = switch ($TargetMode) {
        'DeviceNames'   { "DeviceNames: $($DeviceNames -join ', ')" }
        'SerialNumbers' { "SerialNumbers: $($SerialNumbers -join ', ')" }
        'DeviceIds'     { "DeviceIds: $($DeviceIds -join ', ')" }
        'EntraGroup'    { "EntraGroup: $EntraGroupName" }
    }
    foreach ($device in $targetDevices) {
        $exportRows.Add([PSCustomObject]@{
            Timestamp          = (Get-Date).ToString('yyyy-MM-dd HH:mm:ss')
            DeviceName         = $device.deviceName
            SerialNumber       = $device.serialNumber
            UserPrincipalName  = $device.userPrincipalName
            OperatingSystem    = $device.operatingSystem
            OSVersion          = $device.osVersion
            Model              = $device.model
            LastSync           = $device.lastSyncDateTime
            IntuneDeviceId     = $device.id
            EntraDeviceId      = $device.azureADDeviceId
            WipeType           = $WipeType
            KeepEnrollmentData = $KeepEnrollmentData
            Target             = $targetDescription
            Result             = 'Not processed'
            Error              = ''
            AutopilotId        = ''
            AutopilotResult    = ''
        })
    }

    if ($RemoveAutopilot) {
        Write-Output "`nLooking up Windows Autopilot records..."
        Set-AutopilotLookup -Rows $exportRows
        $autopilotPlanned = @($exportRows | Where-Object { $_.AutopilotId }).Count
        Write-Output "Autopilot records to remove once their device has left Intune: $autopilotPlanned of $($exportRows.Count)"
    }

    if ($DryRun) {
        Set-ExportResult -Result 'Dry run - not wiped'
        foreach ($row in $exportRows) {
            if ($row.AutopilotId) { $row.AutopilotResult = 'Dry run - would remove after wipe' }
        }
        Write-Output "[OK] Dry run completed. No wipe actions were sent."
        exit 0
    }

    # Confirmation prompt for local runs unless Force or WhatIf is specified
    # (Azure Automation without -Force already exited during environment detection)
    if (-not $Force -and -not $WhatIfPreference) {
        Write-Output "`nCONFIRMATION REQUIRED"
        Write-Output "This operation will perform a $($WipeType.ToLower()) wipe on $($targetDevices.Count) device(s)."

        if ($WipeType -eq 'Full') {
            Write-Output "WARNING: THIS WILL PERMANENTLY DELETE ALL DATA ON THE DEVICES!"
        }
        if ($RemoveAutopilot) {
            Write-Output "WARNING: The Autopilot records of $autopilotPlanned device(s) will then be deleted. Re-registering them needs their hardware hash again."
        }

        $confirmation = Read-Host "`nType 'CONFIRM' to proceed with the wipe operation"

        if ($confirmation -ne 'CONFIRM') {
            Write-Output "Operation cancelled by user."
            Set-ExportResult -Result 'Cancelled by user'
            exit 0
        }
    }

    # Process wipe operations
    $successfulWipes = 0
    $failedWipes = 0
    $processedDevices = 0

    Write-Output "`nProcessing device wipe operations..."

    foreach ($device in $targetDevices) {
        $processedDevices++
        Write-Progress -Activity "Wiping Devices" -Status "Processing device $processedDevices of $($targetDevices.Count): $($device.deviceName)" -PercentComplete (($processedDevices / $targetDevices.Count) * 100)

        if ($PSCmdlet.ShouldProcess($device.deviceName, "$WipeType wipe")) {
            $wipeSuccessful = Invoke-DeviceWipe -DeviceId $device.id -DeviceName $device.deviceName -WipeType $WipeType -KeepEnrollmentData $KeepEnrollmentData -PIN $PIN -OperatingSystem $device.operatingSystem

            if ($wipeSuccessful) {
                $successfulWipes++
                Set-ExportResult -DeviceId $device.id -Result 'Wipe initiated'
            }
            else {
                $failedWipes++
                Set-ExportResult -DeviceId $device.id -Result 'Failed' -ErrorMessage $script:LastWipeError
            }
        }
        else {
            Set-ExportResult -DeviceId $device.id -Result 'WhatIf - not wiped'
        }

        # Add delay between wipe operations
        if ($processedDevices -lt $targetDevices.Count) {
            Start-Sleep -Seconds $WipeDelaySeconds
        }
    }

    Write-Progress -Activity "Wiping Devices" -Completed

    # Devices whose wipe was not sent keep their Autopilot record
    foreach ($row in $exportRows) {
        if ($row.AutopilotResult -eq 'Pending removal' -and $row.Result -ne 'Wipe initiated') {
            $row.AutopilotResult = "Not removed - $($row.Result)"
        }
    }
    Save-ExportFile -Quiet

    # Display wipe summary
    Write-Output "`nWIPE OPERATION SUMMARY"
    Write-Output "========================="
    Write-Output "Wipe Type: $WipeType"
    Write-Output "Total Devices Processed: $($targetDevices.Count)"
    Write-Output "Successful Wipes: $successfulWipes"
    Write-Output "Failed Wipes: $failedWipes"

    if ($failedWipes -gt 0) {
        Write-Output "`nFailed wipe operations require manual review."
    }
    if ($successfulWipes -gt 0) {
        Write-Output "`n$successfulWipes device(s) have been scheduled for $($WipeType.ToLower()) wipe."
        Write-Output "Note: Wipe operations may take several minutes to complete on the devices."
    }

    # Autopilot removal for devices whose wipe was sent
    $autopilotFailures = 0
    if ($RemoveAutopilot) {
        $toRemove = @($exportRows | Where-Object { $_.AutopilotResult -eq 'Pending removal' })
        if ($toRemove.Count -gt 0) {
            Write-Output "`nAUTOPILOT CLEANUP"
            Write-Output "========================="
            Write-Output "Waiting up to $AutopilotWaitMinutes min for $($toRemove.Count) device(s) to pick up the wipe and leave Intune (checking every $AutopilotPollSeconds s)..."
            Invoke-AutopilotRemoval -Rows $toRemove -WaitMinutes $AutopilotWaitMinutes -PollSeconds $AutopilotPollSeconds
        }
        Write-AutopilotSummary
        $autopilotFailures = @($exportRows | Where-Object { $_.AutopilotResult -like 'Failed*' }).Count
    }

    Write-Output "`nDevice wipe operation completed!"

    if ($failedWipes -gt 0 -or $autopilotFailures -gt 0) {
        exit 1
    }

}
catch {
    Write-Error "Script execution failed: $($_.Exception.Message)"
    exit 1
}
finally {
    # Write the CSV export (rows still 'Not processed' mean the run stopped before reaching them)
    Save-ExportFile

    # Disconnect from Microsoft Graph
    try {
        if (Get-MgContext) {
            Disconnect-MgGraph -ErrorAction SilentlyContinue | Out-Null
            Write-Output "[OK] Disconnected from Microsoft Graph"
        }
    }
    catch {
        # Ignore disconnection errors - this is expected behavior when already disconnected
        Write-Verbose "Graph disconnection completed (may have already been disconnected)"
    }

    if ($transcriptStarted) {
        Stop-Transcript | Out-Null
    }
}