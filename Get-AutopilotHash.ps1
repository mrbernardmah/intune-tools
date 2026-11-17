<#
.SYNOPSIS
    Autopilot hardware-hash capture tool for use during OOBE (GUI or command line).

.DESCRIPTION
    Automates the manual OOBE steps:
        mkdir C:\temp
        Save-Script -Name Get-WindowsAutopilotInfo -Path C:\temp   (installs NuGet provider)
        Set-ExecutionPolicy Bypass
        .\Get-WindowsAutopilotInfo.ps1 -OutputFile C:\temp\<file>.csv
        start msedge
    ...and adds: copy CSV to USB, optional direct upload to Intune (-Online), and logging.

.USAGE (OOBE)
    Shift+F10 (or Fn+Shift+F10) at any OOBE screen, then:
        powershell -ExecutionPolicy Bypass -File D:\Get-AutopilotHashOOBE.ps1
    or just run Start-AutopilotOOBE.cmd from the USB stick.

.EXAMPLE
    # Headless, capture only
    .\Get-AutopilotHashOOBE.ps1 -NoGui

.EXAMPLE
    # Headless, capture + upload straight to Intune with a group tag
    .\Get-AutopilotHashOOBE.ps1 -NoGui -GroupTag "VSG-Standard" -Online
#>
[CmdletBinding()]
param(
    [switch]$NoGui,
    [string]$WorkDir   = 'C:\temp',
    [string]$Prefix    = 'VSG',
    [string]$OutputFile,
    [string]$GroupTag,
    [switch]$Online,
    [switch]$Assign,
    [switch]$CopyToUsb,
    [switch]$OpenEdge,
    [string]$EdgeUrl   = 'https://intune.microsoft.com/#view/Microsoft_Intune_Enrollment/AutopilotDevices.ReactView'
)

$ErrorActionPreference = 'Stop'

# ---------------------------------------------------------------------------
# Elevation (Shift+F10 in OOBE is already elevated, this covers normal use)
# ---------------------------------------------------------------------------
$principal = New-Object Security.Principal.WindowsPrincipal([Security.Principal.WindowsIdentity]::GetCurrent())
if (-not $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
    $argList = @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', "`"$PSCommandPath`"")
    foreach ($kv in $PSBoundParameters.GetEnumerator()) {
        if ($kv.Value -is [switch]) { if ($kv.Value) { $argList += "-$($kv.Key)" } }
        else { $argList += "-$($kv.Key)"; $argList += "`"$($kv.Value)`"" }
    }
    Start-Process powershell.exe -Verb RunAs -ArgumentList $argList
    exit
}

Set-ExecutionPolicy -ExecutionPolicy Bypass -Scope Process -Force
[Net.ServicePointManager]::SecurityProtocol = [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12

if (-not (Test-Path $WorkDir)) { New-Item -Path $WorkDir -ItemType Directory -Force | Out-Null }
$script:LogFile   = Join-Path $WorkDir 'AutopilotOOBE.log'
$script:LogBox    = $null
$script:ApScript  = Join-Path $WorkDir 'Get-WindowsAutopilotInfo.ps1'

# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------
function Write-Log {
    param([Parameter(ValueFromPipeline)][object]$Message, [string]$Level = 'INFO')
    process {
        if ($null -eq $Message) { return }
        $line = '{0} [{1}] {2}' -f (Get-Date -Format 'HH:mm:ss'), $Level, ($Message | Out-String).Trim()
        Add-Content -Path $script:LogFile -Value $line -ErrorAction SilentlyContinue
        if ($script:LogBox) {
            $script:LogBox.AppendText($line + [Environment]::NewLine)
            [System.Windows.Forms.Application]::DoEvents()
        } else {
            $color = switch ($Level) { 'ERROR' { 'Red' } 'WARN' { 'Yellow' } 'OK' { 'Green' } default { 'Gray' } }
            Write-Host $line -ForegroundColor $color
        }
    }
}

function Get-DeviceInfo {
    $bios = Get-CimInstance -ClassName Win32_BIOS
    $cs   = Get-CimInstance -ClassName Win32_ComputerSystem
    [pscustomobject]@{
        Serial       = ($bios.SerialNumber).Trim()
        Manufacturer = ($cs.Manufacturer).Trim()
        Model        = ($cs.Model).Trim()
    }
}

function Test-Internet {
    try {
        $r = Invoke-WebRequest -Uri 'https://www.powershellgallery.com' -UseBasicParsing -Method Head -TimeoutSec 10
        return ($r.StatusCode -lt 400)
    } catch { return $false }
}

function Initialize-Prereqs {
    Write-Log "Working folder: $WorkDir"

    if (-not (Test-Internet)) {
        throw "No internet access to the PowerShell Gallery. Connect to Wi-Fi/Ethernet in OOBE first."
    }

    $nuget = Get-PackageProvider -ListAvailable -ErrorAction SilentlyContinue |
             Where-Object { $_.Name -eq 'NuGet' -and $_.Version -ge [version]'2.8.5.201' }
    if (-not $nuget) {
        Write-Log 'Installing NuGet package provider...'
        Install-PackageProvider -Name NuGet -MinimumVersion 2.8.5.201 -Force -Scope AllUsers | Out-Null
        Write-Log 'NuGet provider installed.' 'OK'
    } else {
        Write-Log "NuGet provider present ($($nuget[0].Version))."
    }

    if ((Get-PSRepository -Name PSGallery).InstallationPolicy -ne 'Trusted') {
        Set-PSRepository -Name PSGallery -InstallationPolicy Trusted
    }

    if (-not (Test-Path $script:ApScript)) {
        Write-Log 'Downloading Get-WindowsAutopilotInfo from PSGallery...'
        Save-Script -Name Get-WindowsAutopilotInfo -Path $WorkDir -Force
        Write-Log 'Get-WindowsAutopilotInfo downloaded.' 'OK'
    } else {
        Write-Log 'Get-WindowsAutopilotInfo already present.'
    }
}

function Invoke-HashCapture {
    param([Parameter(Mandatory)][string]$Path, [string]$Tag)

    Initialize-Prereqs
    $dir = Split-Path $Path -Parent
    if (-not (Test-Path $dir)) { New-Item -Path $dir -ItemType Directory -Force | Out-Null }
    if (Test-Path $Path) { Remove-Item $Path -Force }

    $params = @{ OutputFile = $Path }
    if ($Tag) { $params.GroupTag = $Tag }

    Write-Log "Capturing hardware hash -> $Path"
    & $script:ApScript @params *>&1 | ForEach-Object { Write-Log $_ }

    if (-not (Test-Path $Path)) { throw "CSV was not created: $Path" }
    $row = Import-Csv $Path | Select-Object -First 1
    if (-not $row.'Hardware Hash') { throw 'CSV created but the Hardware Hash column is empty.' }
    Write-Log "Hash captured for serial $($row.'Device Serial Number') ($([math]::Round((Get-Item $Path).Length/1KB,1)) KB)." 'OK'
    return $Path
}

function Invoke-OnlineUpload {
    param([string]$Tag, [switch]$AssignProfile)

    Initialize-Prereqs
    $params = @{ Online = $true }
    if ($Tag)           { $params.GroupTag = $Tag }
    if ($AssignProfile) { $params.Assign   = $true }

    Write-Log 'Uploading to Intune. A Microsoft sign-in window will appear (needs Intune admin rights)...'
    if ($AssignProfile) { Write-Log 'Waiting for profile assignment, this can take 5-15 minutes.' }
    & $script:ApScript @params *>&1 | ForEach-Object { Write-Log $_ }
    Write-Log 'Online upload finished. Check the output above for errors.' 'OK'
}

function Copy-CsvToUsb {
    param([Parameter(Mandatory)][string]$Path)

    if (-not (Test-Path $Path)) { throw "Nothing to copy, CSV not found: $Path" }
    $usb = Get-CimInstance Win32_LogicalDisk -Filter 'DriveType=2' | Select-Object -ExpandProperty DeviceID
    if (-not $usb) { throw 'No removable USB drive found. Insert one and try again.' }

    foreach ($drive in $usb) {
        $dest = Join-Path "$drive\" 'Autopilot'
        if (-not (Test-Path $dest)) { New-Item -Path $dest -ItemType Directory -Force | Out-Null }
        Copy-Item -Path $Path -Destination $dest -Force
        Write-Log "Copied to $dest\$(Split-Path $Path -Leaf)" 'OK'
    }
}

function Open-Edge {
    param([string]$Url = $EdgeUrl)
    Write-Log "Launching Edge: $Url"
    Start-Process 'msedge.exe' -ArgumentList $Url
}

# ---------------------------------------------------------------------------
# Defaults
# ---------------------------------------------------------------------------
$device = Get-DeviceInfo
$safeSerial = ($device.Serial -replace '[^A-Za-z0-9\-]', '')
if (-not $OutputFile) { $OutputFile = Join-Path $WorkDir ("{0}_{1}.csv" -f $Prefix, $safeSerial) }

# ---------------------------------------------------------------------------
# Headless mode
# ---------------------------------------------------------------------------
if ($NoGui) {
    try {
        Write-Log "Device: $($device.Manufacturer) $($device.Model)  Serial: $($device.Serial)"
        Invoke-HashCapture -Path $OutputFile -Tag $GroupTag | Out-Null
        if ($CopyToUsb) { Copy-CsvToUsb -Path $OutputFile }
        if ($Online)    { Invoke-OnlineUpload -Tag $GroupTag -AssignProfile:$Assign }
        if ($OpenEdge)  { Open-Edge }
        Write-Log 'Done.' 'OK'
    } catch {
        Write-Log $_.Exception.Message 'ERROR'
        exit 1
    }
    exit 0
}

# ---------------------------------------------------------------------------
# GUI
# ---------------------------------------------------------------------------
Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing
[System.Windows.Forms.Application]::EnableVisualStyles()

$font     = New-Object System.Drawing.Font('Segoe UI', 10)
$fontBold = New-Object System.Drawing.Font('Segoe UI', 10, [System.Drawing.FontStyle]::Bold)

$form = New-Object System.Windows.Forms.Form
$form.Text            = 'Autopilot Hash Capture (OOBE)'
$form.Size            = New-Object System.Drawing.Size(760, 640)
$form.StartPosition   = 'CenterScreen'
$form.FormBorderStyle = 'FixedDialog'
$form.MaximizeBox     = $false
$form.TopMost         = $true          # keep it above the OOBE window
$form.Font            = $font

function New-Label($text, $x, $y, $w = 130, $bold = $false) {
    $l = New-Object System.Windows.Forms.Label
    $l.Text = $text; $l.Location = New-Object System.Drawing.Point($x, $y)
    $l.Size = New-Object System.Drawing.Size($w, 24)
    if ($bold) { $l.Font = $fontBold }
    $form.Controls.Add($l); $l
}
function New-Button($text, $x, $y, $w = 170) {
    $b = New-Object System.Windows.Forms.Button
    $b.Text = $text; $b.Location = New-Object System.Drawing.Point($x, $y)
    $b.Size = New-Object System.Drawing.Size($w, 36)
    $form.Controls.Add($b); $b
}

# Device info
$grp = New-Object System.Windows.Forms.GroupBox
$grp.Text = 'Device'; $grp.Location = New-Object System.Drawing.Point(15, 10)
$grp.Size = New-Object System.Drawing.Size(715, 80)
$form.Controls.Add($grp)
$info = New-Object System.Windows.Forms.Label
$info.Location = New-Object System.Drawing.Point(12, 22)
$info.Size = New-Object System.Drawing.Size(690, 50)
$info.Text = "Serial:  $($device.Serial)`r`nModel:   $($device.Manufacturer) $($device.Model)"
$info.Font = New-Object System.Drawing.Font('Consolas', 10)
$grp.Controls.Add($info)

# Inputs
New-Label 'Output CSV' 15 105 | Out-Null
$txtOut = New-Object System.Windows.Forms.TextBox
$txtOut.Location = New-Object System.Drawing.Point(150, 102)
$txtOut.Size = New-Object System.Drawing.Size(580, 24)
$txtOut.Text = $OutputFile
$form.Controls.Add($txtOut)

New-Label 'Group Tag' 15 140 | Out-Null
$txtTag = New-Object System.Windows.Forms.TextBox
$txtTag.Location = New-Object System.Drawing.Point(150, 137)
$txtTag.Size = New-Object System.Drawing.Size(250, 24)
$txtTag.Text = $GroupTag
$form.Controls.Add($txtTag)

$chkAssign = New-Object System.Windows.Forms.CheckBox
$chkAssign.Text = 'Online: wait for profile assignment'
$chkAssign.Location = New-Object System.Drawing.Point(415, 137)
$chkAssign.Size = New-Object System.Drawing.Size(315, 24)
$chkAssign.Checked = [bool]$Assign
$form.Controls.Add($chkAssign)

# Buttons
$btnCapture = New-Button '1. Capture hash'      15 180 175
$btnUsb     = New-Button '2. Copy CSV to USB'  200 180 175
$btnOnline  = New-Button 'Upload to Intune'    385 180 170
$btnEdge    = New-Button 'Open Edge'           565 180 165
$btnView    = New-Button 'View CSV'             15 222 175
$btnLog     = New-Button 'Open log'            200 222 175
$btnReboot  = New-Button 'Restart device'      385 222 170
$btnClose   = New-Button 'Close'               565 222 165
$btnCapture.Font = $fontBold

# Log
$script:LogBox = New-Object System.Windows.Forms.TextBox
$script:LogBox.Multiline  = $true
$script:LogBox.ReadOnly   = $true
$script:LogBox.ScrollBars = 'Vertical'
$script:LogBox.BackColor  = [System.Drawing.Color]::Black
$script:LogBox.ForeColor  = [System.Drawing.Color]::LightGreen
$script:LogBox.Font       = New-Object System.Drawing.Font('Consolas', 9)
$script:LogBox.Location   = New-Object System.Drawing.Point(15, 270)
$script:LogBox.Size       = New-Object System.Drawing.Size(715, 280)
$form.Controls.Add($script:LogBox)

$status = New-Object System.Windows.Forms.Label
$status.Location = New-Object System.Drawing.Point(15, 560)
$status.Size = New-Object System.Drawing.Size(715, 24)
$status.Text = 'Ready. Make sure the device is connected to the internet.'
$form.Controls.Add($status)

$allButtons = @($btnCapture, $btnUsb, $btnOnline, $btnEdge, $btnView, $btnLog, $btnReboot, $btnClose)

function Invoke-UiAction {
    param([string]$Busy, [scriptblock]$Action)
    $allButtons | ForEach-Object { $_.Enabled = $false }
    $form.Cursor = [System.Windows.Forms.Cursors]::WaitCursor
    $status.Text = $Busy
    $status.ForeColor = [System.Drawing.Color]::DarkBlue
    [System.Windows.Forms.Application]::DoEvents()
    try {
        & $Action
        $status.Text = 'Done.'
        $status.ForeColor = [System.Drawing.Color]::DarkGreen
    } catch {
        Write-Log $_.Exception.Message 'ERROR'
        $status.Text = "Error: $($_.Exception.Message)"
        $status.ForeColor = [System.Drawing.Color]::DarkRed
    } finally {
        $allButtons | ForEach-Object { $_.Enabled = $true }
        $form.Cursor = [System.Windows.Forms.Cursors]::Default
    }
}

$btnCapture.Add_Click({
    Invoke-UiAction 'Capturing hardware hash...' {
        Invoke-HashCapture -Path $txtOut.Text.Trim() -Tag $txtTag.Text.Trim() | Out-Null
    }
})
$btnUsb.Add_Click({
    Invoke-UiAction 'Copying CSV to USB...' { Copy-CsvToUsb -Path $txtOut.Text.Trim() }
})
$btnOnline.Add_Click({
    $msg = "Upload this device straight to Intune?`r`n`r`nYou will be asked to sign in with an account that has Intune admin rights."
    if ([System.Windows.Forms.MessageBox]::Show($msg, 'Upload to Intune', 'YesNo', 'Question') -eq 'Yes') {
        $form.TopMost = $false   # let the sign-in window come to the front
        Invoke-UiAction 'Uploading to Intune (sign-in window may be behind this one)...' {
            Invoke-OnlineUpload -Tag $txtTag.Text.Trim() -AssignProfile:$chkAssign.Checked
        }
        $form.TopMost = $true
    }
})
$btnEdge.Add_Click({
    Invoke-UiAction 'Opening Edge...' { $form.TopMost = $false; Open-Edge }
})
$btnView.Add_Click({
    Invoke-UiAction 'Opening CSV...' {
        $p = $txtOut.Text.Trim()
        if (-not (Test-Path $p)) { throw "CSV not found: $p" }
        Start-Process notepad.exe -ArgumentList "`"$p`""
    }
})
$btnLog.Add_Click({ Start-Process notepad.exe -ArgumentList "`"$script:LogFile`"" })
$btnReboot.Add_Click({
    if ([System.Windows.Forms.MessageBox]::Show('Restart the device now?', 'Restart', 'YesNo', 'Warning') -eq 'Yes') {
        Restart-Computer -Force
    }
})
$btnClose.Add_Click({ $form.Close() })

$form.Add_Shown({
    $form.Activate()
    Write-Log "Device: $($device.Manufacturer) $($device.Model)  Serial: $($device.Serial)"
    Write-Log "Log file: $script:LogFile"
})

[void]$form.ShowDialog()