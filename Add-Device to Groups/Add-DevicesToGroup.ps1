<#
  Adds devices to an Entra group by hostname.
  Entra bulk import only accepts object IDs, so this looks up each hostname's
  Entra device object and adds it to the group.

  Usage:
    .\Add-DevicesToGroup.ps1 -CsvPath .\Year12_PrimaryDevice_Hostnames.csv            # dry run
    .\Add-DevicesToGroup.ps1 -CsvPath .\Year12_PrimaryDevice_Hostnames.csv -Apply     # make changes

  If a hostname matches more than one Entra device (stale re-enrolment), only the
  device with the most recent sign-in is added; the others are listed in the report.
#>
param(
    [Parameter(Mandatory)] [string]$CsvPath,
    [string]$GroupId = '25613d16-4236-4627-b487-e891222df396',
    [switch]$Apply
)

if (-not (Get-Module -ListAvailable Microsoft.Graph.Identity.DirectoryManagement)) {
    Install-Module Microsoft.Graph -Scope CurrentUser -Force
}
Connect-MgGraph -Scopes 'Device.Read.All','GroupMember.ReadWrite.All' -NoWelcome

$existing = @{}
Get-MgGroupMember -GroupId $GroupId -All | ForEach-Object { $existing[$_.Id] = $true }

$report = foreach ($row in Import-Csv $CsvPath) {
    $name = $row.DeviceName.Trim()
    if (-not $name) { continue }
    $safe = $name.Replace("'", "''")
    $devices = @(Get-MgDevice -Filter "displayName eq '$safe'" -All `
        -Property Id,DisplayName,ApproximateLastSignInDateTime |
        Sort-Object ApproximateLastSignInDateTime -Descending)

    if ($devices.Count -eq 0) {
        [pscustomobject]@{ DeviceName=$name; ObjectId=''; Status='Not found in Entra'; Note='' }
        continue
    }

    $pick  = $devices[0]
    $note  = if ($devices.Count -gt 1) { "Skipped $($devices.Count - 1) older duplicate(s): " + (($devices | Select-Object -Skip 1).Id -join ', ') } else { '' }

    if ($existing.ContainsKey($pick.Id)) {
        $status = 'Already a member'
    } elseif ($Apply) {
        try {
            New-MgGroupMember -GroupId $GroupId -DirectoryObjectId $pick.Id -ErrorAction Stop
            $status = 'Added'
        } catch { $status = "Failed: $($_.Exception.Message)" }
    } else {
        $status = 'Would add (dry run)'
    }
    [pscustomobject]@{ DeviceName=$name; ObjectId=$pick.Id; Status=$status; Note=$note }
}

$out = Join-Path (Split-Path $CsvPath) 'AddDevicesToGroup_Report.csv'
$report | Export-Csv $out -NoTypeInformation -Encoding UTF8
$report | Group-Object Status | Select-Object Name, Count | Format-Table -AutoSize
Write-Host "Report written to $out"