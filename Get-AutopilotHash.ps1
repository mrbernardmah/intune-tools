<#
.SYNOPSIS
    Collects the Windows Autopilot device hash and opens Microsoft Edge on Google Drive.

.DESCRIPTION
    Automates steps 3-8 of "(117) Windows Autopilot - Device Hash Upload via VM":
      3. Create C:\Temp
      4. Download Get-WindowsAutopilotInfo from the PowerShell Gallery
      5. Set the execution policy to Bypass (this process only)
      6. Change to C:\Temp
      7. Generate the hardware hash CSV
      8. Open Microsoft Edge, then go to Google Drive so the CSV can be uploaded

    Run from OOBE: press Shift+F10, type "powershell", then run:
        irm https://raw.githubusercontent.com/<owner>/<repo>/main/Get-AutopilotHash.ps1 | iex

.PARAMETER OutputFolder
    Folder for the script and CSV. Default: C:\Temp

.PARAMETER OutputFile
    CSV file name. Default: AutopilotHash-<SerialNumber>.csv

.PARAMETER DriveUrl
    URL that Edge opens after the hash is collected. Default: Google Drive "My Drive".
#>
[CmdletBinding()]
param(
    [string]$OutputFolder = 'C:\Temp',
    [string]$OutputFile,
    [string]$DriveUrl = 'https://drive.google.com/drive/my-drive'
)

$ErrorActionPreference = 'Stop'
$ProgressPreference    = 'SilentlyContinue'

function Write-Step([string]$Message) { Write-Host "`n==> $Message" -ForegroundColor Cyan }

try {
    # PowerShell Gallery requires TLS 1.2 (older OOBE builds default to TLS 1.0)
    [Net.ServicePointManager]::SecurityProtocol = [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12

    # Step 5 (done first so everything below can run): bypass for this process only
    Write-Step 'Setting execution policy to Bypass for this session'
    Set-ExecutionPolicy -ExecutionPolicy Bypass -Scope Process -Force

    # Step 3: create the folder
    Write-Step "Creating $OutputFolder"
    if (-not (Test-Path $OutputFolder)) { New-Item -Path $OutputFolder -ItemType Directory -Force | Out-Null }

    # Step 4: download Get-WindowsAutopilotInfo without the "Y" prompts
    Write-Step 'Downloading Get-WindowsAutopilotInfo from the PowerShell Gallery'
    if (-not (Get-PackageProvider -Name NuGet -ListAvailable -ErrorAction SilentlyContinue |
              Where-Object { $_.Version -ge [version]'2.8.5.201' })) {
        Install-PackageProvider -Name NuGet -MinimumVersion 2.8.5.201 -Force -Scope CurrentUser | Out-Null
    }
    if ((Get-PSRepository -Name PSGallery).InstallationPolicy -ne 'Trusted') {
        Set-PSRepository -Name PSGallery -InstallationPolicy Trusted
    }
    Save-Script -Name Get-WindowsAutopilotInfo -Path $OutputFolder -Force

    # Step 6: change to the folder
    Set-Location -Path $OutputFolder

    # Step 7: generate the hash file
    if (-not $OutputFile) {
        $serial = (Get-CimInstance -ClassName Win32_BIOS).SerialNumber -replace '[\\/:*?"<>| ]', '_'
        $OutputFile = "AutopilotHash-$serial.csv"
    }
    $csvPath = Join-Path $OutputFolder $OutputFile

    Write-Step "Generating device hash -> $csvPath"
    & (Join-Path $OutputFolder 'Get-WindowsAutopilotInfo.ps1') -OutputFile $csvPath

    if (-not (Test-Path $csvPath)) { throw "Hash file was not created at $csvPath" }
    Write-Host "Hash saved: $csvPath" -ForegroundColor Green

    # Put the CSV path on the clipboard so it can be pasted into the upload dialog
    try { Set-Clipboard -Value $csvPath } catch { }

    # Step 8: open Edge, then navigate to Google Drive
    Write-Step "Opening Microsoft Edge at $DriveUrl"
    $edge = @(
        "${env:ProgramFiles(x86)}\Microsoft\Edge\Application\msedge.exe",
        "$env:ProgramFiles\Microsoft\Edge\Application\msedge.exe"
    ) | Where-Object { Test-Path $_ } | Select-Object -First 1
    if (-not $edge) { $edge = 'msedge' }   # fall back to App Paths lookup, same as "start msedge"

    Start-Process -FilePath $edge -ArgumentList '--no-first-run', '--no-default-browser-check', $DriveUrl

    Write-Host "`nNext: sign in to Google Drive, click New > File upload, and choose:" -ForegroundColor Yellow
    Write-Host "  $csvPath  (path copied to clipboard)" -ForegroundColor Yellow
}
catch {
    Write-Host "`nFAILED: $($_.Exception.Message)" -ForegroundColor Red
    Write-Host 'Check the VM has internet access and try again.' -ForegroundColor Red
}s