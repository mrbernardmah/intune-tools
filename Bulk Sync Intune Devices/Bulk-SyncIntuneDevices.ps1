<#
.SYNOPSIS
    Intune Device Sync Tool - GUI for sending Intune "Sync" requests to managed devices.

.DESCRIPTION
    Three ways to connect to Microsoft Graph:
      1. Bearer token      - paste an access token for https://graph.microsoft.com
      2. App registration  - Tenant ID + Client ID + Client secret (client-credentials flow)
      3. Interactive       - sign in with your admin account (Microsoft.Graph.Authentication,
                             installed for the current user on first use if missing)

    Then: load devices (with filters), tick the ones you want, and send Sync.
    Handles paging, throttling (429/503/504 with Retry-After), Stop, and CSV export.

    Permissions needed (delegated or application):
      DeviceManagementManagedDevices.PrivilegedOperations.All   (sync)
      DeviceManagementManagedDevices.Read.All                   (list devices)

.NOTES
    Run on Windows:  powershell.exe -ExecutionPolicy Bypass -File .\Intune-SyncTool.ps1
    Works in Windows PowerShell 5.1 and PowerShell 7.
#>

#region Startup ---------------------------------------------------------------

# WinForms needs an STA thread; relaunch if needed.
if ([Threading.Thread]::CurrentThread.GetApartmentState() -ne 'STA') {
    $exe = (Get-Process -Id $PID).Path
    Start-Process -FilePath $exe -ArgumentList @('-NoProfile', '-STA', '-ExecutionPolicy', 'Bypass', '-File', "`"$PSCommandPath`"")
    return
}

Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing
[Windows.Forms.Application]::EnableVisualStyles()
[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12

$script:GraphRoot   = 'https://graph.microsoft.com/v1.0'
$script:AuthMode    = $null      # 'Token' | 'MgGraph'
$script:Token       = $null
$script:TokenExpiry = $null
$script:Cancel      = $false
$script:MaxRetries  = 5
$script:Scopes      = @('DeviceManagementManagedDevices.PrivilegedOperations.All',
                        'DeviceManagementManagedDevices.Read.All')

#endregion

#region Helpers ---------------------------------------------------------------

function Write-Log {
    param([string]$Text, [string]$Color = 'Black')
    $log.SelectionStart  = $log.TextLength
    $log.SelectionLength = 0
    $log.SelectionColor  = [Drawing.Color]::FromName($Color)
    $log.AppendText("[$(Get-Date -Format 'HH:mm:ss')] $Text`r`n")
    $log.ScrollToCaret()
    [Windows.Forms.Application]::DoEvents()
}

function Wait-UI {
    # Sleep without freezing the window.
    param([int]$Milliseconds)
    $sw = [Diagnostics.Stopwatch]::StartNew()
    while ($sw.ElapsedMilliseconds -lt $Milliseconds -and -not $script:Cancel) {
        [Windows.Forms.Application]::DoEvents()
        Start-Sleep -Milliseconds 50
    }
}

function ConvertFrom-Jwt {
    param([string]$Token)
    try {
        $parts = $Token.Split('.')
        if ($parts.Count -lt 2) { return $null }
        $p = $parts[1].Replace('-', '+').Replace('_', '/')
        switch ($p.Length % 4) { 2 { $p += '==' } 3 { $p += '=' } }
        return ([Text.Encoding]::UTF8.GetString([Convert]::FromBase64String($p)) | ConvertFrom-Json)
    } catch { return $null }
}

function Get-AppToken {
    param([string]$TenantId, [string]$ClientId, [string]$ClientSecret)
    $body = @{
        client_id     = $ClientId
        client_secret = $ClientSecret
        scope         = 'https://graph.microsoft.com/.default'
        grant_type    = 'client_credentials'
    }
    (Invoke-RestMethod -Method Post -Body $body -ContentType 'application/x-www-form-urlencoded' `
        -Uri "https://login.microsoftonline.com/$TenantId/oauth2/v2.0/token").access_token
}

function Get-HttpStatus {
    param($ErrorRecord)
    $status = 0
    try { $status = [int]$ErrorRecord.Exception.Response.StatusCode } catch { }
    if ($status -eq 0) {
        $msg = "$($ErrorRecord.Exception.Message) $($ErrorRecord.ErrorDetails.Message)"
        if     ($msg -match 'TooManyRequests|\b429\b')    { $status = 429 }
        elseif ($msg -match 'ServiceUnavailable|\b503\b') { $status = 503 }
        elseif ($msg -match 'Unauthorized|\b401\b')       { $status = 401 }
        elseif ($msg -match 'Forbidden|\b403\b')          { $status = 403 }
    }
    return $status
}

function Get-RetryAfter {
    param($ErrorRecord, [int]$Attempt)
    $seconds = 0
    try {
        $h = $ErrorRecord.Exception.Response.Headers
        if ($h -is [System.Net.WebHeaderCollection]) { $seconds = [int]$h['Retry-After'] }
        elseif ($h.RetryAfter.Delta)                 { $seconds = [int]$h.RetryAfter.Delta.TotalSeconds }
    } catch { }
    if ($seconds -le 0) { $seconds = [math]::Min(60, [math]::Pow(2, $Attempt)) }
    return $seconds
}

function Invoke-Graph {
    param([ValidateSet('GET', 'POST')][string]$Method, [string]$Uri)

    if (-not $script:AuthMode) { throw 'Not connected.' }
    if ($script:TokenExpiry -and $script:TokenExpiry -lt (Get-Date)) {
        throw '401 Unauthorized: token has expired. Connect again.'
    }

    for ($attempt = 1; ; $attempt++) {
        try {
            if ($script:AuthMode -eq 'MgGraph') {
                return Invoke-MgGraphRequest -Method $Method -Uri $Uri -OutputType PSObject
            } else {
                $headers = @{ Authorization = "Bearer $script:Token"; 'Content-Type' = 'application/json' }
                return Invoke-RestMethod -Method $Method -Uri $Uri -Headers $headers
            }
        } catch {
            $status = Get-HttpStatus $_
            if (($status -in @(429, 503, 504)) -and ($attempt -le $script:MaxRetries) -and -not $script:Cancel) {
                $wait = Get-RetryAfter $_ $attempt
                Write-Log "HTTP $status (throttled) - waiting $wait s, retry $attempt/$($script:MaxRetries)" 'DarkOrange'
                Wait-UI ($wait * 1000)
                continue
            }
            $detail = if ($_.ErrorDetails.Message) { $_.ErrorDetails.Message } else { $_.Exception.Message }
            if ($status -eq 401) { throw "401 Unauthorized: token invalid or expired. $detail" }
            if ($status -eq 403) { throw "403 Forbidden: missing Intune permission. $detail" }
            throw $detail
        }
    }
}

function Set-Busy {
    param([bool]$Busy)
    $btnConnect.Enabled    = -not $Busy
    $btnDisconnect.Enabled = (-not $Busy) -and [bool]$script:AuthMode
    $btnLoad.Enabled       = (-not $Busy) -and [bool]$script:AuthMode
    $btnSync.Enabled       = (-not $Busy) -and [bool]$script:AuthMode -and $grid.Rows.Count -gt 0
    $btnExport.Enabled     = (-not $Busy) -and $grid.Rows.Count -gt 0
    $btnAll.Enabled        = -not $Busy
    $btnNone.Enabled       = -not $Busy
    $btnStop.Enabled       = $Busy
    $grpAuth.Enabled       = -not $Busy
    $form.Cursor           = if ($Busy) { [Windows.Forms.Cursors]::WaitCursor } else { [Windows.Forms.Cursors]::Default }
}

function Update-Selected {
    $n = 0
    foreach ($r in $grid.Rows) { if ($r.Cells['Select'].Value -eq $true) { $n++ } }
    $lblCount.Text = "$n of $($grid.Rows.Count) selected"
}

function Show-TokenInfo {
    param([string]$Token)
    $claims = ConvertFrom-Jwt $Token
    if (-not $claims) {
        Write-Log 'Could not decode the token (not a JWT?). Continuing anyway.' 'DarkOrange'
        $script:TokenExpiry = $null
        return 'Connected (token not decodable)'
    }
    $script:TokenExpiry = [DateTimeOffset]::FromUnixTimeSeconds([int64]$claims.exp).LocalDateTime
    if ($script:TokenExpiry -lt (Get-Date)) { throw 'This token has already expired.' }

    $who = if ($claims.upn) { $claims.upn } elseif ($claims.app_displayname) { "app: $($claims.app_displayname)" } else { $claims.appid }
    $perms = @()
    if ($claims.scp)   { $perms += $claims.scp -split ' ' }
    if ($claims.roles) { $perms += $claims.roles }

    Write-Log "Token for $who (tenant $($claims.tid)), expires $($script:TokenExpiry)" 'DarkGreen'
    if ($perms -notcontains 'DeviceManagementManagedDevices.PrivilegedOperations.All') {
        Write-Log 'WARNING: token does not include DeviceManagementManagedDevices.PrivilegedOperations.All - sync will likely fail with 403.' 'Red'
    }
    if ($script:TokenExpiry -lt (Get-Date).AddMinutes(10)) {
        Write-Log 'WARNING: token expires within 10 minutes.' 'DarkOrange'
    }
    return "Connected: $who  |  expires $($script:TokenExpiry.ToString('HH:mm'))"
}

#endregion

#region Form ------------------------------------------------------------------

$form = New-Object Windows.Forms.Form
$form.Text          = 'Intune Device Sync Tool'
$form.Size          = New-Object Drawing.Size(1000, 760)
$form.MinimumSize   = New-Object Drawing.Size(900, 650)
$form.StartPosition = 'CenterScreen'
$form.Font          = New-Object Drawing.Font('Segoe UI', 9)

function New-Label($text, $x, $y, $w = 120) {
    $l = New-Object Windows.Forms.Label
    $l.Text = $text; $l.Location = New-Object Drawing.Point($x, $y); $l.Size = New-Object Drawing.Size($w, 20)
    $l.TextAlign = 'MiddleLeft'
    return $l
}
function New-TextBox($x, $y, $w, [switch]$Secret) {
    $t = New-Object Windows.Forms.TextBox
    $t.Location = New-Object Drawing.Point($x, $y); $t.Size = New-Object Drawing.Size($w, 22)
    if ($Secret) { $t.UseSystemPasswordChar = $true }
    return $t
}
function New-Button($text, $x, $y, $w = 100) {
    $b = New-Object Windows.Forms.Button
    $b.Text = $text; $b.Location = New-Object Drawing.Point($x, $y); $b.Size = New-Object Drawing.Size($w, 28)
    return $b
}

# --- Sign-in group ---
$grpAuth = New-Object Windows.Forms.GroupBox
$grpAuth.Text = 'Sign in'
$grpAuth.Location = New-Object Drawing.Point(10, 8)
$grpAuth.Size = New-Object Drawing.Size(965, 120)
$grpAuth.Anchor = 'Top,Left,Right'

$rbInteractive = New-Object Windows.Forms.RadioButton
$rbInteractive.Text = 'Sign in to Intune (interactive)'; $rbInteractive.Location = New-Object Drawing.Point(15, 22); $rbInteractive.Size = New-Object Drawing.Size(220, 22)
$rbInteractive.Checked = $true
$rbToken = New-Object Windows.Forms.RadioButton
$rbToken.Text = 'Bearer token'; $rbToken.Location = New-Object Drawing.Point(245, 22); $rbToken.Size = New-Object Drawing.Size(120, 22)
$rbApp = New-Object Windows.Forms.RadioButton
$rbApp.Text = 'App registration (client secret)'; $rbApp.Location = New-Object Drawing.Point(375, 22); $rbApp.Size = New-Object Drawing.Size(230, 22)

# Interactive panel
$pnlInteractive = New-Object Windows.Forms.Panel
$pnlInteractive.Location = New-Object Drawing.Point(15, 48); $pnlInteractive.Size = New-Object Drawing.Size(935, 30); $pnlInteractive.Anchor = 'Top,Left,Right'
$txtTenantInteractive = New-TextBox 120 3 280
$pnlInteractive.Controls.AddRange(@(
    (New-Label 'Tenant (optional):' 0 3 120), $txtTenantInteractive,
    (New-Label 'Opens a Microsoft sign-in window. Needs an Intune admin account.' 410 3 450)
))

# Token panel
$pnlToken = New-Object Windows.Forms.Panel
$pnlToken.Location = $pnlInteractive.Location; $pnlToken.Size = $pnlInteractive.Size; $pnlToken.Anchor = 'Top,Left,Right'
$txtToken = New-TextBox 120 3 730 -Secret
$txtToken.Anchor = 'Top,Left,Right'
$chkShowToken = New-Object Windows.Forms.CheckBox
$chkShowToken.Text = 'Show'; $chkShowToken.Location = New-Object Drawing.Point(860, 3); $chkShowToken.Size = New-Object Drawing.Size(60, 22); $chkShowToken.Anchor = 'Top,Right'
$pnlToken.Controls.AddRange(@((New-Label 'Access token:' 0 3 120), $txtToken, $chkShowToken))
$pnlToken.Visible = $false

# App panel
$pnlApp = New-Object Windows.Forms.Panel
$pnlApp.Location = $pnlInteractive.Location; $pnlApp.Size = $pnlInteractive.Size; $pnlApp.Anchor = 'Top,Left,Right'
$txtTenant = New-TextBox 65 3 230
$txtClient = New-TextBox 370 3 230
$txtSecret = New-TextBox 690 3 230 -Secret
$pnlApp.Controls.AddRange(@(
    (New-Label 'Tenant ID:' 0 3 65), $txtTenant,
    (New-Label 'Client ID:' 305 3 65), $txtClient,
    (New-Label 'Secret:' 640 3 50), $txtSecret
))
$pnlApp.Visible = $false

$btnConnect    = New-Button 'Connect' 15 82
$btnDisconnect = New-Button 'Disconnect' 120 82
$btnDisconnect.Enabled = $false
$lblStatus = New-Label 'Not connected' 230 86 720
$lblStatus.ForeColor = [Drawing.Color]::DimGray
$lblStatus.Anchor = 'Top,Left,Right'

$grpAuth.Controls.AddRange(@($rbInteractive, $rbToken, $rbApp, $pnlInteractive, $pnlToken, $pnlApp,
                             $btnConnect, $btnDisconnect, $lblStatus))

# --- Filter group ---
$grpFilter = New-Object Windows.Forms.GroupBox
$grpFilter.Text = 'Devices'
$grpFilter.Location = New-Object Drawing.Point(10, 133)
$grpFilter.Size = New-Object Drawing.Size(965, 58)
$grpFilter.Anchor = 'Top,Left,Right'

$txtName = New-TextBox 95 24 170
$txtName.Text = '*'
$cmbOS = New-Object Windows.Forms.ComboBox
$cmbOS.DropDownStyle = 'DropDownList'
$cmbOS.Location = New-Object Drawing.Point(310, 24); $cmbOS.Size = New-Object Drawing.Size(110, 22)
[void]$cmbOS.Items.AddRange(@('All', 'Windows', 'macOS', 'iOS', 'Android', 'Linux'))
$cmbOS.SelectedIndex = 0
$numHours = New-Object Windows.Forms.NumericUpDown
$numHours.Location = New-Object Drawing.Point(615, 24); $numHours.Size = New-Object Drawing.Size(70, 22)
$numHours.Maximum = 100000; $numHours.Value = 0
$btnLoad = New-Button 'Load devices' 700 20 120
$btnLoad.Enabled = $false

$grpFilter.Controls.AddRange(@(
    (New-Label 'Name (wildcard):' 8 24 90), $txtName,
    (New-Label 'OS:' 280 24 30), $cmbOS,
    (New-Label 'Last check-in older than (hours, 0 = any):' 430 24 185), $numHours,
    $btnLoad
))

# --- Selection buttons ---
$btnAll  = New-Button 'Select all' 10 198 90
$btnNone = New-Button 'Select none' 105 198 90
$lblCount = New-Label '0 of 0 selected' 205 202 300

# --- Grid ---
$grid = New-Object Windows.Forms.DataGridView
$grid.Location = New-Object Drawing.Point(10, 232)
$grid.Size = New-Object Drawing.Size(965, 285)
$grid.Anchor = 'Top,Bottom,Left,Right'
$grid.AllowUserToAddRows = $false
$grid.AllowUserToDeleteRows = $false
$grid.RowHeadersVisible = $false
$grid.SelectionMode = 'FullRowSelect'
$grid.AutoSizeColumnsMode = 'Fill'
$grid.BackgroundColor = [Drawing.Color]::White

$colSel = New-Object Windows.Forms.DataGridViewCheckBoxColumn
$colSel.Name = 'Select'; $colSel.HeaderText = ''; $colSel.FillWeight = 12
[void]$grid.Columns.Add($colSel)
foreach ($c in @(
    @('DeviceName', 'Device name', 120), @('OS', 'OS', 50), @('User', 'User', 120),
    @('LastSync', 'Last check-in', 70), @('Status', 'Status', 90), @('Id', 'Id', 10))) {
    $col = New-Object Windows.Forms.DataGridViewTextBoxColumn
    $col.Name = $c[0]; $col.HeaderText = $c[1]; $col.FillWeight = $c[2]; $col.ReadOnly = $true
    [void]$grid.Columns.Add($col)
}
$grid.Columns['Id'].Visible = $false

# --- Action row ---
$btnSync   = New-Button 'Sync selected' 10 525 120
$btnSync.Enabled = $false
$btnSync.Font = New-Object Drawing.Font('Segoe UI', 9, [Drawing.FontStyle]::Bold)
$btnStop   = New-Button 'Stop' 135 525 80
$btnStop.Enabled = $false
$btnExport = New-Button 'Export CSV' 220 525 100
$btnExport.Enabled = $false
foreach ($b in @($btnSync, $btnStop, $btnExport)) { $b.Anchor = 'Bottom,Left' }

$progress = New-Object Windows.Forms.ProgressBar
$progress.Location = New-Object Drawing.Point(330, 529); $progress.Size = New-Object Drawing.Size(645, 20)
$progress.Anchor = 'Bottom,Left,Right'

# --- Log ---
$log = New-Object Windows.Forms.RichTextBox
$log.Location = New-Object Drawing.Point(10, 560)
$log.Size = New-Object Drawing.Size(965, 150)
$log.Anchor = 'Bottom,Left,Right'
$log.ReadOnly = $true
$log.BackColor = [Drawing.Color]::White
$log.Font = New-Object Drawing.Font('Consolas', 9)

$form.Controls.AddRange(@($grpAuth, $grpFilter, $btnAll, $btnNone, $lblCount, $grid,
                          $btnSync, $btnStop, $btnExport, $progress, $log))

#endregion

#region Events ----------------------------------------------------------------

$switchPanel = {
    $pnlInteractive.Visible = $rbInteractive.Checked
    $pnlToken.Visible       = $rbToken.Checked
    $pnlApp.Visible         = $rbApp.Checked
}
$rbInteractive.Add_CheckedChanged($switchPanel)
$rbToken.Add_CheckedChanged($switchPanel)
$rbApp.Add_CheckedChanged($switchPanel)
$chkShowToken.Add_CheckedChanged({ $txtToken.UseSystemPasswordChar = -not $chkShowToken.Checked })

# Commit checkbox clicks immediately so the count updates.
$grid.Add_CurrentCellDirtyStateChanged({ if ($grid.IsCurrentCellDirty) { $grid.CommitEdit('CurrentCellChange') } })
$grid.Add_CellValueChanged({ Update-Selected })

$btnAll.Add_Click({  foreach ($r in $grid.Rows) { $r.Cells['Select'].Value = $true };  Update-Selected })
$btnNone.Add_Click({ foreach ($r in $grid.Rows) { $r.Cells['Select'].Value = $false }; Update-Selected })
$btnStop.Add_Click({ $script:Cancel = $true; Write-Log 'Stopping after the current request...' 'DarkOrange' })

# --- Connect ---
$btnConnect.Add_Click({
    Set-Busy $true
    try {
        if ($rbToken.Checked) {
            $t = ($txtToken.Text.Trim() -replace '^(?i)bearer\s+', '')
            if (-not $t) { throw 'Paste an access token first.' }
            $status = Show-TokenInfo $t
            $script:Token = $t
            $script:AuthMode = 'Token'
        }
        elseif ($rbApp.Checked) {
            if (-not ($txtTenant.Text -and $txtClient.Text -and $txtSecret.Text)) { throw 'Enter Tenant ID, Client ID and Secret.' }
            Write-Log 'Requesting app-only token...'
            $t = Get-AppToken -TenantId $txtTenant.Text.Trim() -ClientId $txtClient.Text.Trim() -ClientSecret $txtSecret.Text
            $status = Show-TokenInfo $t
            $script:Token = $t
            $script:AuthMode = 'Token'
        }
        else {
            if (-not (Get-Module -ListAvailable -Name Microsoft.Graph.Authentication)) {
                $ans = [Windows.Forms.MessageBox]::Show(
                    "Interactive sign-in needs the Microsoft.Graph.Authentication module.`n`nInstall it now for your user account?",
                    'Module required', 'YesNo', 'Question')
                if ($ans -ne 'Yes') { throw 'Interactive sign-in cancelled (module not installed).' }
                Write-Log 'Installing Microsoft.Graph.Authentication (CurrentUser)...'
                if (-not (Get-PackageProvider -ListAvailable -Name NuGet -ErrorAction SilentlyContinue)) {
                    Install-PackageProvider -Name NuGet -MinimumVersion 2.8.5.201 -Scope CurrentUser -Force | Out-Null
                }
                Install-Module -Name Microsoft.Graph.Authentication -Scope CurrentUser -Force -AllowClobber -ErrorAction Stop
            }
            Import-Module Microsoft.Graph.Authentication -ErrorAction Stop
            Write-Log 'Opening Microsoft sign-in...'
            $params = @{ Scopes = $script:Scopes; ErrorAction = 'Stop' }
            if ($txtTenantInteractive.Text.Trim()) { $params.TenantId = $txtTenantInteractive.Text.Trim() }
            if ((Get-Command Connect-MgGraph).Parameters.ContainsKey('NoWelcome')) { $params.NoWelcome = $true }
            Connect-MgGraph @params | Out-Null

            $ctx = Get-MgContext
            if (-not $ctx) { throw 'Sign-in did not complete.' }
            $script:AuthMode = 'MgGraph'
            $script:TokenExpiry = $null
            Write-Log "Signed in as $($ctx.Account) (tenant $($ctx.TenantId))" 'DarkGreen'
            if ($ctx.Scopes -notcontains 'DeviceManagementManagedDevices.PrivilegedOperations.All') {
                Write-Log 'WARNING: PrivilegedOperations.All was not granted - sync will likely fail. An admin may need to consent.' 'Red'
            }
            $status = "Connected: $($ctx.Account)"
        }
        $lblStatus.Text = $status
        $lblStatus.ForeColor = [Drawing.Color]::DarkGreen
    } catch {
        $script:AuthMode = $null; $script:Token = $null
        $lblStatus.Text = 'Not connected'
        $lblStatus.ForeColor = [Drawing.Color]::DimGray
        Write-Log "Connect failed: $($_.Exception.Message)" 'Red'
    } finally {
        Set-Busy $false
    }
})

# --- Disconnect ---
$btnDisconnect.Add_Click({
    if ($script:AuthMode -eq 'MgGraph') { try { Disconnect-MgGraph -ErrorAction SilentlyContinue | Out-Null } catch { } }
    $script:AuthMode = $null; $script:Token = $null; $script:TokenExpiry = $null
    $txtToken.Clear(); $txtSecret.Clear()
    $lblStatus.Text = 'Not connected'; $lblStatus.ForeColor = [Drawing.Color]::DimGray
    Write-Log 'Disconnected.'
    Set-Busy $false
})

# --- Load devices ---
$btnLoad.Add_Click({
    $script:Cancel = $false
    Set-Busy $true
    $grid.Rows.Clear()
    try {
        Write-Log 'Loading managed devices...'
        $select = 'id,deviceName,operatingSystem,lastSyncDateTime,userPrincipalName'
        $uri = "$($script:GraphRoot)/deviceManagement/managedDevices?`$select=$select&`$top=999"
        $all = New-Object System.Collections.Generic.List[object]
        while ($uri -and -not $script:Cancel) {
            $page = Invoke-Graph -Method GET -Uri $uri
            foreach ($d in $page.value) { $all.Add($d) }
            $lblCount.Text = "Loading... $($all.Count)"
            [Windows.Forms.Application]::DoEvents()
            $uri = $page.'@odata.nextLink'
        }
        Write-Log "Found $($all.Count) managed devices."

        $nameFilter = if ($txtName.Text.Trim()) { $txtName.Text.Trim() } else { '*' }
        $osFilter   = $cmbOS.SelectedItem
        $hours      = [int]$numHours.Value
        $cutoff     = (Get-Date).ToUniversalTime().AddHours(-$hours)

        $grid.SuspendLayout()
        foreach ($d in $all) {
            if ($d.deviceName -notlike $nameFilter) { continue }
            if ($osFilter -ne 'All' -and $d.operatingSystem -ne $osFilter) { continue }
            $last = $null
            if ($d.lastSyncDateTime) { try { $last = ([datetime]$d.lastSyncDateTime).ToUniversalTime() } catch { } }
            if ($hours -gt 0 -and $last -and $last -ge $cutoff) { continue }
            $lastText = if ($last -and $last.Year -gt 1) { $last.ToLocalTime().ToString('yyyy-MM-dd HH:mm') } else { 'Never' }
            [void]$grid.Rows.Add($true, $d.deviceName, $d.operatingSystem, $d.userPrincipalName, $lastText, '', $d.id)
        }
        $grid.ResumeLayout()
        Write-Log "$($grid.Rows.Count) devices match the filters." 'DarkGreen'
    } catch {
        Write-Log "Load failed: $($_.Exception.Message)" 'Red'
    } finally {
        Update-Selected
        Set-Busy $false
    }
})

# --- Sync ---
$btnSync.Add_Click({
    $grid.EndEdit()
    $rows = @($grid.Rows | Where-Object { $_.Cells['Select'].Value -eq $true })
    if ($rows.Count -eq 0) { Write-Log 'No devices selected.' 'DarkOrange'; return }

    $ans = [Windows.Forms.MessageBox]::Show("Send a Sync request to $($rows.Count) device(s)?", 'Confirm sync', 'YesNo', 'Question')
    if ($ans -ne 'Yes') { return }

    $script:Cancel = $false
    Set-Busy $true
    $progress.Maximum = $rows.Count; $progress.Value = 0
    $sent = 0; $failed = 0
    try {
        foreach ($row in $rows) {
            if ($script:Cancel) { Write-Log 'Stopped by user.' 'DarkOrange'; break }
            $name = $row.Cells['DeviceName'].Value
            $row.Cells['Status'].Value = 'Sending...'
            $grid.FirstDisplayedScrollingRowIndex = [math]::Max(0, $row.Index - 5)
            [Windows.Forms.Application]::DoEvents()
            try {
                Invoke-Graph -Method POST -Uri "$($script:GraphRoot)/deviceManagement/managedDevices/$($row.Cells['Id'].Value)/syncDevice" | Out-Null
                $row.Cells['Status'].Value = 'Sent'
                $row.Cells['Status'].Style.ForeColor = [Drawing.Color]::DarkGreen
                Write-Log "Sync request sent to $name" 'DarkGoldenrod'
                $sent++
            } catch {
                $msg = $_.Exception.Message
                $row.Cells['Status'].Value = 'Failed'
                $row.Cells['Status'].Style.ForeColor = [Drawing.Color]::Red
                $row.Cells['Status'].ToolTipText = $msg
                Write-Log "FAILED $name - $msg" 'Red'
                $failed++
                if ($msg -like '401*') { Write-Log 'Stopping: token is no longer valid. Connect again.' 'Red'; break }
            }
            $progress.Value = [math]::Min($progress.Maximum, $progress.Value + 1)
            Wait-UI 200   # gentle pacing to stay under Graph throttling limits
        }
    } finally {
        Write-Log "Done. Sent: $sent  Failed: $failed  Selected: $($rows.Count)" 'DarkGreen'
        Set-Busy $false
    }
})

# --- Export ---
$btnExport.Add_Click({
    $dlg = New-Object Windows.Forms.SaveFileDialog
    $dlg.Filter = 'CSV files (*.csv)|*.csv'
    $dlg.FileName = "IntuneSync_$(Get-Date -Format 'yyyyMMdd_HHmm').csv"
    if ($dlg.ShowDialog() -ne 'OK') { return }
    $grid.Rows | ForEach-Object {
        [pscustomobject]@{
            Selected   = [bool]$_.Cells['Select'].Value
            DeviceName = $_.Cells['DeviceName'].Value
            OS         = $_.Cells['OS'].Value
            User       = $_.Cells['User'].Value
            LastSync   = $_.Cells['LastSync'].Value
            Status     = $_.Cells['Status'].Value
            Error      = $_.Cells['Status'].ToolTipText
            DeviceId   = $_.Cells['Id'].Value
        }
    } | Export-Csv -Path $dlg.FileName -NoTypeInformation -Encoding UTF8
    Write-Log "Exported to $($dlg.FileName)" 'DarkGreen'
})

$form.Add_FormClosing({
    $script:Cancel = $true
    if ($script:AuthMode -eq 'MgGraph') { try { Disconnect-MgGraph -ErrorAction SilentlyContinue | Out-Null } catch { } }
})

#endregion

Write-Log 'Choose a sign-in method and click Connect.'
[void]$form.ShowDialog()
$form.Dispose()