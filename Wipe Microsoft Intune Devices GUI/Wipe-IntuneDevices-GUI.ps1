<#
.TITLE
    Wipe Devices GUI

.SYNOPSIS
    Windows GUI for remote wipe / retire of Intune managed devices, found by Entra ID group or by hostname / serial number.

.DESCRIPTION
    GUI front end built on the logic of Remote-Wipe-Intune-Devices-V3.ps1 (v2.0):
      - Search and pick the Entra ID group (no ambiguity when two groups share a name)
      - Preview every target device in a grid before anything is sent: device members are matched to
        Intune by Entra device ID (most recently synced record wins), user members add all of their
        managed devices; optional nested-group expansion
      - Tick / untick individual devices; devices already in a wipe/retire pending state are unticked
      - Confirmation dialog (type CONFIRM) before any wipe is sent

    Sign-in options (choose in the connection bar):
      - Browser sign-in: opens the Microsoft login page in your browser; the token renews silently during long runs
      - Device code: enter a code at microsoft.com/devicelogin (useful when the browser is on another machine)
      - Paste bearer token: for example the Authorization header copied from the Intune portal (F12 > Network);
        it cannot be renewed, so the run pauses and asks for a new token before it expires
      - MgGraphCommunity module or Graph SDK Connect-MgGraph

    Fixes for the "Unauthorized (401)" failures seen part-way through large runs:
      - The access token's expiry and scopes are read after sign-in and shown in the window
      - Before every wipe call the token is checked; if it has under 4 minutes left the script
        refreshes it (silently with the Graph SDK, or by signing in again) before continuing
      - A 401 on any call triggers one token renewal (or a prompt for a new pasted token) and a retry of that same device
      - If authorisation keeps failing (3 devices in a row), the run stops instead of failing every
        remaining device. Rows not processed stay ticked, so pressing Wipe again resumes
      - 429 / 5xx responses honour Retry-After and are retried with back-off
      - The wipe permission is checked with Graph before the first wipe (a harmless sync request if the token's scope list
        does not name it), so a missing permission stops the run before any device is touched

.TAGS
    Operational,Devices,GUI

.MINROLE
    Intune Administrator

.PERMISSIONS
    DeviceManagementManagedDevices.PrivilegedOperations.All,DeviceManagementManagedDevices.Read.All,GroupMember.Read.All,Device.Read.All

.VERSION
    1.6

.CHANGELOG
    1.6 - Wipe option drop-down in its own box in the main window (with description and macOS PIN); the prompt opens
          with that option selected. Search by hostname / serial number (several at once, * wildcard) besides Entra ID
          group; hostname matches are added to the list, so lists can be built up; Clear list button. Fixed the Exit
          button being pushed off-screen
    1.5 - Portal-style wipe prompt when Wipe is pressed: Reset device and remove all data / Reset device, but keep user
          data / Securely erase device (high security) / Retire, optional macOS unlock PIN, "I understand" tick box and
          (for several devices) typing the device count; warns about Windows-only options and the 500 wipes/day tenant
          limit. Replaces the fixed Selective/Full, keep-enrollment and PIN controls
    1.4 - The wipe permission is no longer judged from the token's scope list (tokens such as those copied from the Intune
          portal may not list it yet still be allowed). If it is not listed, a harmless syncDevice request checks with Graph
          before the first wipe; the run only stops if Graph refuses (403)
    1.3 - Fixed "property 'Visible' cannot be found" / "null-valued expression" when loading a group (the device table was
          unrolled to $null when returned); explicit grid columns; group members with no Intune record are listed in grey
          and cannot be ticked; clear message when a group has no Intune devices
    1.2 - Exit button with safe shutdown (stops running work first, closes once it has unwound); closing the window does the
          same; Ctrl+C in the console no longer stops the script; Stop also cancels a waiting sign-in; every event handler
          catches its own errors, and if PowerShell is stopped anyway the window closes instead of showing
          "Unhandled exception ... The pipeline has been stopped"
    1.1 - Sign-in options: browser sign-in (auth code + PKCE) and device code with silent refresh-token renewal,
          paste bearer token (validated: Graph audience, expiry, wipe scope) with a pause-and-prompt for a new one
          before expiry; tenant box; -TenantId and -ClientId parameters
    1.0 - Initial GUI release: Wipe by group tab, token expiry tracking and proactive refresh, 401 re-auth and retry,
          authorisation circuit breaker, resumable runs, per-device CSV written after every device

.EXAMPLE
    .\Wipe-IntuneDevices-GUI.ps1
    Opens the GUI. Exports go to C:\ProgramData\Devicie\logs unless changed in the window.

.NOTES
    - Run locally on Windows (Windows PowerShell 5.1 or PowerShell 7). Requires an STA thread; the script relaunches itself with -STA if needed
    - Requires Microsoft.Graph.Authentication (all sign-in options hand the token to it). MgGraphCommunity is only needed for that option
    - Browser and device code sign-in use the Microsoft Graph Command Line Tools app by default (-ClientId to change); it needs
      consent for the four permissions above, which an admin can grant on first sign-in
    - Tokens are held in memory only and never written to the log or CSV
    - Export: Wipe-Devices_<timestamp>_<Option>.csv (one row per device, rewritten after every device so it is never lost)
      and a matching .log, same naming as the V3 script
    - CAUTION: Full wipe resets devices to factory settings. Operations cannot be undone
#>

[CmdletBinding()]
param(
    [string]$ExportPath = 'C:\ProgramData\Devicie\logs',

    # Tenant for browser / device code sign-in: 'organizations', a tenant ID, or a domain such as contoso.onmicrosoft.com
    [string]$TenantId = 'organizations',

    # Public client used for browser / device code sign-in (default: Microsoft Graph Command Line Tools, the same app Connect-MgGraph uses)
    [string]$ClientId = '14d82eec-204b-4c2f-b7e8-296a70dab67e'
)

# ============================================================================
# STA CHECK (WinForms dialogs need a single-threaded apartment)
# ============================================================================
if ([System.Threading.Thread]::CurrentThread.GetApartmentState() -ne 'STA') {
    $hostExe = (Get-Process -Id $PID).Path
    Start-Process -FilePath $hostExe -ArgumentList @('-STA', '-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', "`"$PSCommandPath`"", '-ExportPath', "`"$ExportPath`"", '-TenantId', $TenantId, '-ClientId', $ClientId)
    return
}

Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing
[System.Windows.Forms.Application]::EnableVisualStyles()

# If PowerShell itself is stopped while the window is open (Ctrl+C in the console, Stop in VS Code / ISE), event
# handlers can no longer run. Without this, WinForms shows "Unhandled exception ... The pipeline has been stopped"
# on every click and timer tick; with it, the window closes instead. All handlers catch their own errors.
try { [System.Windows.Forms.Application]::SetUnhandledExceptionMode([System.Windows.Forms.UnhandledExceptionMode]::ThrowException) } catch { }

# Treat Ctrl+C in the console as a key press rather than stopping the script (a common way to hit the error above)
$script:RestoreCtrlC = $null
try { $script:RestoreCtrlC = [Console]::TreatControlCAsInput; [Console]::TreatControlCAsInput = $true } catch { }

# ============================================================================
# CONSTANTS AND STATE
# ============================================================================
$GraphBase = 'https://graph.microsoft.com/beta'
$DeviceSelect = 'id,deviceName,serialNumber,azureADDeviceId,userPrincipalName,operatingSystem,osVersion,model,lastSyncDateTime,managementState'
$RequiredScopes = @(
    'DeviceManagementManagedDevices.PrivilegedOperations.All',
    'DeviceManagementManagedDevices.Read.All',
    'GroupMember.Read.All',
    'Device.Read.All'
)
$PrivilegedScope = 'DeviceManagementManagedDevices.PrivilegedOperations.All'
$PendingStates = @('wipePending', 'retirePending', 'wipeIssued', 'retireIssued', 'deletePending')

# Wipe options, same wording as the Intune portal. Key -> Graph call (see Invoke-SingleWipe):
#   Wipe             -> wipe, nothing kept
#   WipeKeepUserData -> wipe with keepUserData + keepEnrollmentData
#   ProtectedWipe    -> wipe with useProtectedWipe
#   Retire           -> retire (selective wipe)
$WipeOptions = @(
    @{ Key = 'Wipe'; Label = 'Reset device and remove all data'
        Desc = 'Restores factory settings and deletes all data and management settings. If the process is interrupted, the device might not recover.' },
    @{ Key = 'WipeKeepUserData'; Label = 'Reset device, but keep user data'
        Desc = 'Resets the device while keeping user files and accounts. Management settings are removed, but the device stays enrolled. (Windows)' },
    @{ Key = 'ProtectedWipe'; Label = 'Securely erase device (high security)'
        Desc = 'Removes all data and settings, prevents recovery, and completes even if the device loses power. Can leave some devices (for example BitLocker-encrypted ones) unable to start. (Windows)' },
    @{ Key = 'Retire'; Label = 'Retire: remove company data only'
        Desc = 'Removes company apps, data, email profiles and management, and unenrolls the device. Personal data and the OS are left in place.' }
)
$TokenRefreshMinutes = 4       # refresh the token when it has less than this left (the Graph SDK refreshes silently under 5)
$AuthFailureStopCount = 3      # stop the run after this many devices in a row fail authorisation
$AnyFailurePauseCount = 5      # ask before continuing after this many failures in a row

$script:State = @{
    Connected      = $false
    Account        = ''
    TenantId       = ''
    Scopes         = @()
    TokenExpiryUtc = $null
    ExpiryIsGuess  = $false
    StopRequested  = $false
    Busy           = $false
    Groups         = @()
    SelectedGroup  = $null
    TargetDescription = ''
    AuthMode       = ''
    AccessToken    = $null
    RefreshToken   = $null
    LogFile        = $null
    CsvFile        = $null
    CloseRequested = $false
    TokenApp       = ''
    WipeVerified   = $null      # $true once Graph has accepted a privileged action with the current sign-in
}

# ============================================================================
# UI HELPERS
# ============================================================================
function Invoke-UiPump { [System.Windows.Forms.Application]::DoEvents() }

function Write-UiLog {
    param([string]$Message, [ValidateSet('Info', 'OK', 'Warn', 'Error')][string]$Level = 'Info')

    $line = '{0} [{1}] {2}' -f (Get-Date -Format 'HH:mm:ss'), $Level.ToUpper(), $Message
    $color = switch ($Level) {
        'OK'    { [System.Drawing.Color]::FromArgb(0, 128, 0) }
        'Warn'  { [System.Drawing.Color]::FromArgb(176, 112, 0) }
        'Error' { [System.Drawing.Color]::FromArgb(192, 0, 0) }
        default { [System.Drawing.Color]::FromArgb(40, 40, 40) }
    }
    if ($script:txtLog) {
        $script:txtLog.SelectionStart = $script:txtLog.TextLength
        $script:txtLog.SelectionLength = 0
        $script:txtLog.SelectionColor = $color
        $script:txtLog.AppendText($line + [Environment]::NewLine)
        $script:txtLog.ScrollToCaret()
    }
    if ($script:State.LogFile) {
        try { Add-Content -Path $script:State.LogFile -Value $line -Encoding UTF8 -ErrorAction Stop } catch { }
    }
    Invoke-UiPump
}

function Wait-WithEvents {
    param([double]$Seconds)
    $until = (Get-Date).AddSeconds($Seconds)
    while ((Get-Date) -lt $until -and -not $script:State.StopRequested) {
        Start-Sleep -Milliseconds 100
        Invoke-UiPump
    }
}

function Show-Message {
    param([string]$Text, [string]$Title = 'Wipe Devices', [string]$Icon = 'Information', [string]$Buttons = 'OK')
    return [System.Windows.Forms.MessageBox]::Show($Text, $Title,
        [System.Windows.Forms.MessageBoxButtons]::$Buttons, [System.Windows.Forms.MessageBoxIcon]::$Icon)
}

function Set-Busy {
    param([bool]$Busy)
    $script:State.Busy = $Busy
    $script:form.UseWaitCursor = $Busy
    foreach ($c in @($btnConnect, $cmbAuth, $txtTenant, $cmbSearchBy, $btnSearch, $txtGroup, $cmbGroups, $chkNested, $btnLoad,
            $btnAll, $btnNone, $btnClear, $cmbWipeOption, $txtPinMain, $numDelay, $txtExport, $btnBrowse)) {
        $c.Enabled = -not $Busy
    }
    $grid.ReadOnly = $Busy
    if (-not $Busy -and $grid.DataSource) {
        foreach ($col in $grid.Columns) { $col.ReadOnly = ($col.Name -ne 'Wipe') }
    }
    $btnStop.Enabled = $Busy
    Update-WipeButton
}

function Request-AppExit {
    <# Exit safely: if work is running, stop it after the current step and close once it has unwound.
       Closing while a handler is still running would end the script under it. #>
    if ($script:State.CloseRequested) { return }
    if ($script:State.Busy) {
        $answer = Show-Message -Text "Work is in progress. Stop after the current device / step and exit?`r`n`r`nDevices not yet processed stay ticked in the CSV as 'Not processed'." -Icon Warning -Buttons YesNo
        if ($answer -ne 'Yes') { return }
        $script:State.StopRequested = $true
        $script:State.CloseRequested = $true
        $btnExit.Enabled = $false
        $btnExit.Text = 'Exiting...'
        Write-UiLog 'Exit requested. Stopping after the current step, then closing...' -Level Warn
        $closeTimer.Start()   # closes the window once Busy clears
        return
    }
    $script:State.CloseRequested = $true
    $form.Close()
}

function Update-WipeButton {
    $checked = 0
    if ($script:DeviceTable) {
        $checked = @($script:DeviceTable.Rows | Where-Object { $_['Wipe'] -eq $true }).Count
    }
    $btnWipe.Enabled = (-not $script:State.Busy) -and $script:State.Connected -and $checked -gt 0
    $verb = if ($cmbWipeOption.SelectedIndex -eq 3) { 'Retire' } else { 'Wipe' }
    $btnWipe.Text = "$verb $checked device(s)..."
    $lblCount.Text = if ($script:DeviceTable) { "$($script:DeviceTable.Rows.Count) device(s) found, $checked ticked" } else { '' }
}

# ============================================================================
# MODULES
# ============================================================================
function Initialize-RequiredModule {
    param([string]$ModuleName)

    if (-not (Get-Module -ListAvailable -Name $ModuleName)) {
        $answer = Show-Message -Text "Module '$ModuleName' is not installed. Install it now from PSGallery?" -Icon Question -Buttons YesNo
        if ($answer -ne 'Yes') { throw "Module '$ModuleName' is required but installation was declined." }

        $isAdmin = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
        $scope = if ($isAdmin) { 'AllUsers' } else { 'CurrentUser' }
        Write-UiLog "Installing $ModuleName ($scope)..."
        Install-Module -Name $ModuleName -Scope $scope -Force -AllowClobber -Repository PSGallery -ErrorAction Stop
        Write-UiLog "Installed $ModuleName" -Level OK
    }
    if (-not (Get-Module -Name $ModuleName)) {
        Import-Module -Name $ModuleName -ErrorAction Stop
    }
}

# ============================================================================
# GRAPH: AUTHENTICATION AND TOKEN TRACKING
# ============================================================================
# Sign-in options (connection bar):
#   Browser     - opens the Microsoft sign-in page in the default browser (auth code + PKCE, localhost redirect);
#                 keeps a refresh token in memory so the access token renews silently during long runs
#   DeviceCode  - shows a code and opens microsoft.com/devicelogin; also renews silently
#   Token       - paste a bearer token (for example copied from the Intune portal); cannot be renewed, so the
#                 GUI pauses and asks for a new one before it expires
#   Community   - MgGraphCommunity module (as in the V3 script)
#   GraphSdk    - Connect-MgGraph (renews silently)
# Tokens are kept in memory only and are never written to the log or CSV.

$GraphAudiences = @('https://graph.microsoft.com', 'https://graph.microsoft.com/', '00000003-0000-0000-c000-000000000000')
$OAuthScope = (@($RequiredScopes | ForEach-Object { "https://graph.microsoft.com/$_" }) + @('offline_access', 'openid', 'profile')) -join ' '
$PastedTokenRefreshMinutes = 5   # ask for a new pasted token when the current one has less than this left
$PastedTokenMinMinutes = 6       # refuse pasted tokens with less than this left

function Get-AuthMode {
    switch ($cmbAuth.SelectedIndex) {
        0 { 'Browser' }
        1 { 'DeviceCode' }
        2 { 'Token' }
        3 { 'Community' }
        default { 'GraphSdk' }
    }
}

function Get-AadTenant {
    $t = $txtTenant.Text.Trim()
    if (-not $t) { $t = 'organizations' }
    return $t
}

function ConvertTo-Base64Url {
    param([byte[]]$Bytes)
    return [Convert]::ToBase64String($Bytes).TrimEnd('=').Replace('+', '-').Replace('/', '_')
}

function ConvertFrom-JwtPayload {
    param([string]$Token)
    $parts = $Token.Split('.')
    if ($parts.Count -lt 2) { return $null }
    $payload = $parts[1].Replace('-', '+').Replace('_', '/')
    switch ($payload.Length % 4) { 2 { $payload += '==' } 3 { $payload += '=' } }
    return ([System.Text.Encoding]::UTF8.GetString([Convert]::FromBase64String($payload)) | ConvertFrom-Json)
}

function ConvertTo-CleanToken {
    param([string]$Text)
    $t = $Text.Trim().Trim('"', "'")
    $t = $t -replace '^(?i)authorization:\s*', ''
    $t = $t -replace '^(?i)bearer\s+', ''
    return ($t -replace '\s', '')
}

function Get-TokenProblem {
    <# Returns $null when the token is usable for Graph, otherwise a reason. #>
    param([string]$Token, [int]$MinMinutes = 1)
    $claims = $null
    try { $claims = ConvertFrom-JwtPayload -Token $Token } catch { }
    if (-not $claims -or -not $claims.exp) { return 'This does not look like an access token. It should start with eyJ and contain two dots.' }
    if ([string]$claims.aud -notin $GraphAudiences) {
        return "This token is for '$($claims.aud)', not Microsoft Graph. Copy the Authorization header from a request to graph.microsoft.com."
    }
    $left = ([DateTimeOffset]::FromUnixTimeSeconds([int64]$claims.exp).UtcDateTime - (Get-Date).ToUniversalTime()).TotalMinutes
    if ($left -le 0) { return 'This token has already expired. Copy a fresh one.' }
    if ($left -lt $MinMinutes) { return ("This token expires in {0:N0} min. Refresh the portal page and copy a fresh one." -f $left) }
    return $null
}

function Set-TokenState {
    param($Claims)
    $script:State.TokenExpiryUtc = [DateTimeOffset]::FromUnixTimeSeconds([int64]$Claims.exp).UtcDateTime
    $script:State.ExpiryIsGuess = $false
    if ($Claims.scp) { $script:State.Scopes = @(([string]$Claims.scp).Split(' ')) }
    elseif ($Claims.roles) { $script:State.Scopes = @($Claims.roles) }   # app-only token
    $acct = @($Claims.upn, $Claims.unique_name, $Claims.preferred_username, $Claims.app_displayname) | Where-Object { $_ } | Select-Object -First 1
    if ($acct) { $script:State.Account = [string]$acct }
    if ($Claims.tid) { $script:State.TenantId = [string]$Claims.tid }
    $app = @($Claims.app_displayname, $Claims.appid, $Claims.azp) | Where-Object { $_ } | Select-Object -First 1
    $script:State.TokenApp = [string]$app
}

function Set-GraphAccessToken {
    <# Hands an access token to the Graph SDK so Invoke-MgGraphRequest uses it. #>
    param([string]$Token)
    $cmd = Get-Command Connect-MgGraph -ErrorAction Stop
    $value = if ($cmd.Parameters['AccessToken'].ParameterType -eq [securestring]) { ConvertTo-SecureString -String $Token -AsPlainText -Force } else { $Token }
    $params = @{ AccessToken = $value; ErrorAction = 'Stop' }
    if ($cmd.Parameters.ContainsKey('NoWelcome')) { $params['NoWelcome'] = $true }
    Connect-MgGraph @params | Out-Null

    $script:State.AccessToken = $Token
    Set-TokenState -Claims (ConvertFrom-JwtPayload -Token $Token)
    $script:State.Connected = $true
    Update-AuthLabel
}

function Test-GraphAccess {
    try {
        Invoke-MgGraphRequest -Uri "$GraphBase/deviceManagement/managedDevices?`$top=1&`$select=id" -Method GET -ErrorAction Stop | Out-Null
    }
    catch {
        $s = Get-GraphErrorStatus -ErrorRecord $_
        if ($s -eq 401) { throw 'Microsoft Graph rejected the token (401 Unauthorized).' }
        if ($s -eq 403) { throw 'Signed in, but reading Intune devices was denied (403). Check the Intune Administrator role / PIM activation and that the token includes DeviceManagementManagedDevices.Read.All.' }
        throw
    }
}

function Invoke-AadTokenRequest {
    param([hashtable]$Body)
    $Body['client_id'] = $ClientId
    try {
        return Invoke-RestMethod -Method Post -Uri "https://login.microsoftonline.com/$(Get-AadTenant)/oauth2/v2.0/token" -Body $Body -ContentType 'application/x-www-form-urlencoded' -ErrorAction Stop
    }
    catch {
        $code = ''
        $desc = $_.Exception.Message
        try {
            $j = $_.ErrorDetails.Message | ConvertFrom-Json -ErrorAction Stop
            $code = [string]$j.error
            $desc = (([string]$j.error_description) -split "`r?`n")[0]
        }
        catch { }
        $ex = [System.Exception]::new($desc)
        $ex.Data['AadError'] = $code
        throw $ex
    }
}

function Invoke-BrowserSignIn {
    <# Authorization code flow with PKCE. Opens the Microsoft sign-in page in the default browser and
       receives the redirect on a localhost port. Returns the token response (access + refresh token). #>
    $rng = [System.Security.Cryptography.RandomNumberGenerator]::Create()
    $buf = New-Object byte[] 32
    $rng.GetBytes($buf)
    $verifier = ConvertTo-Base64Url -Bytes $buf
    $sha = [System.Security.Cryptography.SHA256]::Create()
    $challenge = ConvertTo-Base64Url -Bytes ($sha.ComputeHash([System.Text.Encoding]::ASCII.GetBytes($verifier)))
    $state = [guid]::NewGuid().ToString('N')

    # Listen on IPv4 and (where possible) IPv6 loopback on the same port, since "localhost" may resolve to either
    $listeners = [System.Collections.Generic.List[System.Net.Sockets.TcpListener]]::new()
    $v4 = [System.Net.Sockets.TcpListener]::new([System.Net.IPAddress]::Loopback, 0)
    $v4.Start()
    $listeners.Add($v4)
    $port = ([System.Net.IPEndPoint]$v4.LocalEndpoint).Port
    try {
        $v6 = [System.Net.Sockets.TcpListener]::new([System.Net.IPAddress]::IPv6Loopback, $port)
        $v6.Start()
        $listeners.Add($v6)
    }
    catch { }

    $redirect = "http://localhost:$port/"
    $query = $null
    try {
        $authUrl = 'https://login.microsoftonline.com/{0}/oauth2/v2.0/authorize?client_id={1}&response_type=code&redirect_uri={2}&response_mode=query&scope={3}&state={4}&code_challenge={5}&code_challenge_method=S256&prompt=select_account' -f `
        (Get-AadTenant), $ClientId, [uri]::EscapeDataString($redirect), [uri]::EscapeDataString($OAuthScope), $state, $challenge
        Write-UiLog 'Opening the Microsoft sign-in page in your browser. Finish signing in there (5 minute limit)...'
        Start-Process $authUrl

        $deadline = (Get-Date).AddMinutes(5)
        $tasks = @($null) * $listeners.Count
        while (-not $query) {
            for ($k = 0; $k -lt $listeners.Count; $k++) {
                if ($null -eq $tasks[$k]) { $tasks[$k] = $listeners[$k].AcceptTcpClientAsync() }
            }
            $done = -1
            for ($k = 0; $k -lt $listeners.Count; $k++) { if ($tasks[$k].IsCompleted) { $done = $k; break } }
            if ($done -lt 0) {
                if ((Get-Date) -gt $deadline) { throw 'Timed out waiting for the browser sign-in (5 minutes).' }
                if ($script:State.StopRequested) { throw 'Sign-in cancelled.' }
                Start-Sleep -Milliseconds 100
                Invoke-UiPump
                continue
            }

            $client = $null
            try {
                $client = $tasks[$done].Result
                $tasks[$done] = $null
                $stream = $client.GetStream()
                $stream.ReadTimeout = 2000   # browsers open speculative connections that never send a request
                $reader = New-Object System.IO.StreamReader($stream)
                $line = $reader.ReadLine()
                if ($line -match '^GET\s+/\?(\S+)\s+HTTP') {
                    $parsed = @{}
                    foreach ($pair in $Matches[1].Split('&')) {
                        $kv = $pair.Split('=', 2)
                        if ($kv.Count -eq 2) { $parsed[[uri]::UnescapeDataString($kv[0])] = [uri]::UnescapeDataString($kv[1].Replace('+', ' ')) }
                    }
                    if ($parsed.ContainsKey('code') -or $parsed.ContainsKey('error')) { $query = $parsed }
                }
                $msg = if ($query -and $query['code']) { 'Signed in. You can close this tab and return to the Intune Device Wipe window.' }
                elseif ($query) { 'Sign-in failed: ' + [System.Net.WebUtility]::HtmlEncode([string]$query['error_description']) }
                else { 'Waiting for sign-in...' }
                $html = "<html><head><meta charset='utf-8'><title>Intune Device Wipe</title></head><body style='font-family:Segoe UI,Arial;padding:40px'><h3>$msg</h3></body></html>"
                $bodyBytes = [System.Text.Encoding]::UTF8.GetBytes($html)
                $head = "HTTP/1.1 200 OK`r`nContent-Type: text/html; charset=utf-8`r`nContent-Length: $($bodyBytes.Length)`r`nConnection: close`r`n`r`n"
                $headBytes = [System.Text.Encoding]::ASCII.GetBytes($head)
                $stream.Write($headBytes, 0, $headBytes.Length)
                $stream.Write($bodyBytes, 0, $bodyBytes.Length)
                $stream.Flush()
            }
            catch { }
            finally { if ($client) { $client.Close() } }
        }
    }
    finally {
        foreach ($l in $listeners) { try { $l.Stop() } catch { } }
    }

    if ($query['error']) { throw "Sign-in failed: $($query['error']): $((([string]$query['error_description']) -split "`r?`n")[0])" }
    if ($query['state'] -ne $state) { throw 'The sign-in response did not match this request (state mismatch). Try again.' }
    return Invoke-AadTokenRequest -Body @{
        grant_type    = 'authorization_code'
        code          = $query['code']
        redirect_uri  = $redirect
        code_verifier = $verifier
        scope         = $OAuthScope
    }
}

function Invoke-DeviceCodeSignIn {
    <# Device code flow: shows the code, copies it to the clipboard and opens microsoft.com/devicelogin. #>
    $dc = Invoke-RestMethod -Method Post -Uri "https://login.microsoftonline.com/$(Get-AadTenant)/oauth2/v2.0/devicecode" `
        -Body @{ client_id = $ClientId; scope = $OAuthScope } -ContentType 'application/x-www-form-urlencoded' -ErrorAction Stop
    try { [System.Windows.Forms.Clipboard]::SetText([string]$dc.user_code) } catch { }

    $dlg = New-Object System.Windows.Forms.Form
    $dlg.Text = 'Sign in with a code'
    $dlg.Size = New-Object System.Drawing.Size(460, 240)
    $dlg.StartPosition = 'CenterParent'
    $dlg.FormBorderStyle = 'FixedDialog'
    $dlg.MaximizeBox = $false
    $dlg.MinimizeBox = $false
    $info = New-Object System.Windows.Forms.Label
    $info.Location = New-Object System.Drawing.Point(15, 12)
    $info.Size = New-Object System.Drawing.Size(420, 50)
    $info.Text = "A browser has opened $($dc.verification_uri). Enter this code (already copied to the clipboard) and sign in with your Intune admin account:"
    $code = New-Object System.Windows.Forms.TextBox
    $code.Location = New-Object System.Drawing.Point(15, 68)
    $code.Size = New-Object System.Drawing.Size(250, 34)
    $code.Font = New-Object System.Drawing.Font('Consolas', 16, [System.Drawing.FontStyle]::Bold)
    $code.ReadOnly = $true
    $code.Text = [string]$dc.user_code
    $open = New-Object System.Windows.Forms.Button
    $open.Location = New-Object System.Drawing.Point(15, 150)
    $open.Size = New-Object System.Drawing.Size(140, 30)
    $open.Text = 'Open browser again'
    $open.Tag = [string]$dc.verification_uri
    $open.Add_Click({ param($s) Start-Process $s.Tag })
    $cancel = New-Object System.Windows.Forms.Button
    $cancel.Location = New-Object System.Drawing.Point(345, 150)
    $cancel.Size = New-Object System.Drawing.Size(85, 30)
    $cancel.Text = 'Cancel'
    $cancel.Add_Click({ param($s) $s.FindForm().Close() })
    $dlg.Controls.AddRange(@($info, $code, $open, $cancel))
    $script:DeviceCodeCancelled = $false
    $dlg.Add_FormClosed({ $script:DeviceCodeCancelled = $true })
    $dlg.Show($script:form)
    Start-Process ([string]$dc.verification_uri)
    Write-UiLog "Device code sign-in: enter code $($dc.user_code) at $($dc.verification_uri)"

    $interval = [int]$dc.interval
    if ($interval -lt 1) { $interval = 5 }
    $deadline = (Get-Date).AddSeconds([int]$dc.expires_in)
    try {
        while ($true) {
            $until = (Get-Date).AddSeconds($interval)
            while ((Get-Date) -lt $until -and -not $script:DeviceCodeCancelled -and -not $script:State.StopRequested) { Start-Sleep -Milliseconds 100; Invoke-UiPump }
            if ($script:DeviceCodeCancelled -or $script:State.StopRequested) { throw 'Sign-in cancelled.' }
            if ((Get-Date) -gt $deadline) { throw 'The sign-in code expired. Connect again.' }
            try {
                return Invoke-AadTokenRequest -Body @{ grant_type = 'urn:ietf:params:oauth:grant-type:device_code'; device_code = [string]$dc.device_code }
            }
            catch {
                $aad = $_.Exception.Data['AadError']
                if ($aad -eq 'authorization_pending') { continue }
                if ($aad -eq 'slow_down') { $interval += 5; continue }
                throw
            }
        }
    }
    finally {
        $script:DeviceCodeCancelled = $false
        if (-not $dlg.IsDisposed) { $dlg.Close(); $dlg.Dispose() }
        $script:DeviceCodeCancelled = $false
    }
}

function Request-PastedToken {
    <# Dialog to paste a bearer token. Loops until a valid token is pasted or the user cancels ($null). #>
    param([string]$Reason = '')

    $pasted = ''
    while ($true) {
        $dlg = New-Object System.Windows.Forms.Form
        $dlg.Text = 'Paste access token'
        $dlg.Size = New-Object System.Drawing.Size(680, 470)
        $dlg.StartPosition = 'CenterParent'
        $dlg.FormBorderStyle = 'FixedDialog'
        $dlg.MaximizeBox = $false
        $dlg.MinimizeBox = $false

        $y = 12
        if ($Reason) {
            $why = New-Object System.Windows.Forms.Label
            $why.Location = New-Object System.Drawing.Point(15, $y)
            $why.Size = New-Object System.Drawing.Size(640, 36)
            $why.ForeColor = [System.Drawing.Color]::FromArgb(176, 112, 0)
            $why.Text = "$Reason The run is paused until a new token is pasted."
            $dlg.Controls.Add($why)
            $y += 40
        }
        $help = New-Object System.Windows.Forms.Label
        $help.Location = New-Object System.Drawing.Point(15, $y)
        $help.Size = New-Object System.Drawing.Size(640, 130)
        $help.Text = "To copy a token from the Intune portal:`r`n" +
        "  1. Click 'Open Intune portal' and sign in (activate your PIM role first if you use PIM).`r`n" +
        "  2. Press F12, open the Network tab and type graph.microsoft.com in the filter box.`r`n" +
        "  3. In the portal, open Devices > All devices so requests appear.`r`n" +
        "  4. Click a request to graph.microsoft.com > Headers > Request Headers, and copy the Authorization value.`r`n" +
        "  5. Paste it below (the 'Bearer ' prefix is optional).`r`n`r`n" +
        "Portal tokens last about an hour and cannot be renewed here, so you will be asked for a new one before it expires. The token is kept in memory only."
        $dlg.Controls.Add($help)
        $y += 135

        $txt = New-Object System.Windows.Forms.TextBox
        $txt.Location = New-Object System.Drawing.Point(15, $y)
        $txt.Size = New-Object System.Drawing.Size(635, 150)
        $txt.Multiline = $true
        $txt.ScrollBars = 'Vertical'
        $txt.Font = New-Object System.Drawing.Font('Consolas', 8)
        $txt.Text = $pasted
        $dlg.Controls.Add($txt)

        $portal = New-Object System.Windows.Forms.Button
        $portal.Location = New-Object System.Drawing.Point(15, 385)
        $portal.Size = New-Object System.Drawing.Size(140, 30)
        $portal.Text = 'Open Intune portal'
        $portal.Add_Click({ Start-Process 'https://intune.microsoft.com/#view/Microsoft_Intune_DeviceSettings/DevicesMenu/~/allDevices' })
        $ok = New-Object System.Windows.Forms.Button
        $ok.Location = New-Object System.Drawing.Point(470, 385)
        $ok.Size = New-Object System.Drawing.Size(90, 30)
        $ok.Text = 'Use token'
        $ok.DialogResult = [System.Windows.Forms.DialogResult]::OK
        $cancel = New-Object System.Windows.Forms.Button
        $cancel.Location = New-Object System.Drawing.Point(565, 385)
        $cancel.Size = New-Object System.Drawing.Size(85, 30)
        $cancel.Text = 'Cancel'
        $cancel.DialogResult = [System.Windows.Forms.DialogResult]::Cancel
        $dlg.Controls.AddRange(@($portal, $ok, $cancel))
        $dlg.CancelButton = $cancel

        $result = $dlg.ShowDialog($script:form)
        $pasted = $txt.Text
        $dlg.Dispose()
        if ($result -ne [System.Windows.Forms.DialogResult]::OK) { return $null }

        $token = ConvertTo-CleanToken -Text $pasted
        $problem = Get-TokenProblem -Token $token -MinMinutes $PastedTokenMinMinutes
        if (-not $problem) {
            # The scopes listed in the token are not checked here: Graph decides, and wipe permission is verified
            # with a harmless sync request before the first wipe
            return $token
        }
        Show-Message -Text $problem -Icon Warning | Out-Null
    }
}

function Update-TokenInfo {
    <# Records the current token's expiry and scopes. For the SDK/module sign-ins it makes a cheap call
       inside the granted scopes and reads the bearer token that was sent; falls back to an estimate. #>
    if ($script:State.AccessToken) {
        Set-TokenState -Claims (ConvertFrom-JwtPayload -Token $script:State.AccessToken)
        Update-AuthLabel
        return
    }

    $ctx = Get-MgContext
    if (-not $ctx) { throw 'Not connected to Microsoft Graph.' }
    $script:State.Account = [string]$ctx.Account
    $script:State.TenantId = [string]$ctx.TenantId
    $script:State.Scopes = @($ctx.Scopes)

    $tokenRead = $false
    try {
        $resp = Invoke-MgGraphRequest -Uri "$GraphBase/deviceManagement/managedDevices?`$top=1&`$select=id" -Method GET -OutputType HttpResponseMessage -ErrorAction Stop
        $status = [int]$resp.StatusCode
        if ($status -eq 401) { throw 'The token was rejected (401 Unauthorized).' }
        if ($status -eq 403) { throw 'Access denied reading managed devices (403). Check the Intune Administrator role / PIM activation.' }

        $auth = $resp.RequestMessage.Headers.Authorization
        if ($auth -and $auth.Parameter) {
            $claims = ConvertFrom-JwtPayload -Token $auth.Parameter
            if ($claims -and $claims.exp) {
                Set-TokenState -Claims $claims
                $tokenRead = $true
            }
        }
    }
    catch {
        if ($_.Exception.Message -match '401|403|Unauthorized|Forbidden') { throw }
        Write-UiLog "Could not read token details ($($_.Exception.Message)). Using an estimated expiry." -Level Warn
    }

    if (-not $tokenRead) {
        # Conservative estimate: Entra access tokens last 60-90 minutes
        $script:State.TokenExpiryUtc = (Get-Date).ToUniversalTime().AddMinutes(55)
        $script:State.ExpiryIsGuess = $true
    }
    Update-AuthLabel
}

function Update-AuthLabel {
    if (-not $script:State.Connected -or -not $script:State.TokenExpiryUtc) {
        $lblAuth.Text = 'Not connected'
        $lblAuth.ForeColor = [System.Drawing.Color]::FromArgb(192, 0, 0)
        return
    }
    $mins = [math]::Floor(($script:State.TokenExpiryUtc - (Get-Date).ToUniversalTime()).TotalMinutes)
    $est = if ($script:State.ExpiryIsGuess) { ' (estimated)' } else { '' }
    $renew = switch ($script:State.AuthMode) {
        'Token' { 'pasted token, asks for a new one' }
        'Community' { 'renews by signing in again' }
        default { 'renews automatically' }
    }
    $priv = if ($script:State.WipeVerified -eq $true) { 'wipe permission verified' }
    elseif ($script:State.WipeVerified -eq $false) { 'wipe permission REFUSED by Graph' }
    elseif ($script:State.Scopes -contains $PrivilegedScope) { 'wipe permission in token' }
    else { 'wipe permission checked before first wipe' }
    $lblAuth.Text = "$($script:State.Account)  |  token ~$mins min$est ($renew)  |  $priv"
    $lblAuth.ForeColor = if ($mins -lt $TokenRefreshMinutes -or $priv -like '*REFUSED*') { [System.Drawing.Color]::FromArgb(176, 112, 0) } else { [System.Drawing.Color]::FromArgb(0, 110, 0) }
}

function Connect-WipeGraph {
    param([switch]$Reconnect)

    $mode = if ($Reconnect -and $script:State.AuthMode) { $script:State.AuthMode } else { Get-AuthMode }
    Initialize-RequiredModule -ModuleName 'Microsoft.Graph.Authentication'

    if ($Reconnect) { Write-UiLog 'Signing in again to get a fresh token. Complete the sign-in prompt if one appears...' -Level Warn }
    else { Write-UiLog "Connecting to Microsoft Graph: $($cmbAuth.SelectedItem)" }

    $script:State.AuthMode = $mode
    if (-not $Reconnect) { $script:State.WipeVerified = $null }
    $script:State.AccessToken = $null
    $script:State.RefreshToken = $null
    $lblAuth.Text = 'Waiting for sign-in...'
    Invoke-UiPump

    switch ($mode) {
        'Browser' {
            $t = Invoke-BrowserSignIn
            Set-GraphAccessToken -Token $t.access_token
            $script:State.RefreshToken = $t.refresh_token
            Test-GraphAccess
        }
        'DeviceCode' {
            $t = Invoke-DeviceCodeSignIn
            Set-GraphAccessToken -Token $t.access_token
            $script:State.RefreshToken = $t.refresh_token
            Test-GraphAccess
        }
        'Token' {
            $tok = Request-PastedToken
            if (-not $tok) { throw 'Cancelled: no access token was provided.' }
            Set-GraphAccessToken -Token $tok
            Test-GraphAccess
        }
        'Community' {
            Initialize-RequiredModule -ModuleName 'MgGraphCommunity'
            try { Disconnect-MgGraph -ErrorAction SilentlyContinue | Out-Null } catch { }
            Connect-MgGraphCommunity -Scopes $RequiredScopes -NoWelcome -ErrorAction Stop
            $script:State.Connected = $true
            Update-TokenInfo
        }
        default {
            try { Disconnect-MgGraph -ErrorAction SilentlyContinue | Out-Null } catch { }
            $p = @{ Scopes = $RequiredScopes; NoWelcome = $true; ErrorAction = 'Stop' }
            if ((Get-AadTenant) -ne 'organizations') { $p['TenantId'] = Get-AadTenant }
            Connect-MgGraph @p
            $script:State.Connected = $true
            Update-TokenInfo
        }
    }

    $mins = [math]::Floor(($script:State.TokenExpiryUtc - (Get-Date).ToUniversalTime()).TotalMinutes)
    Write-UiLog "Connected as $($script:State.Account). Token valid for ~$mins min." -Level OK
    if ($mode -eq 'Token') {
        Write-UiLog 'Pasted tokens cannot be renewed here. You will be asked for a new token before this one expires.' -Level Warn
    }
    if ($script:State.Scopes -notcontains $PrivilegedScope) {
        $appText = if ($script:State.TokenApp) { " (token issued to app '$($script:State.TokenApp)')" } else { '' }
        Write-UiLog "The token's scope list does not name $PrivilegedScope$appText. Graph may still allow wipes; this is checked with a harmless device sync before the first wipe." -Level Info
    }
}

function Restore-WipeAuth {
    <# Gets a fresh token using the current sign-in method: silent refresh first, interactive or paste if needed. #>
    param([string]$Reason)

    switch ($script:State.AuthMode) {
        { $_ -in @('Browser', 'DeviceCode') } {
            if ($script:State.RefreshToken) {
                try {
                    $t = Invoke-AadTokenRequest -Body @{ grant_type = 'refresh_token'; refresh_token = $script:State.RefreshToken; scope = $OAuthScope }
                    Set-GraphAccessToken -Token $t.access_token
                    if ($t.refresh_token) { $script:State.RefreshToken = $t.refresh_token }
                    $mins = [math]::Floor(($script:State.TokenExpiryUtc - (Get-Date).ToUniversalTime()).TotalMinutes)
                    Write-UiLog "Token renewed silently, valid ~$mins min." -Level OK
                    return
                }
                catch {
                    Write-UiLog "Silent renewal failed ($($_.Exception.Message)). Signing in again..." -Level Warn
                }
            }
            Connect-WipeGraph -Reconnect
            return
        }
        'Token' {
            Write-UiLog "$Reason Waiting for a new pasted token..." -Level Warn
            $tok = Request-PastedToken -Reason $Reason
            if (-not $tok) { throw 'No new access token was provided.' }
            Set-GraphAccessToken -Token $tok
            Test-GraphAccess
            $mins = [math]::Floor(($script:State.TokenExpiryUtc - (Get-Date).ToUniversalTime()).TotalMinutes)
            Write-UiLog "New token accepted, valid ~$mins min." -Level OK
            return
        }
        default {
            Connect-WipeGraph -Reconnect
        }
    }
}

function Confirm-FreshToken {
    <# Called before every wipe: make sure the token will outlive the next call by a safe margin. #>
    if (-not $script:State.TokenExpiryUtc) { return }
    $threshold = if ($script:State.AuthMode -eq 'Token') { $PastedTokenRefreshMinutes } else { $TokenRefreshMinutes }
    $left = ($script:State.TokenExpiryUtc - (Get-Date).ToUniversalTime()).TotalMinutes
    if ($left -ge $threshold) { return }

    Write-UiLog ("Token expires in {0:N0} min, renewing before continuing..." -f [math]::Max($left, 0)) -Level Warn
    try {
        if ($script:State.AuthMode -eq 'GraphSdk') {
            # The Graph SDK renews on its own; re-read the token first and only sign in again if it is still old
            try { Update-TokenInfo } catch { }
            $left = ($script:State.TokenExpiryUtc - (Get-Date).ToUniversalTime()).TotalMinutes
            if ($left -ge $threshold -and -not $script:State.ExpiryIsGuess) {
                Write-UiLog ("Token renewed, valid ~{0:N0} min." -f $left) -Level OK
                return
            }
        }
        Restore-WipeAuth -Reason ("The current token expires in {0:N0} min." -f [math]::Max($left, 0))
        $left = ($script:State.TokenExpiryUtc - (Get-Date).ToUniversalTime()).TotalMinutes
        if ($left -lt 2 -and -not $script:State.ExpiryIsGuess) {
            throw "Sign-in returned a token that expires in $([math]::Floor($left)) min (a stale cached token). Close PowerShell, sign in again and resume."
        }
    }
    catch {
        # Tag as 401 so the run's authorisation circuit breaker counts it
        $ex = [System.Exception]::new("Token renewal failed: $($_.Exception.Message)")
        $ex.Data['HttpStatus'] = 401
        throw $ex
    }
}

# ============================================================================
# GRAPH: REQUESTS WITH ERROR HANDLING
# ============================================================================
function Get-GraphErrorStatus {
    param($ErrorRecord)
    $ex = $ErrorRecord.Exception
    if ($ex.Data -and $ex.Data.Contains('HttpStatus')) { return [int]$ex.Data['HttpStatus'] }
    $respProp = $ex.PSObject.Properties['Response']
    if ($respProp -and $respProp.Value -and $respProp.Value.StatusCode) { return [int]$respProp.Value.StatusCode }

    $m = "$($ex.Message) $($ErrorRecord.ErrorDetails.Message)"
    if ($m -match 'Unauthorized|\b401\b') { return 401 }
    elseif ($m -match 'Forbidden|\b403\b') { return 403 }
    elseif ($m -match 'TooManyRequests|throttl|\b429\b') { return 429 }
    elseif ($m -match 'NotFound|\b404\b') { return 404 }
    elseif ($m -match 'BadRequest|\b400\b') { return 400 }
    elseif ($m -match 'ServiceUnavailable|\b503\b') { return 503 }
    elseif ($m -match 'GatewayTimeout|\b504\b') { return 504 }
    elseif ($m -match 'BadGateway|\b502\b') { return 502 }
    elseif ($m -match 'InternalServerError|\b500\b') { return 500 }
    return 0
}

function Get-GraphRetryAfter {
    param($ErrorRecord, [int]$Default)
    try {
        $resp = $ErrorRecord.Exception.PSObject.Properties['Response'].Value
        $delta = $resp.Headers.RetryAfter.Delta
        if ($delta) { return [math]::Max([int]$delta.TotalSeconds, 1) }
    }
    catch { }
    return $Default
}

function Get-GraphErrorText {
    param($ErrorRecord)
    $text = [string]$ErrorRecord.Exception.Message
    $details = [string]$ErrorRecord.ErrorDetails.Message
    if ($details) {
        try {
            $j = $details | ConvertFrom-Json -ErrorAction Stop
            if ($j.error.message) { $text = "$text $($j.error.code): $($j.error.message)" }
        }
        catch { $text = "$text $details" }
    }
    $text = ($text -replace '\s+', ' ').Trim()
    if ($text.Length -gt 400) { $text = $text.Substring(0, 400) + '...' }
    return $text
}

function Invoke-WipeGraphRequest {
    <# Invoke-MgGraphRequest with: one re-authentication + retry on 401, Retry-After aware retries on 429/5xx.
       Throws an exception whose Data['HttpStatus'] holds the final status code. #>
    param(
        [string]$Uri,
        [string]$Method = 'GET',
        [string]$Body,
        [int]$MaxAttempts = 4
    )

    $attempt = 0
    $reauthDone = $false
    while ($true) {
        $attempt++
        try {
            $params = @{ Uri = $Uri; Method = $Method; ErrorAction = 'Stop' }
            if ($Body) { $params['Body'] = $Body; $params['ContentType'] = 'application/json' }
            return (Invoke-MgGraphRequest @params)
        }
        catch {
            $err = $_
            $status = Get-GraphErrorStatus -ErrorRecord $err
            $text = Get-GraphErrorText -ErrorRecord $err

            if ($status -eq 401 -and -not $reauthDone) {
                $reauthDone = $true
                Write-UiLog 'Graph returned 401 Unauthorized (token expired or revoked). Renewing the token and retrying...' -Level Warn
                try {
                    Restore-WipeAuth -Reason 'Microsoft Graph rejected the current token (401 Unauthorized).'
                }
                catch {
                    $ex = [System.Exception]::new("Re-authentication failed: $($_.Exception.Message)")
                    $ex.Data['HttpStatus'] = 401
                    throw $ex
                }
                continue
            }

            if (($status -eq 429 -or $status -ge 500) -and $attempt -lt $MaxAttempts -and -not $script:State.StopRequested) {
                $default = if ($status -eq 429) { 60 } else { [int][math]::Pow(2, $attempt) * 5 }
                $wait = Get-GraphRetryAfter -ErrorRecord $err -Default $default
                Write-UiLog "Graph returned $status. Waiting $wait s before retry $attempt of $($MaxAttempts - 1)..." -Level Warn
                Wait-WithEvents -Seconds $wait
                continue
            }

            $ex = [System.Exception]::new($text)
            $ex.Data['HttpStatus'] = $status
            throw $ex
        }
    }
}

function Get-WipeGraphAllPages {
    param([string]$Uri)
    $results = [System.Collections.Generic.List[object]]::new()
    $next = $Uri
    while ($next) {
        if ($script:State.StopRequested) { throw 'Stopped by user.' }
        $resp = Invoke-WipeGraphRequest -Uri $next
        if ($null -ne $resp.value) { foreach ($item in $resp.value) { $results.Add($item) } }
        elseif ($resp -and -not $resp.ContainsKey('value')) { $results.Add($resp) }
        $next = $resp.'@odata.nextLink'
        Invoke-UiPump
    }
    return , $results
}

# ============================================================================
# GROUP AND DEVICE RESOLUTION (ported from Get-DevicesByEntraGroup in V3)
# ============================================================================
function Find-EntraGroup {
    param([string]$Text)
    $Text = $Text.Trim()
    $guid = [guid]::Empty
    if ([guid]::TryParse($Text, [ref]$guid)) {
        $g = Invoke-WipeGraphRequest -Uri "$GraphBase/groups/$Text`?`$select=id,displayName,groupTypes,membershipRule"
        return @($g)
    }
    $escaped = $Text -replace "'", "''"
    $escaped = [uri]::EscapeDataString($escaped)
    $uri = "$GraphBase/groups?`$filter=startswith(displayName,'$escaped')&`$select=id,displayName,groupTypes,membershipRule&`$top=100"
    $groups = Get-WipeGraphAllPages -Uri $uri
    return @($groups | Sort-Object { $_.displayName })
}

function Get-WipeTargetDevices {
    param([string]$GroupId, [bool]$IncludeNested)

    $memberPath = if ($IncludeNested) { 'transitiveMembers' } else { 'members' }
    Write-UiLog "Retrieving group $memberPath..."
    $members = Get-WipeGraphAllPages -Uri "$GraphBase/groups/$GroupId/$memberPath`?`$top=999"

    $deviceMembers = @($members | Where-Object { $_.'@odata.type' -eq '#microsoft.graph.device' })
    $userMembers = @($members | Where-Object { $_.'@odata.type' -eq '#microsoft.graph.user' })
    $groupMembers = @($members | Where-Object { $_.'@odata.type' -eq '#microsoft.graph.group' })
    $otherCount = $members.Count - $deviceMembers.Count - $userMembers.Count - $groupMembers.Count
    Write-UiLog "Group has $($members.Count) member(s): $($deviceMembers.Count) device(s), $($userMembers.Count) user(s), $($groupMembers.Count) nested group(s)" -Level OK
    if ($groupMembers.Count -gt 0 -and -not $IncludeNested) {
        Write-UiLog "$($groupMembers.Count) nested group(s) are not expanded. Tick 'Include nested groups' to include their members." -Level Warn
    }
    if ($otherCount -gt 0) { Write-UiLog "$otherCount member(s) are neither devices nor users and are ignored." -Level Warn }

    $allDevices = Get-AllManagedDevicesCached -Refresh

    $emptyGuid = '00000000-0000-0000-0000-000000000000'
    $byEntraId = @{}
    $byUpn = @{}
    foreach ($d in $allDevices) {
        $eid = [string]$d.azureADDeviceId
        if ($eid -and $eid -ne $emptyGuid) {
            if (-not $byEntraId.ContainsKey($eid)) { $byEntraId[$eid] = [System.Collections.Generic.List[object]]::new() }
            $byEntraId[$eid].Add($d)
        }
        $upn = [string]$d.userPrincipalName
        if ($upn) {
            if (-not $byUpn.ContainsKey($upn)) { $byUpn[$upn] = [System.Collections.Generic.List[object]]::new() }
            $byUpn[$upn].Add($d)
        }
    }

    $targets = [System.Collections.Generic.List[object]]::new()
    $seen = @{}
    $notInIntune = [System.Collections.Generic.List[string]]::new()
    $script:NotInIntune = [System.Collections.Generic.List[object]]::new()

    foreach ($m in $deviceMembers) {
        $eid = [string]$m.deviceId
        if (-not $eid) {
            Write-UiLog "Device member $($m.displayName) returned no deviceId. Check Device.Read.All is granted." -Level Warn
            continue
        }
        if (-not $byEntraId.ContainsKey($eid)) {
            $notInIntune.Add([string]$m.displayName)
            $script:NotInIntune.Add([PSCustomObject]@{ Name = [string]$m.displayName; EntraDeviceId = $eid; OS = [string]$m.operatingSystem; Model = [string]$m.model })
            continue
        }

        # Several Intune records for one Entra device are stale re-enrollments: target the most recently synced one
        $sorted = @($byEntraId[$eid] | Sort-Object -Property { if ($_.lastSyncDateTime) { [DateTime]$_.lastSyncDateTime } else { [DateTime]::MinValue } } -Descending)
        $dev = $sorted[0]
        if ($sorted.Count -gt 1) {
            $skipped = ($sorted | Select-Object -Skip 1 | ForEach-Object { "$($_.deviceName) [last sync $($_.lastSyncDateTime)]" }) -join '; '
            Write-UiLog "$($m.displayName) has $($sorted.Count) Intune records. Targeting the most recent; skipped: $skipped" -Level Warn
        }
        if (-not $seen.ContainsKey($dev.id)) {
            $seen[$dev.id] = $true
            $targets.Add([PSCustomObject]@{ Device = $dev; Source = 'Device member' })
        }
    }
    if ($notInIntune.Count -gt 0) {
        Write-UiLog "$($notInIntune.Count) device member(s) have no Intune record and will not be wiped: $($notInIntune -join ', '). They are usually Entra-registered or stale Entra objects; they are listed in grey." -Level Warn
    }

    foreach ($m in $userMembers) {
        $keys = @([string]$m.userPrincipalName, [string]$m.mail) | Where-Object { $_ } | Select-Object -Unique
        foreach ($k in $keys) {
            if (-not $byUpn.ContainsKey($k)) { continue }
            foreach ($dev in $byUpn[$k]) {
                if (-not $seen.ContainsKey($dev.id)) {
                    $seen[$dev.id] = $true
                    $targets.Add([PSCustomObject]@{ Device = $dev; Source = "User: $k" })
                }
            }
        }
    }
    return , $targets
}

function Get-AllManagedDevicesCached {
    <# All Intune managed devices (selected fields). Cached for 10 minutes so several hostname searches do not
       re-download the tenant; -Refresh forces a fresh copy (used when loading a group). #>
    param([switch]$Refresh)
    if (-not $Refresh -and $script:DeviceCache -and ((Get-Date) - $script:DeviceCacheTime).TotalMinutes -lt 10) {
        return , $script:DeviceCache
    }
    Write-UiLog 'Retrieving Intune managed devices (this can take a minute in large tenants)...'
    $script:DeviceCache = Get-WipeGraphAllPages -Uri "$GraphBase/deviceManagement/managedDevices?`$select=$DeviceSelect"
    $script:DeviceCacheTime = Get-Date
    Write-UiLog "Retrieved $($script:DeviceCache.Count) managed device record(s)" -Level OK
    return , $script:DeviceCache
}

function Find-WipeDevicesByName {
    <# Finds Intune devices by hostname or serial number. Several terms can be separated by commas, semicolons,
       spaces or new lines; * and ? work as wildcards. Several Intune records of the same physical device
       (same Entra device ID, from re-enrollment) are collapsed to the most recently synced one. #>
    param([string]$Text)

    $terms = @($Text -split '[,;\s]+' | ForEach-Object { $_.Trim().Trim('"', "'") } | Where-Object { $_ } | Select-Object -Unique)
    $all = Get-AllManagedDevicesCached
    $emptyGuid = '00000000-0000-0000-0000-000000000000'
    $targets = [System.Collections.Generic.List[object]]::new()
    $seen = @{}
    $notFound = [System.Collections.Generic.List[string]]::new()

    foreach ($term in $terms) {
        $isWild = $term -match '[\*\?]'
        $found = @($all | Where-Object {
                if ($isWild) { ([string]$_.deviceName -like $term) -or ([string]$_.serialNumber -like $term) }
                else { ([string]$_.deviceName -eq $term) -or ([string]$_.serialNumber -eq $term) }
            })
        if ($found.Count -eq 0) { $notFound.Add($term); continue }

        $physical = @($found | Group-Object -Property {
                $eid = [string]$_.azureADDeviceId
                if ($eid -and $eid -ne $emptyGuid) { $eid } else { [string]$_.id }
            })
        foreach ($g in $physical) {
            $sorted = @($g.Group | Sort-Object -Property { if ($_.lastSyncDateTime) { [DateTime]$_.lastSyncDateTime } else { [DateTime]::MinValue } } -Descending)
            $dev = $sorted[0]
            if ($sorted.Count -gt 1) {
                $skipped = ($sorted | Select-Object -Skip 1 | ForEach-Object { "$($_.deviceName) [last sync $($_.lastSyncDateTime)]" }) -join '; '
                Write-UiLog "$($dev.deviceName) has $($sorted.Count) Intune records. Using the most recently synced; skipped: $skipped" -Level Warn
            }
            if (-not $seen.ContainsKey($dev.id)) {
                $seen[$dev.id] = $true
                $targets.Add([PSCustomObject]@{ Device = $dev; Source = "Search: $term" })
            }
        }
        if ($physical.Count -gt 1 -and -not $isWild) {
            Write-UiLog "'$term' matches $($physical.Count) different devices. All are listed; untick any you do not want." -Level Warn
        }
        if ($isWild -and $physical.Count -gt 200) {
            Write-UiLog "'$term' matches $($physical.Count) devices. Check the list carefully before wiping." -Level Warn
        }
    }
    if ($notFound.Count -gt 0) {
        Write-UiLog "No Intune device found for: $($notFound -join ', ')" -Level Warn
    }
    return , $targets
}

function Add-DeviceRows {
    <# Adds target devices to the grid's table; skips devices already listed. Returns the number added. #>
    param($Table, $Targets)
    $existing = @{}
    foreach ($r in $Table.Rows) { if ($r['IntuneId']) { $existing[[string]$r['IntuneId']] = $true } }
    $added = 0
    $pending = 0
    foreach ($tg in $Targets) {
        $d = $tg.Device
        if ($existing.ContainsKey([string]$d.id)) { continue }
        $existing[[string]$d.id] = $true
        $state = [string]$d.managementState
        $isPending = $state -in $PendingStates
        if ($isPending) { $pending++ }
        $lastSync = if ($d.lastSyncDateTime) { ([DateTime]$d.lastSyncDateTime).ToLocalTime().ToString('yyyy-MM-dd HH:mm') } else { 'Never' }
        [void]$Table.Rows.Add((-not $isPending), $d.deviceName, $d.serialNumber, $d.userPrincipalName, $d.operatingSystem,
            $d.model, $lastSync, $state, $tg.Source, $(if ($isPending) { 'Already pending - skipped' } else { 'Not processed' }), '',
            (Get-Date).ToString('yyyy-MM-dd HH:mm:ss'), $d.id, $d.azureADDeviceId)
        $added++
    }
    if ($pending -gt 0) { Write-UiLog "$pending device(s) already have a wipe/retire pending and were unticked." -Level Warn }
    return $added
}

function Get-SelectedWipeOption {
    $o = $WipeOptions[[math]::Max($cmbWipeOption.SelectedIndex, 0)]
    return [PSCustomObject]@{ Key = $o.Key; Label = $o.Label; Desc = $o.Desc }
}

# ============================================================================
# EXPORT
# ============================================================================
function Start-ExportFiles {
    param([string]$Label)
    $folder = $txtExport.Text.Trim()
    try {
        if (-not (Test-Path -Path $folder -PathType Container)) { New-Item -Path $folder -ItemType Directory -Force -ErrorAction Stop | Out-Null }
        $base = 'Wipe-Devices_{0}_{1}' -f (Get-Date -Format 'yyyyMMdd-HHmmss'), $Label
        $script:State.CsvFile = Join-Path $folder "$base.csv"
        $script:State.LogFile = Join-Path $folder "$base.log"
        Set-Content -Path $script:State.LogFile -Value $script:txtLog.Text -Encoding UTF8 -ErrorAction Stop
        Write-UiLog "Logging to $($script:State.LogFile)"
    }
    catch {
        $script:State.CsvFile = $null
        $script:State.LogFile = $null
        Write-UiLog "Export folder '$folder' is not usable, no CSV or log will be written: $($_.Exception.Message)" -Level Warn
    }
}

function Save-ExportCsv {
    param([string]$WipeOption)
    if (-not $script:State.CsvFile -or -not $script:DeviceTable) { return }
    try {
        $rows = foreach ($r in $script:DeviceTable.Rows) {
            [PSCustomObject]@{
                Timestamp          = $r['Timestamp']
                DeviceName         = $r['Device']
                SerialNumber       = $r['Serial']
                UserPrincipalName  = $r['User']
                OperatingSystem    = $r['OS']
                Model              = $r['Model']
                LastSync           = $r['LastSync']
                ManagementState    = $r['State']
                IntuneDeviceId     = $r['IntuneId']
                EntraDeviceId      = $r['EntraId']
                Source             = $r['Source']
                Ticked             = $r['Wipe']
                WipeOption         = $WipeOption
                Target             = $script:State.TargetDescription
                Result             = $r['Result']
                Error              = $r['Error']
            }
        }
        $rows | Export-Csv -Path $script:State.CsvFile -NoTypeInformation -Encoding UTF8 -ErrorAction Stop
    }
    catch {
        Write-UiLog "Could not write CSV $($script:State.CsvFile): $($_.Exception.Message)" -Level Warn
    }
}

# ============================================================================
# WIPE
# ============================================================================
function Invoke-SingleWipe {
    param($Row, $Option)

    $id = [string]$Row['IntuneId']
    if ($Option.Key -eq 'Retire') {
        # retire takes no request body
        Invoke-WipeGraphRequest -Uri "$GraphBase/deviceManagement/managedDevices('$id')/retire" -Method POST | Out-Null
        return
    }

    # Portal option -> Graph wipe parameters (see learn.microsoft.com/graph/api/intune-devices-manageddevice-wipe)
    $body = @{ keepEnrollmentData = $false; keepUserData = $false }
    switch ($Option.Key) {
        'WipeKeepUserData' { $body['keepEnrollmentData'] = $true; $body['keepUserData'] = $true }   # doWipePersistUserData: keeps user data, stays enrolled
        'ProtectedWipe'    { $body['useProtectedWipe'] = $true }                                     # doWipeProtected: continues through power loss
    }
    if ($Option.Pin -and [string]$Row['OS'] -eq 'macOS') { $body['macOsUnlockCode'] = $Option.Pin }
    Invoke-WipeGraphRequest -Uri "$GraphBase/deviceManagement/managedDevices('$id')/wipe" -Method POST -Body ($body | ConvertTo-Json -Compress) | Out-Null
}

function Test-WipePermission {
    <# The token's scope list does not name the wipe permission, but Graph may still allow it (it is Graph, not the
       list, that decides). Check with syncDevice, which needs the same PrivilegedOperations permission as wipe but only
       asks the device to check in. Returns $true if Graph accepted it. #>
    param($Row)
    $id = [string]$Row['IntuneId']
    $name = [string]$Row['Device']
    Write-UiLog "Checking wipe permission with a harmless sync request to $name (the token's scope list does not name it)..."
    try {
        Invoke-WipeGraphRequest -Uri "$GraphBase/deviceManagement/managedDevices('$id')/syncDevice" -Method POST | Out-Null
        $script:State.WipeVerified = $true
        Write-UiLog 'Graph accepted a privileged device action with this sign-in. Wipes are allowed.' -Level OK
        Update-AuthLabel
        return $true
    }
    catch {
        $status = 0
        if ($_.Exception.Data -and $_.Exception.Data.Contains('HttpStatus')) { $status = [int]$_.Exception.Data['HttpStatus'] }
        $msg = $_.Exception.Message
        if ($status -eq 403) {
            $script:State.WipeVerified = $false
            Update-AuthLabel
            Write-UiLog "Graph refused the privileged action (403): $msg" -Level Error
            $how = switch ($script:State.AuthMode) {
                'Token' { "Copy a token from a graph.microsoft.com request in the Intune portal (intune.microsoft.com, not the Azure portal) after activating your Intune Administrator role, then press Connect again." }
                default { "Either an admin consents to $PrivilegedScope for the sign-in app, or you use 'Paste bearer token' with a token copied from the Intune portal." }
            }
            Show-Message -Text "Microsoft Graph refused the wipe permission for this sign-in (403 Forbidden).`r`n`r`n$how`r`n`r`nNothing was wiped." -Icon Error | Out-Null
        }
        elseif ($status -eq 404) {
            # Device gone: the check itself is inconclusive, let the run's own error handling deal with it
            Write-UiLog "Permission check inconclusive ($name was not found). Continuing; the first wipe will show whether it is allowed." -Level Warn
            return $true
        }
        else {
            Write-UiLog "Permission check failed: $msg" -Level Error
            Show-Message -Text "Could not check the wipe permission:`r`n$msg`r`n`r`nNothing was wiped." -Icon Error | Out-Null
        }
        return $false
    }
}

function Show-WipeOptionsDialog {
    <# Portal-style wipe prompt: choose the wipe option, optional macOS PIN, tick "I understand" (and for several
       devices type the count). Returns the chosen option, or $null if cancelled. #>
    param([int]$Count, [string]$Target, [string]$FirstDevice, [int]$MacCount, [int]$NonWindowsCount, [string]$DefaultKey = 'Wipe', [string]$DefaultPin = '')

    $grey = [System.Drawing.Color]::FromArgb(96, 96, 96)
    $dlg = New-Object System.Windows.Forms.Form
    $dlg.Text = 'Intune Device Wipe'
    $dlg.StartPosition = 'CenterParent'
    $dlg.FormBorderStyle = 'FixedDialog'
    $dlg.MaximizeBox = $false
    $dlg.MinimizeBox = $false
    $dlg.Font = New-Object System.Drawing.Font('Segoe UI', 9.5)
    $dlg.ClientSize = New-Object System.Drawing.Size(640, 600)

    $y = 16
    $title = New-Object System.Windows.Forms.Label
    $title.Location = New-Object System.Drawing.Point(20, $y)
    $title.Size = New-Object System.Drawing.Size(600, 30)
    $title.Font = New-Object System.Drawing.Font('Segoe UI', 14, [System.Drawing.FontStyle]::Bold)
    $title.Text = if ($Count -eq 1) { "Wipe $($FirstDevice)?" } else { "Wipe $Count devices?" }
    $title.AutoEllipsis = $true
    $dlg.Controls.Add($title)
    $y += 38

    $intro = New-Object System.Windows.Forms.Label
    $intro.Location = New-Object System.Drawing.Point(20, $y)
    $intro.Size = New-Object System.Drawing.Size(600, 40)
    $intro.Text = "Target: $Target. Wiping returns devices to default settings. Choose what is kept below. You can't undo this action."
    $dlg.Controls.Add($intro)
    $y += 40
    $learn = New-Object System.Windows.Forms.LinkLabel
    $learn.Location = New-Object System.Drawing.Point(20, $y)
    $learn.Size = New-Object System.Drawing.Size(300, 20)
    $learn.Text = 'Learn more about device wipe'
    $learn.Add_LinkClicked({ Start-Process 'https://learn.microsoft.com/intune/device-management/actions/wipe' })
    $dlg.Controls.Add($learn)
    $y += 32

    $options = $WipeOptions
    $radios = @()
    foreach ($o in $options) {
        $r = New-Object System.Windows.Forms.RadioButton
        $r.Location = New-Object System.Drawing.Point(20, $y)
        $r.Size = New-Object System.Drawing.Size(600, 24)
        $r.Font = New-Object System.Drawing.Font('Segoe UI', 10.5)
        $r.Text = $o.Label
        $r.Tag = $o.Key
        $dlg.Controls.Add($r)
        $radios += $r
        $y += 25
        $d = New-Object System.Windows.Forms.Label
        $d.Location = New-Object System.Drawing.Point(40, $y)
        $d.Size = New-Object System.Drawing.Size(580, 36)
        $d.ForeColor = $grey
        $d.Text = $o.Desc
        $dlg.Controls.Add($d)
        $y += 42
    }
    $default = @($radios | Where-Object { $_.Tag -eq $DefaultKey })
    if ($default.Count -gt 0) { $default[0].Checked = $true } else { $radios[0].Checked = $true }

    $platformNote = New-Object System.Windows.Forms.Label
    $platformNote.Location = New-Object System.Drawing.Point(20, $y)
    $platformNote.Size = New-Object System.Drawing.Size(600, 34)
    $platformNote.ForeColor = [System.Drawing.Color]::FromArgb(176, 112, 0)
    $platformNote.Text = "$NonWindowsCount of the selected device(s) are not Windows. This option is Windows-only, so Intune may reject it for those devices (they will show as Failed)."
    $platformNote.Visible = $false
    $dlg.Controls.Add($platformNote)
    $y += 36

    $lblPin = New-Object System.Windows.Forms.Label
    $lblPin.Location = New-Object System.Drawing.Point(20, ($y + 3))
    $lblPin.Size = New-Object System.Drawing.Size(330, 20)
    $lblPin.Text = "macOS unlock PIN, 6 digits ($MacCount Mac(s), optional):"
    $txtPin = New-Object System.Windows.Forms.TextBox
    $txtPin.Location = New-Object System.Drawing.Point(355, $y)
    $txtPin.Size = New-Object System.Drawing.Size(90, 24)
    $txtPin.MaxLength = 6
    $txtPin.Text = $DefaultPin
    $dlg.Controls.AddRange(@($lblPin, $txtPin))
    $lblPin.Visible = ($MacCount -gt 0)
    $txtPin.Visible = ($MacCount -gt 0)
    if ($MacCount -gt 0) { $y += 32 }

    if ($Count -gt 500) {
        $limit = New-Object System.Windows.Forms.Label
        $limit.Location = New-Object System.Drawing.Point(20, $y)
        $limit.Size = New-Object System.Drawing.Size(600, 34)
        $limit.ForeColor = [System.Drawing.Color]::FromArgb(192, 0, 0)
        $limit.Text = "Intune accepts up to 500 wipe actions per tenant per day (portal and API combined). Devices beyond the limit will fail; untick some and run the rest tomorrow."
        $dlg.Controls.Add($limit)
        $y += 38
    }

    $lblCount = New-Object System.Windows.Forms.Label
    $lblCount.Location = New-Object System.Drawing.Point(20, ($y + 3))
    $lblCount.Size = New-Object System.Drawing.Size(330, 20)
    $lblCount.Text = "Type the number of devices ($Count) to confirm:"
    $txtCount = New-Object System.Windows.Forms.TextBox
    $txtCount.Location = New-Object System.Drawing.Point(355, $y)
    $txtCount.Size = New-Object System.Drawing.Size(90, 24)
    $dlg.Controls.AddRange(@($lblCount, $txtCount))
    $lblCount.Visible = ($Count -gt 1)
    $txtCount.Visible = ($Count -gt 1)
    if ($Count -gt 1) { $y += 34 }

    $chk = New-Object System.Windows.Forms.CheckBox
    $chk.Location = New-Object System.Drawing.Point(20, $y)
    $chk.Size = New-Object System.Drawing.Size(300, 26)
    $chk.Font = New-Object System.Drawing.Font('Segoe UI', 10.5)
    $chk.Text = 'I understand'
    $dlg.Controls.Add($chk)
    $y += 40

    $ok = New-Object System.Windows.Forms.Button
    $ok.Location = New-Object System.Drawing.Point(330, $y)
    $ok.Size = New-Object System.Drawing.Size(180, 34)
    $ok.Enabled = $false
    $ok.DialogResult = [System.Windows.Forms.DialogResult]::OK
    $cancel = New-Object System.Windows.Forms.Button
    $cancel.Location = New-Object System.Drawing.Point(520, $y)
    $cancel.Size = New-Object System.Drawing.Size(100, 34)
    $cancel.Text = 'Cancel'
    $cancel.DialogResult = [System.Windows.Forms.DialogResult]::Cancel
    $dlg.Controls.AddRange(@($ok, $cancel))
    $dlg.CancelButton = $cancel
    $dlg.ClientSize = New-Object System.Drawing.Size(640, ($y + 50))

    $noun = if ($Count -eq 1) { 'device' } else { "$Count devices" }
    $update = {
        $key = ($radios | Where-Object { $_.Checked } | Select-Object -First 1).Tag
        $ok.Text = if ($key -eq 'Retire') { "Retire $noun" } else { "Wipe $noun" }
        $platformNote.Visible = ($key -in @('WipeKeepUserData', 'ProtectedWipe')) -and $NonWindowsCount -gt 0
        $txtPin.Enabled = ($key -ne 'Retire')
        $pinOk = (-not $txtPin.Visible) -or (-not $txtPin.Enabled) -or [string]::IsNullOrEmpty($txtPin.Text) -or ($txtPin.Text -match '^\d{6}$')
        $countOk = ($Count -le 1) -or ($txtCount.Text.Trim() -eq [string]$Count)
        $ok.Enabled = $chk.Checked -and $pinOk -and $countOk
    }.GetNewClosure()
    $handler = { & $update }.GetNewClosure()
    foreach ($r in $radios) { $r.Add_CheckedChanged($handler) }
    $chk.Add_CheckedChanged($handler)
    $txtPin.Add_TextChanged($handler)
    $txtCount.Add_TextChanged($handler)
    & $update

    $result = $dlg.ShowDialog($script:form)
    $key = ($radios | Where-Object { $_.Checked } | Select-Object -First 1).Tag
    $pin = if ($txtPin.Visible -and $txtPin.Enabled) { $txtPin.Text.Trim() } else { '' }
    $dlg.Dispose()
    if ($result -ne [System.Windows.Forms.DialogResult]::OK) { return $null }

    $label = ($options | Where-Object { $_.Key -eq $key }).Label
    return [PSCustomObject]@{ Key = $key; Label = $label; Pin = $pin }
}

function Start-WipeRun {
    $grid.EndEdit() | Out-Null
    $delay = [int]$numDelay.Value

    $rows = @($script:DeviceTable.Rows | Where-Object { $_['Wipe'] -eq $true -and -not [string]::IsNullOrEmpty([string]$_['IntuneId']) })
    if ($rows.Count -eq 0) { return }

    # Pre-flight: the token must carry the privileged scope, otherwise every call fails
    try { Confirm-FreshToken; Update-TokenInfo }
    catch {
        Show-Message -Text "Sign-in check failed: $($_.Exception.Message)" -Icon Error | Out-Null
        return
    }
    if ($script:State.WipeVerified -ne $true -and $script:State.Scopes -notcontains $PrivilegedScope) {
        if (-not (Test-WipePermission -Row $rows[0])) { return }
    }

    $groupName = $script:State.TargetDescription
    $macCount = @($rows | Where-Object { [string]$_['OS'] -eq 'macOS' }).Count
    $nonWindows = @($rows | Where-Object { [string]$_['OS'] -notlike 'Windows*' }).Count
    $selected = Get-SelectedWipeOption
    $option = Show-WipeOptionsDialog -Count $rows.Count -Target $groupName -FirstDevice ([string]$rows[0]['Device']) -MacCount $macCount -NonWindowsCount $nonWindows `
        -DefaultKey $selected.Key -DefaultPin $txtPinMain.Text.Trim()
    if (-not $option) {
        Write-UiLog 'Wipe cancelled at the wipe options prompt.'
        return
    }
    # Keep the main window's drop-down in step with what was confirmed
    for ($k = 0; $k -lt $WipeOptions.Count; $k++) { if ($WipeOptions[$k].Key -eq $option.Key) { $cmbWipeOption.SelectedIndex = $k } }
    if ($option.Pin) { $txtPinMain.Text = $option.Pin }
    $doneText = if ($option.Key -eq 'Retire') { 'Retire initiated' } else { 'Wipe initiated' }

    $script:State.StopRequested = $false
    Set-Busy $true
    Start-ExportFiles -Label $option.Key
    Write-UiLog "Starting '$($option.Label)' on $($rows.Count) device(s) ($groupName, delay $delay s)"

    $progress.Maximum = $rows.Count
    $progress.Value = 0
    $ok = 0; $failed = 0; $authFailRun = 0; $anyFailRun = 0; $stopReason = ''
    $i = 0

    foreach ($row in $rows) {
        if ($script:State.StopRequested) { $stopReason = 'Stopped by user.'; break }
        $i++
        $name = [string]$row['Device']
        $lblStatus.Text = "Processing $i of $($rows.Count): $name"
        $row['Result'] = 'In progress'
        Invoke-UiPump

        try {
            Confirm-FreshToken
            Invoke-SingleWipe -Row $row -Option $option
            $ok++
            $authFailRun = 0; $anyFailRun = 0
            $row['Result'] = $doneText
            $row['Error'] = ''
            $row['Wipe'] = $false          # untick, so pressing Wipe again resumes with the rest only
            Write-UiLog "$($doneText): $name ($($option.Label))" -Level OK
        }
        catch {
            $failed++
            $anyFailRun++
            $status = 0
            if ($_.Exception.Data -and $_.Exception.Data.Contains('HttpStatus')) { $status = [int]$_.Exception.Data['HttpStatus'] }
            $msg = $_.Exception.Message
            $row['Result'] = 'Failed'
            $row['Error'] = if ($status) { "HTTP $status - $msg" } else { $msg }
            Write-UiLog "Failed: $name - $($row['Error'])" -Level Error

            if ($status -eq 401 -or $status -eq 403) { $authFailRun++ } else { $authFailRun = 0 }
            if ($authFailRun -ge $AuthFailureStopCount) {
                $hint = if ($status -eq 403) { 'Check that your Intune Administrator role (or PIM activation) is still active.' } else { 'Sign-in could not be refreshed.' }
                $stopReason = "$authFailRun devices in a row failed authorisation (HTTP $status). $hint"
                break
            }
            if ($anyFailRun -ge $AnyFailurePauseCount) {
                $answer = Show-Message -Text "$anyFailRun devices in a row have failed. Last error:`r`n$($row['Error'])`r`n`r`nContinue with the remaining devices?" -Icon Warning -Buttons YesNo
                if ($answer -ne 'Yes') { $stopReason = 'Stopped after repeated failures.'; break }
                $anyFailRun = 0
            }
        }
        finally {
            $row['Timestamp'] = (Get-Date).ToString('yyyy-MM-dd HH:mm:ss')
            $progress.Value = [math]::Min($i, $progress.Maximum)
            Save-ExportCsv -WipeOption $option.Label
            Update-AuthLabel
        }

        if ($i -lt $rows.Count -and $delay -gt 0) { Wait-WithEvents -Seconds $delay }
    }

    $remaining = @($rows | Where-Object { $_['Result'] -notin @('Wipe initiated', 'Retire initiated', 'Failed') }).Count
    foreach ($r in $rows) { if ($r['Result'] -eq 'In progress') { $r['Result'] = 'Not processed' } }
    Save-ExportCsv -WipeOption $option.Label

    Write-UiLog "SUMMARY: $ok initiated, $failed failed, $remaining not processed." -Level $(if ($failed -or $remaining) { 'Warn' } else { 'OK' })
    if ($script:State.CsvFile) { Write-UiLog "CSV: $($script:State.CsvFile)" }
    $lblStatus.Text = "Done: $ok initiated, $failed failed, $remaining not processed"

    Set-Busy $false
    if ($script:State.CloseRequested) { return }   # exiting: no pop-ups, the CSV already has every result
    if ($stopReason) {
        Write-UiLog "Run stopped: $stopReason" -Level Error
        Show-Message -Text "$stopReason`r`n`r`n$ok initiated, $failed failed, $remaining not processed.`r`n`r`nFailed and unprocessed devices are still ticked. Fix the cause, then press Wipe again to resume with only those devices." -Icon Warning | Out-Null
    }
    elseif ($failed -gt 0) {
        Show-Message -Text "$ok initiated, $failed failed.`r`n`r`nFailed devices are still ticked. Press Wipe again to retry only those." -Icon Warning | Out-Null
    }
}

# ============================================================================
# FORM
# ============================================================================
$font = New-Object System.Drawing.Font('Segoe UI', 9)
$script:form = New-Object System.Windows.Forms.Form
$form.Text = 'Intune Device Wipe'
$form.Size = New-Object System.Drawing.Size(1280, 860)
$form.MinimumSize = New-Object System.Drawing.Size(1000, 700)
$form.StartPosition = 'CenterScreen'
$form.Font = $font

function New-Ctl {
    param([string]$Type, [int]$X, [int]$Y, [int]$W, [int]$H, [string]$Text = '')
    $c = New-Object "System.Windows.Forms.$Type"
    $c.Location = New-Object System.Drawing.Point($X, $Y)
    $c.Size = New-Object System.Drawing.Size($W, $H)
    if ($Text) { $c.Text = $Text }
    return $c
}

# --- Connection bar ---
$pnlAuth = New-Object System.Windows.Forms.Panel
$pnlAuth.Dock = 'Top'
$pnlAuth.Height = 44
$cmbAuth = New-Ctl ComboBox 10 10 330 24
$cmbAuth.DropDownStyle = 'DropDownList'
[void]$cmbAuth.Items.Add('Browser sign-in (Microsoft login page, auto-renews)')
[void]$cmbAuth.Items.Add('Device code (microsoft.com/devicelogin, auto-renews)')
[void]$cmbAuth.Items.Add('Paste bearer token (e.g. copied from Intune portal)')
[void]$cmbAuth.Items.Add('MgGraphCommunity module (as in V3 script)')
[void]$cmbAuth.Items.Add('Graph SDK Connect-MgGraph')
$cmbAuth.SelectedIndex = 0
$lblTenant = New-Ctl Label 350 13 50 20 'Tenant:'
$txtTenant = New-Ctl TextBox 402 10 190 24 $TenantId
$btnConnect = New-Ctl Button 600 8 95 28 'Connect'
$lblAuth = New-Ctl Label 705 13 465 22 'Not connected'
$lblAuth.ForeColor = [System.Drawing.Color]::FromArgb(192, 0, 0)
$tip = New-Object System.Windows.Forms.ToolTip
$tip.SetToolTip($txtTenant, "'organizations' signs in to your home tenant. Enter a tenant ID or domain to sign in to a specific tenant.")
$btnExit = New-Ctl Button 1178 8 80 28 'Exit'
$lblAuth.AutoEllipsis = $true
$pnlAuth.Controls.AddRange(@($btnExit, $cmbAuth, $lblTenant, $txtTenant, $btnConnect, $lblAuth))
# Anchors on a docked panel are measured from its initial 200 px width, which pushed Exit off-screen; lay out on resize
$pnlAuth.Add_Resize({
        try {
            $btnExit.Left = [math]::Max($pnlAuth.ClientSize.Width - $btnExit.Width - 10, 720)
            $lblAuth.Width = [math]::Max($btnExit.Left - $lblAuth.Left - 10, 100)
        }
        catch { }
    })

# --- Tabs (first function: wipe by group) ---
$split = New-Object System.Windows.Forms.SplitContainer
$split.Dock = 'Fill'
$split.Orientation = 'Horizontal'
$split.SplitterDistance = 560

$tabs = New-Object System.Windows.Forms.TabControl
$tabs.Dock = 'Fill'
$tabGroup = New-Object System.Windows.Forms.TabPage
$tabGroup.Text = 'Wipe by group'
$tabs.TabPages.Add($tabGroup)

$pnlTop = New-Object System.Windows.Forms.Panel
$pnlTop.Dock = 'Top'
$pnlTop.Height = 176

# Row 1: find devices by group or by hostname / serial
$lblSearchBy = New-Ctl Label 8 12 62 20 'Search by:'
$cmbSearchBy = New-Ctl ComboBox 72 9 190 24
$cmbSearchBy.DropDownStyle = 'DropDownList'
[void]$cmbSearchBy.Items.Add('Entra ID group')
[void]$cmbSearchBy.Items.Add('Hostname / serial number')
$cmbSearchBy.SelectedIndex = 0
$txtGroup = New-Ctl TextBox 270 9 300 24
$btnSearch = New-Ctl Button 576 7 100 28 'Search'
$cmbGroups = New-Ctl ComboBox 684 9 300 24
$cmbGroups.DropDownStyle = 'DropDownList'
$chkNested = New-Ctl CheckBox 990 10 70 22 'Nested'
$btnLoad = New-Ctl Button 1065 7 170 28 'Load devices (preview)'
$btnLoad.Enabled = $false
$lblSearchHint = New-Ctl Label 270 36 760 18 'Type the start of a group name (or a group ID), press Search, pick the group, then Load devices.'
$lblSearchHint.ForeColor = [System.Drawing.Color]::FromArgb(96, 96, 96)
$tip.SetToolTip($chkNested, 'Include members of nested groups')

# Row 2: wipe option box
$grpOption = New-Ctl GroupBox 8 58 640 92 'Wipe option'
$cmbWipeOption = New-Ctl ComboBox 10 20 330 24
$cmbWipeOption.DropDownStyle = 'DropDownList'
foreach ($o in $WipeOptions) { [void]$cmbWipeOption.Items.Add($o.Label) }
$cmbWipeOption.SelectedIndex = 0
$lblPinMain = New-Ctl Label 350 23 190 20 'macOS unlock PIN (6 digits):'
$txtPinMain = New-Ctl TextBox 545 20 80 24
$txtPinMain.MaxLength = 6
$tip.SetToolTip($txtPinMain, 'Optional. Only sent to macOS devices.')
$lblOptionDesc = New-Ctl Label 10 50 620 36 $WipeOptions[0].Desc
$lblOptionDesc.ForeColor = [System.Drawing.Color]::FromArgb(96, 96, 96)
$grpOption.Controls.AddRange(@($cmbWipeOption, $lblPinMain, $txtPinMain, $lblOptionDesc))

# Row 2: run settings box
$grpRun = New-Ctl GroupBox 656 58 400 92 'Run settings'
$lblDelay = New-Ctl Label 10 23 145 20 'Delay between wipes (s):'
$numDelay = New-Ctl NumericUpDown 158 20 55 24
$numDelay.Minimum = 0; $numDelay.Maximum = 60; $numDelay.Value = 3
$lblExport = New-Ctl Label 10 57 80 20 'Export folder:'
$txtExport = New-Ctl TextBox 92 54 225 24 $ExportPath
$btnBrowse = New-Ctl Button 322 52 70 28 'Browse'
$grpRun.Controls.AddRange(@($lblDelay, $numDelay, $lblExport, $txtExport, $btnBrowse))

# Row 2: list box
$grpList = New-Ctl GroupBox 1064 58 172 92 'Device list'
$btnAll = New-Ctl Button 8 18 76 26 'Tick all'
$btnNone = New-Ctl Button 88 18 76 26 'Untick all'
$btnClear = New-Ctl Button 8 48 156 26 'Clear list'
$grpList.Controls.AddRange(@($btnAll, $btnNone, $btnClear))
$lblCount = New-Ctl Label 8 154 640 18 ''

$pnlTop.Controls.AddRange(@($lblSearchBy, $cmbSearchBy, $txtGroup, $btnSearch, $cmbGroups, $chkNested, $btnLoad, $lblSearchHint,
        $grpOption, $grpRun, $grpList, $lblCount))

# Grid
$grid = New-Object System.Windows.Forms.DataGridView
$grid.Dock = 'Fill'
$grid.AllowUserToAddRows = $false
$grid.AllowUserToDeleteRows = $false
$grid.RowHeadersVisible = $false
$grid.SelectionMode = 'FullRowSelect'
$grid.AutoSizeColumnsMode = 'DisplayedCells'
$grid.AutoGenerateColumns = $false
$colWipe = New-Object System.Windows.Forms.DataGridViewCheckBoxColumn
$colWipe.Name = 'Wipe'; $colWipe.DataPropertyName = 'Wipe'; $colWipe.HeaderText = 'Wipe'
[void]$grid.Columns.Add($colWipe)
foreach ($def in @(
        @('Device', 'Device'), @('Serial', 'Serial'), @('User', 'Primary user'), @('OS', 'OS'), @('Model', 'Model'),
        @('LastSync', 'Last sync'), @('State', 'Intune state'), @('Source', 'Source'), @('Result', 'Result'), @('Error', 'Error'))) {
    $col = New-Object System.Windows.Forms.DataGridViewTextBoxColumn
    $col.Name = $def[0]; $col.DataPropertyName = $def[0]; $col.HeaderText = $def[1]; $col.ReadOnly = $true
    [void]$grid.Columns.Add($col)
}
$grid.BackgroundColor = [System.Drawing.Color]::White

# Bottom action bar
$pnlBottom = New-Object System.Windows.Forms.Panel
$pnlBottom.Dock = 'Bottom'
$pnlBottom.Height = 44
$btnWipe = New-Ctl Button 8 7 230 30 'Wipe...'
$btnWipe.BackColor = [System.Drawing.Color]::FromArgb(196, 43, 28)
$btnWipe.ForeColor = [System.Drawing.Color]::White
$btnWipe.FlatStyle = 'Flat'
$btnWipe.Enabled = $false
$btnStop = New-Ctl Button 245 7 80 30 'Stop'
$btnStop.Enabled = $false
$btnOpen = New-Ctl Button 332 7 140 30 'Open export folder'
$progress = New-Ctl ProgressBar 480 11 300 22
$lblStatus = New-Ctl Label 790 14 460 20 ''
$lblStatus.AutoEllipsis = $true
$pnlBottom.Add_Resize({ try { $lblStatus.Width = [math]::Max($pnlBottom.ClientSize.Width - $lblStatus.Left - 10, 100) } catch { } })
$pnlBottom.Controls.AddRange(@($btnWipe, $btnStop, $btnOpen, $progress, $lblStatus))

$tabGroup.Controls.Add($grid)
$tabGroup.Controls.Add($pnlTop)
$tabGroup.Controls.Add($pnlBottom)
$grid.BringToFront()

# Log
$script:txtLog = New-Object System.Windows.Forms.RichTextBox
$txtLog.Dock = 'Fill'
$txtLog.ReadOnly = $true
$txtLog.BackColor = [System.Drawing.Color]::FromArgb(250, 250, 250)
$txtLog.Font = New-Object System.Drawing.Font('Consolas', 9)

$split.Panel1.Controls.Add($tabs)
$split.Panel2.Controls.Add($txtLog)
$form.Controls.Add($split)
$form.Controls.Add($pnlAuth)
$split.BringToFront()

# Data table behind the grid
function New-DeviceTable {
    $t = New-Object System.Data.DataTable
    [void]$t.Columns.Add('Wipe', [bool])
    foreach ($col in 'Device', 'Serial', 'User', 'OS', 'Model', 'LastSync', 'State', 'Source', 'Result', 'Error', 'Timestamp', 'IntuneId', 'EntraId') {
        [void]$t.Columns.Add($col, [string])
    }
    # The leading comma stops PowerShell unrolling the table into its rows (an empty table would come back as $null)
    return , $t
}

# ============================================================================
# EVENTS
# ============================================================================
$cmbAuth.Add_SelectedIndexChanged({
        # Pasted tokens already name their tenant; the Community module does not take one
        $txtTenant.Enabled = $cmbAuth.SelectedIndex -in @(0, 1, 4)
    })

$btnConnect.Add_Click({
        $script:State.StopRequested = $false
        Set-Busy $true
        try {
            Connect-WipeGraph
            $btnConnect.Text = 'Reconnect'
        }
        catch {
            $script:State.Connected = $false
            Update-AuthLabel
            Write-UiLog "Connection failed: $($_.Exception.Message)" -Level Error
            if (-not $script:State.CloseRequested) { Show-Message -Text "Connection failed:`r`n$($_.Exception.Message)" -Icon Error | Out-Null }
        }
        finally {
            Set-Busy $false
        }
    })

$btnSearch.Add_Click({
        if (-not $script:State.Connected) { Show-Message -Text 'Connect first.' | Out-Null; return }
        if ([string]::IsNullOrWhiteSpace($txtGroup.Text)) {
            $what = if ($cmbSearchBy.SelectedIndex -eq 0) { 'the start of a group name (or a group ID)' } else { 'one or more hostnames or serial numbers' }
            Show-Message -Text "Type $what." | Out-Null
            return
        }
        $script:State.StopRequested = $false
        Set-Busy $true
        try {
            if ($cmbSearchBy.SelectedIndex -eq 0) {
                # Group search: list matching groups to pick from
                $script:State.Groups = @(Find-EntraGroup -Text $txtGroup.Text)
                $cmbGroups.Items.Clear()
                foreach ($g in $script:State.Groups) {
                    $kind = if ($g.groupTypes -contains 'DynamicMembership') { 'dynamic' } else { 'assigned' }
                    [void]$cmbGroups.Items.Add("$($g.displayName)  [$kind]")
                }
                if ($cmbGroups.Items.Count -gt 0) {
                    $cmbGroups.SelectedIndex = 0
                    Write-UiLog "Found $($cmbGroups.Items.Count) group(s) matching '$($txtGroup.Text.Trim())'" -Level OK
                }
                else {
                    Write-UiLog "No groups start with '$($txtGroup.Text.Trim())'" -Level Warn
                }
            }
            else {
                # Hostname / serial search: add matching devices to the list
                Write-UiLog "Searching Intune for: $($txtGroup.Text.Trim())"
                $targets = Find-WipeDevicesByName -Text $txtGroup.Text
                if (-not $script:DeviceTable) {
                    $script:DeviceTable = New-DeviceTable
                    $grid.DataSource = $script:DeviceTable
                    $script:State.TargetDescription = ''
                }
                $added = Add-DeviceRows -Table $script:DeviceTable -Targets $targets
                if ($added -gt 0) {
                    if (-not $script:State.TargetDescription) { $script:State.TargetDescription = 'Hostname / serial search' }
                    elseif ($script:State.TargetDescription -notlike '*hostname*') { $script:State.TargetDescription += ' + hostname / serial search' }
                    Write-UiLog "Added $added device(s) to the list. Nothing has been wiped." -Level OK
                    $txtGroup.Clear()
                }
                elseif (@($targets).Count -gt 0) {
                    Write-UiLog 'All matching devices are already in the list.' -Level Warn
                }
                $lblStatus.Text = "$($script:DeviceTable.Rows.Count) device(s) in the list"
            }
        }
        catch { Write-UiLog "Search failed: $($_.Exception.Message)" -Level Error }
        finally {
            Set-Busy $false
            $btnLoad.Enabled = $cmbGroups.SelectedIndex -ge 0
        }
    })

$cmbSearchBy.Add_SelectedIndexChanged({
        try {
            $byGroup = ($cmbSearchBy.SelectedIndex -eq 0)
            $cmbGroups.Visible = $byGroup
            $chkNested.Visible = $byGroup
            $btnLoad.Visible = $byGroup
            $btnSearch.Text = if ($byGroup) { 'Search' } else { 'Add devices' }
            $lblSearchHint.Text = if ($byGroup) {
                'Type the start of a group name (or a group ID), press Search, pick the group, then Load devices.'
            }
            else {
                'One or more hostnames or serial numbers, separated by commas or spaces; * is a wildcard (e.g. DD-0392*). Matches are added to the list.'
            }
            $txtGroup.Clear()
            $txtGroup.Focus() | Out-Null
        }
        catch { }
    })

$cmbWipeOption.Add_SelectedIndexChanged({
        try {
            $o = $WipeOptions[$cmbWipeOption.SelectedIndex]
            $lblOptionDesc.Text = $o.Desc
            $isRetire = ($o.Key -eq 'Retire')
            $txtPinMain.Enabled = -not $isRetire
            $lblOptionDesc.ForeColor = if ($o.Key -eq 'ProtectedWipe') { [System.Drawing.Color]::FromArgb(176, 112, 0) } else { [System.Drawing.Color]::FromArgb(96, 96, 96) }
            Update-WipeButton
        }
        catch { }
    })

$btnClear.Add_Click({
        try {
            $script:DeviceTable = $null
            $grid.DataSource = $null
            $script:State.TargetDescription = ''
            $script:State.SelectedGroup = $null
            $lblStatus.Text = ''
            Update-WipeButton
            Write-UiLog 'Device list cleared.'
        }
        catch { }
    })

$txtGroup.Add_KeyDown({
        param($s, $e)
        try { if ($e.KeyCode -eq 'Enter') { $e.SuppressKeyPress = $true; $btnSearch.PerformClick() } } catch { }
    })

$cmbGroups.Add_SelectedIndexChanged({
        if ($script:State.CloseRequested) { return }
        $btnLoad.Enabled = $cmbGroups.SelectedIndex -ge 0
        # A different group invalidates the loaded list
        if ($script:DeviceTable -and $script:State.SelectedGroup -and $cmbGroups.SelectedIndex -ge 0 -and
            $script:State.Groups[$cmbGroups.SelectedIndex].id -ne $script:State.SelectedGroup.id) {
            $script:DeviceTable = $null
            $grid.DataSource = $null
            Update-WipeButton
        }
    })

$btnLoad.Add_Click({
        if ($cmbGroups.SelectedIndex -lt 0) { return }
        $group = $script:State.Groups[$cmbGroups.SelectedIndex]
        $script:State.StopRequested = $false
        Set-Busy $true
        $lblStatus.Text = "Loading devices for $($group.displayName)..."
        try {
            Write-UiLog "Loading devices for group '$($group.displayName)' ($($group.id))"
            $targets = Get-WipeTargetDevices -GroupId $group.id -IncludeNested $chkNested.Checked
            $t = New-DeviceTable
            [void](Add-DeviceRows -Table $t -Targets $targets)
            # Group members with no Intune record: shown greyed out so it is clear why they are not wiped
            foreach ($n in @($script:NotInIntune)) {
                [void]$t.Rows.Add($false, $n.Name, '', '', $n.OS, $n.Model, '', 'Not in Intune', 'Device member',
                    'Not in Intune - cannot wipe', '', (Get-Date).ToString('yyyy-MM-dd HH:mm:ss'), '', $n.EntraDeviceId)
            }
            $script:DeviceTable = $t
            $script:State.SelectedGroup = $group
            $script:State.TargetDescription = "Group: $($group.displayName)"
            $grid.DataSource = $t

            $wipeable = @($targets).Count
            if ($wipeable -eq 0) {
                Write-UiLog "No members of '$($group.displayName)' have an Intune record, so there is nothing to wipe." -Level Warn
                $lblStatus.Text = 'No Intune devices in this group'
                Show-Message -Text "No members of '$($group.displayName)' have an Intune managed device record, so there is nothing to wipe.`r`n`r`nDevices must be enrolled in Intune (not only registered in Entra ID) to be wiped. Members that are not in Intune are listed in grey." -Icon Warning | Out-Null
                return
            }
            Write-UiLog "$wipeable target device(s) loaded. Nothing has been wiped." -Level OK

            # Dry-run export, same as the V3 -DryRun
            Start-ExportFiles -Label 'Preview'
            foreach ($r in $t.Rows) { if ($r['Result'] -eq 'Not processed') { $r['Result'] = 'Dry run - not wiped' } }
            Save-ExportCsv -WipeOption 'Preview - not chosen yet'
            foreach ($r in $t.Rows) { if ($r['Result'] -eq 'Dry run - not wiped') { $r['Result'] = 'Not processed' } }
            if ($script:State.CsvFile) { Write-UiLog "Preview CSV: $($script:State.CsvFile)" }
            $lblStatus.Text = "$wipeable Intune device(s) loaded"
        }
        catch {
            Write-UiLog "Loading devices failed: $($_.Exception.Message)" -Level Error
            $lblStatus.Text = 'Load failed'
        }
        finally { Set-Busy $false }
    })

$grid.Add_CurrentCellDirtyStateChanged({
        if ($grid.IsCurrentCellDirty) { $grid.CommitEdit([System.Windows.Forms.DataGridViewDataErrorContexts]::Commit) | Out-Null }
    })
$grid.Add_CellValueChanged({
        param($s, $e)
        try {
            if ($e.RowIndex -ge 0 -and $grid.Columns[$e.ColumnIndex].Name -eq 'Wipe') {
                $item = $grid.Rows[$e.RowIndex].DataBoundItem
                if ($item -and $item['Wipe'] -eq $true -and [string]::IsNullOrEmpty([string]$item['IntuneId'])) {
                    $item['Wipe'] = $false   # not in Intune: cannot be wiped
                }
            }
            Update-WipeButton
        }
        catch { }
    })

$grid.Add_CellFormatting({
        param($s, $e)
        if ($e.RowIndex -lt 0 -or $script:State.CloseRequested) { return }
        $item = $grid.Rows[$e.RowIndex].DataBoundItem
        if (-not $item) { return }
        $result = [string]$item['Result']
        $color = switch -Wildcard ($result) {
            '* initiated'    { [System.Drawing.Color]::FromArgb(226, 244, 226) }
            'Failed'         { [System.Drawing.Color]::FromArgb(250, 222, 222) }
            'In progress'    { [System.Drawing.Color]::FromArgb(255, 245, 204) }
            'Already pending*' { [System.Drawing.Color]::FromArgb(235, 235, 235) }
            'Not in Intune*' { [System.Drawing.Color]::FromArgb(225, 225, 225) }
            default          { [System.Drawing.Color]::White }
        }
        $e.CellStyle.BackColor = $color
    })

$btnAll.Add_Click({
        try { if ($script:DeviceTable) { foreach ($r in $script:DeviceTable.Rows) { if ($r['Result'] -notlike '* initiated' -and $r['IntuneId']) { $r['Wipe'] = $true } }; Update-WipeButton } }
        catch { Write-UiLog "Tick all failed: $($_.Exception.Message)" -Level Error }
    })
$btnNone.Add_Click({
        try { if ($script:DeviceTable) { foreach ($r in $script:DeviceTable.Rows) { $r['Wipe'] = $false }; Update-WipeButton } }
        catch { Write-UiLog "Untick all failed: $($_.Exception.Message)" -Level Error }
    })

$btnBrowse.Add_Click({
        try {
            $dlg = New-Object System.Windows.Forms.FolderBrowserDialog
            $dlg.SelectedPath = $txtExport.Text
            if ($dlg.ShowDialog($form) -eq 'OK') { $txtExport.Text = $dlg.SelectedPath }
            $dlg.Dispose()
        }
        catch { Write-UiLog "Folder picker failed: $($_.Exception.Message)" -Level Error }
    })

$btnOpen.Add_Click({
        try {
            $folder = $txtExport.Text.Trim()
            if (Test-Path $folder) { Start-Process explorer.exe $folder } else { Show-Message -Text "Folder does not exist yet: $folder" | Out-Null }
        }
        catch { Write-UiLog "Could not open folder: $($_.Exception.Message)" -Level Error }
    })

$btnWipe.Add_Click({
        try { Start-WipeRun }
        catch {
            Write-UiLog "Wipe run error: $($_.Exception.Message)" -Level Error
            try { Set-Busy $false } catch { }
        }
    })

$btnStop.Add_Click({
        $script:State.StopRequested = $true
        Write-UiLog 'Stop requested. Finishing the current step...' -Level Warn
    })

$btnExit.Add_Click({
        try { Request-AppExit }
        catch { try { $form.Close() } catch { } }
    })

# Refreshes the token countdown in the connection bar
$timer = New-Object System.Windows.Forms.Timer
$timer.Interval = 15000
$timer.Add_Tick({
        try { if ($script:State.Connected -and -not $script:State.Busy -and -not $script:State.CloseRequested) { Update-AuthLabel } } catch { }
    })
$timer.Start()

# Closes the window once a stopped run / sign-in has fully unwound (started by Request-AppExit)
$closeTimer = New-Object System.Windows.Forms.Timer
$closeTimer.Interval = 300
$closeTimer.Add_Tick({
        try {
            if (-not $script:State.Busy) {
                $closeTimer.Stop()
                $form.Close()
            }
        }
        catch { }
    })

$form.Add_FormClosing({
        param($s, $e)
        try {
            if ($script:State.Busy) {
                # Never close while a handler is still running: stop it and close once it has unwound
                $e.Cancel = $true
                Request-AppExit
                return
            }
            $script:State.CloseRequested = $true
            $timer.Stop()
            $closeTimer.Stop()
            if (Get-Command Get-MgContext -ErrorAction SilentlyContinue) {
                if (Get-MgContext) { Disconnect-MgGraph -ErrorAction SilentlyContinue | Out-Null }
            }
            $script:State.AccessToken = $null
            $script:State.RefreshToken = $null
        }
        catch { }
    })

Write-UiLog 'Ready. 1) Connect  2) Search and pick a group  3) Load devices (preview)  4) Review ticks  5) Wipe.  Use Exit to close.'
try {
    [void]$form.ShowDialog()
}
finally {
    try { $timer.Stop(); $timer.Dispose() } catch { }
    try { $closeTimer.Stop(); $closeTimer.Dispose() } catch { }
    try { $form.Dispose() } catch { }
    if ($null -ne $script:RestoreCtrlC) { try { [Console]::TreatControlCAsInput = $script:RestoreCtrlC } catch { } }
}