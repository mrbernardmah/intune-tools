<#
.SYNOPSIS
    Autopilot Group Tag Manager - a WPF GUI to view and bulk-update Windows Autopilot
    group tags across tenants via Microsoft Graph.

.DESCRIPTION
    Sign-in options:
      * Interactive login (Microsoft Graph PowerShell SDK, Connect-MgGraph) to any tenant ID / domain
      * Paste a Bearer access token (e.g. copied from the Intune portal's network traffic or another tool)

    Workflow: Connect -> Load devices -> check rows (or import CSV) -> Stage new tag -> review -> Apply.
    Every change is written to a daily audit log under %APPDATA%\AutopilotGroupTagTool\logs.

    Required Graph permission: DeviceManagementServiceConfig.ReadWrite.All
    (DeviceManagementServiceConfig.Read.All is enough to only browse).

.NOTES
    Works on Windows PowerShell 5.1 and PowerShell 7+ (Windows only - WPF).
#>

[CmdletBinding()]
param()

# --- WPF needs an STA thread ----------------------------------------------------------
if ([System.Threading.Thread]::CurrentThread.GetApartmentState() -ne 'STA') {
    $exe = (Get-Process -Id $PID).Path
    Start-Process -FilePath $exe -ArgumentList @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-STA', '-File', "`"$PSCommandPath`"")
    return
}

Add-Type -AssemblyName PresentationFramework, PresentationCore, WindowsBase, System.Xaml

# --- Row model (two-way binding friendly) ---------------------------------------------
if (-not ([System.Management.Automation.PSTypeName]'AutopilotTagRow').Type) {
    Add-Type -Language CSharp -TypeDefinition @'
using System.ComponentModel;
public class AutopilotTagRow : INotifyPropertyChanged {
    public event PropertyChangedEventHandler PropertyChanged;
    private void N(string p) { PropertyChangedEventHandler h = PropertyChanged; if (h != null) h(this, new PropertyChangedEventArgs(p)); }

    private bool _selected;   public bool   Selected  { get { return _selected; }  set { _selected = value;  N("Selected"); } }
    private string _groupTag; public string GroupTag  { get { return _groupTag; }  set { _groupTag = value;  N("GroupTag"); } }
    private string _newTag;   public string NewTag    { get { return _newTag; }    set { _newTag = value;    N("NewTag"); N("NewTagDisplay"); } }
    private bool _pending;    public bool   Pending   { get { return _pending; }   set { _pending = value;   N("Pending"); N("NewTagDisplay"); } }
    private string _status;   public string Status    { get { return _status; }    set { _status = value;    N("Status"); } }

    public string NewTagDisplay { get { if (!_pending) return ""; return string.IsNullOrEmpty(_newTag) ? "(clear)" : _newTag; } }

    public string Id              { get; set; }
    public string SerialNumber    { get; set; }
    public string Model           { get; set; }
    public string Manufacturer    { get; set; }
    public string DisplayName     { get; set; }
    public string UserPrincipal   { get; set; }
    public string EnrollmentState { get; set; }
    public string LastContacted   { get; set; }
    public string AzureAdDeviceId { get; set; }
}
'@
}

# --- Paths / state --------------------------------------------------------------------
$script:AppDir     = Join-Path $env:APPDATA 'AutopilotGroupTagTool'
$script:LogDir     = Join-Path $script:AppDir 'logs'
$script:TenantFile = Join-Path $script:AppDir 'tenants.json'
New-Item -ItemType Directory -Force -Path $script:LogDir | Out-Null

$script:GraphBase    = 'https://graph.microsoft.com/beta'
$script:RequiredPerm = 'DeviceManagementServiceConfig.ReadWrite.All'
$script:Auth         = $null      # @{ Mode; Token; TenantId; Identity; Expires; TenantName }
$script:LoadedTenant = $null
$script:Rows         = New-Object 'System.Collections.ObjectModel.ObservableCollection[AutopilotTagRow]'
$script:View         = [System.Windows.Data.CollectionViewSource]::GetDefaultView($script:Rows)

# --- XAML -----------------------------------------------------------------------------
[xml]$xaml = @'
<Window xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation"
        xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml"
        Title="Autopilot Group Tag Manager" Height="820" Width="1320" MinHeight="600" MinWidth="1000"
        WindowStartupLocation="CenterScreen" FontFamily="Segoe UI" FontSize="12" Background="#F5F6F8">
  <Window.Resources>
    <Style TargetType="Button">
      <Setter Property="Padding" Value="10,4"/>
      <Setter Property="Margin" Value="0,0,6,0"/>
      <Setter Property="MinWidth" Value="80"/>
    </Style>
    <Style TargetType="GroupBox">
      <Setter Property="Margin" Value="0,0,0,8"/>
      <Setter Property="Padding" Value="8"/>
      <Setter Property="Background" Value="White"/>
    </Style>
  </Window.Resources>
  <Grid Margin="10">
    <Grid.RowDefinitions>
      <RowDefinition Height="Auto"/>
      <RowDefinition Height="Auto"/>
      <RowDefinition Height="*"/>
      <RowDefinition Height="Auto"/>
      <RowDefinition Height="150"/>
    </Grid.RowDefinitions>

    <!-- Connection -->
    <GroupBox Grid.Row="0" Header="Tenant connection">
      <Grid>
        <Grid.ColumnDefinitions>
          <ColumnDefinition Width="110"/>
          <ColumnDefinition Width="260"/>
          <ColumnDefinition Width="130"/>
          <ColumnDefinition Width="300"/>
          <ColumnDefinition Width="*"/>
        </Grid.ColumnDefinitions>
        <Grid.RowDefinitions>
          <RowDefinition Height="Auto"/>
          <RowDefinition Height="Auto"/>
          <RowDefinition Height="Auto"/>
          <RowDefinition Height="Auto"/>
        </Grid.RowDefinitions>

        <TextBlock Grid.Row="0" Grid.Column="0" Text="Saved tenant" VerticalAlignment="Center"/>
        <ComboBox  Grid.Row="0" Grid.Column="1" x:Name="cmbTenants" DisplayMemberPath="Name" Margin="0,2,10,2"/>
        <TextBlock Grid.Row="0" Grid.Column="2" Text="Tenant ID or domain" VerticalAlignment="Center"/>
        <TextBox   Grid.Row="0" Grid.Column="3" x:Name="txtTenantId" Margin="0,2,10,2" VerticalContentAlignment="Center"
                   ToolTip="e.g. contoso.onmicrosoft.com or the tenant GUID. Leave blank to use your home tenant."/>
        <StackPanel Grid.Row="0" Grid.Column="4" Orientation="Horizontal">
          <Button x:Name="btnSaveTenant" Content="Save tenant..."/>
          <Button x:Name="btnRemoveTenant" Content="Remove"/>
        </StackPanel>

        <TextBlock Grid.Row="1" Grid.Column="0" Text="Sign-in method" VerticalAlignment="Center" Margin="0,6,0,0"/>
        <StackPanel Grid.Row="1" Grid.Column="1" Grid.ColumnSpan="4" Orientation="Horizontal" Margin="0,6,0,0">
          <RadioButton x:Name="rbInteractive" Content="Interactive login (Microsoft / Intune admin account)" IsChecked="True" Margin="0,0,20,0" VerticalAlignment="Center"/>
          <CheckBox    x:Name="chkDeviceCode" Content="use device code" Margin="0,0,30,0" VerticalAlignment="Center"
                       ToolTip="Shows a code in the PowerShell console to enter at microsoft.com/devicelogin"/>
          <RadioButton x:Name="rbToken" Content="Bearer token" VerticalAlignment="Center"/>
        </StackPanel>

        <TextBlock Grid.Row="2" Grid.Column="0" Text="Bearer token" VerticalAlignment="Top" Margin="0,8,0,0"/>
        <TextBox   Grid.Row="2" Grid.Column="1" Grid.ColumnSpan="3" x:Name="txtToken" Height="46" Margin="0,6,10,0"
                   TextWrapping="Wrap" AcceptsReturn="False" VerticalScrollBarVisibility="Auto" FontFamily="Consolas" FontSize="11"
                   IsEnabled="False" ToolTip="Paste a Microsoft Graph access token (with or without the 'Bearer ' prefix)"/>
        <StackPanel Grid.Row="2" Grid.Column="4" Orientation="Horizontal" VerticalAlignment="Top" Margin="0,6,0,0">
          <Button x:Name="btnConnect" Content="Connect" FontWeight="SemiBold"/>
          <Button x:Name="btnDisconnect" Content="Disconnect" IsEnabled="False"/>
        </StackPanel>

        <Border Grid.Row="3" Grid.Column="0" Grid.ColumnSpan="5" Margin="0,8,0,0" Padding="8,5" CornerRadius="3" x:Name="bdStatus" Background="#EEF0F3">
          <TextBlock x:Name="txtConnStatus" Text="Not connected" TextWrapping="Wrap"/>
        </Border>
      </Grid>
    </GroupBox>

    <!-- Filters -->
    <StackPanel Grid.Row="1" Orientation="Horizontal" Margin="0,0,0,6">
      <Button x:Name="btnLoad" Content="Load devices" FontWeight="SemiBold" IsEnabled="False"/>
      <TextBlock Text="Search" VerticalAlignment="Center" Margin="10,0,6,0"/>
      <TextBox x:Name="txtSearch" Width="220" VerticalContentAlignment="Center" ToolTip="Serial, model, display name, user or tag"/>
      <TextBlock Text="Group tag" VerticalAlignment="Center" Margin="14,0,6,0"/>
      <ComboBox x:Name="cmbTagFilter" Width="200"/>
      <CheckBox x:Name="chkOnlyStaged" Content="Only staged changes" VerticalAlignment="Center" Margin="14,0,14,0"/>
      <Button x:Name="btnCheckVisible" Content="Check all visible"/>
      <Button x:Name="btnUncheckAll" Content="Uncheck all"/>
      <TextBlock x:Name="txtCount" VerticalAlignment="Center" Margin="10,0,0,0" Foreground="#555"/>
    </StackPanel>

    <!-- Grid -->
    <DataGrid Grid.Row="2" x:Name="dgDevices" AutoGenerateColumns="False" CanUserAddRows="False" CanUserDeleteRows="False"
              SelectionMode="Extended" SelectionUnit="FullRow" HeadersVisibility="Column" GridLinesVisibility="Horizontal"
              HorizontalGridLinesBrush="#E3E5E8" AlternatingRowBackground="#FAFBFC" Background="White" RowHeight="24"
              EnableRowVirtualization="True">
      <DataGrid.RowStyle>
        <Style TargetType="DataGridRow">
          <Style.Triggers>
            <DataTrigger Binding="{Binding Pending}" Value="True">
              <Setter Property="Background" Value="#FFF6D5"/>
            </DataTrigger>
            <DataTrigger Binding="{Binding Status}" Value="Failed">
              <Setter Property="Background" Value="#FDE2E1"/>
            </DataTrigger>
            <DataTrigger Binding="{Binding Status}" Value="Updated">
              <Setter Property="Background" Value="#E3F4E5"/>
            </DataTrigger>
          </Style.Triggers>
        </Style>
      </DataGrid.RowStyle>
      <DataGrid.Columns>
        <DataGridTemplateColumn Header="" Width="34" CanUserSort="False">
          <DataGridTemplateColumn.CellTemplate>
            <DataTemplate>
              <CheckBox HorizontalAlignment="Center" VerticalAlignment="Center"
                        IsChecked="{Binding Selected, Mode=TwoWay, UpdateSourceTrigger=PropertyChanged}"/>
            </DataTemplate>
          </DataGridTemplateColumn.CellTemplate>
        </DataGridTemplateColumn>
        <DataGridTextColumn Header="Serial number"    Binding="{Binding SerialNumber}"    IsReadOnly="True" Width="150"/>
        <DataGridTextColumn Header="Current group tag" Binding="{Binding GroupTag}"       IsReadOnly="True" Width="160"/>
        <DataGridTextColumn Header="New group tag"    Binding="{Binding NewTagDisplay}"   IsReadOnly="True" Width="160" FontWeight="SemiBold"/>
        <DataGridTextColumn Header="Model"            Binding="{Binding Model}"           IsReadOnly="True" Width="170"/>
        <DataGridTextColumn Header="Manufacturer"     Binding="{Binding Manufacturer}"    IsReadOnly="True" Width="120"/>
        <DataGridTextColumn Header="Display name"     Binding="{Binding DisplayName}"     IsReadOnly="True" Width="140"/>
        <DataGridTextColumn Header="Assigned user"    Binding="{Binding UserPrincipal}"   IsReadOnly="True" Width="170"/>
        <DataGridTextColumn Header="Enrollment"       Binding="{Binding EnrollmentState}" IsReadOnly="True" Width="95"/>
        <DataGridTextColumn Header="Last contacted"   Binding="{Binding LastContacted}"   IsReadOnly="True" Width="125"/>
        <DataGridTextColumn Header="Status"           Binding="{Binding Status}"          IsReadOnly="True" Width="*"/>
      </DataGrid.Columns>
    </DataGrid>

    <!-- Actions -->
    <GroupBox Grid.Row="3" Header="Change group tag" Margin="0,8,0,8">
      <StackPanel>
        <StackPanel Orientation="Horizontal">
          <TextBlock Text="New group tag" VerticalAlignment="Center" Margin="0,0,6,0"/>
          <TextBox x:Name="txtNewTag" Width="220" VerticalContentAlignment="Center" Margin="0,0,8,0"/>
          <Button x:Name="btnStage" Content="Stage for checked rows"/>
          <Button x:Name="btnStageClear" Content="Stage clear tag"/>
          <Button x:Name="btnImportSerials" Content="Import serials..." ToolTip="Upload a CSV/TXT of serial numbers - every device in it gets the tag typed in 'New group tag'"/>
          <Button x:Name="btnImportCsv" Content="Import CSV (serial + tag)..." ToolTip="CSV with SerialNumber and GroupTag columns - each device gets its own tag"/>
          <Button x:Name="btnUnstage" Content="Discard staged"/>
          <Separator Width="14" Visibility="Hidden"/>
          <CheckBox x:Name="chkDryRun" Content="Dry run (no writes)" VerticalAlignment="Center" Margin="0,0,10,0"/>
          <Button x:Name="btnApply" Content="Apply staged changes" FontWeight="Bold" Background="#2B6CB0" Foreground="White" BorderBrush="#2B6CB0"/>
        </StackPanel>
        <StackPanel Orientation="Horizontal" Margin="0,8,0,0">
          <Button x:Name="btnSync" Content="Sync Autopilot service"/>
          <Button x:Name="btnExport" Content="Export view to CSV..."/>
          <Button x:Name="btnTemplate" Content="Save CSV template..."/>
          <TextBlock VerticalAlignment="Center" Foreground="#666" Margin="8,0,0,0"
                     Text="Tip: no rows checked = staging uses highlighted rows. Import serials: one serial per line or a SerialNumber column."/>
        </StackPanel>
      </StackPanel>
    </GroupBox>

    <!-- Log -->
    <TextBox Grid.Row="4" x:Name="txtLog" IsReadOnly="True" FontFamily="Consolas" FontSize="11"
             VerticalScrollBarVisibility="Auto" HorizontalScrollBarVisibility="Auto" TextWrapping="NoWrap" Background="#1E1E1E" Foreground="#DADADA"/>
  </Grid>
</Window>
'@

$window = [Windows.Markup.XamlReader]::Load((New-Object System.Xml.XmlNodeReader $xaml))
$ui = @{}
$xaml.SelectNodes('//*[@*[local-name()="Name"]]') | ForEach-Object {
    $n = $_.Attributes | Where-Object { $_.LocalName -eq 'Name' } | Select-Object -First 1
    if ($n) { $ui[$n.Value] = $window.FindName($n.Value) }
}

# --- Helpers --------------------------------------------------------------------------
function Update-UI {
    $window.Dispatcher.Invoke([action] {}, [System.Windows.Threading.DispatcherPriority]::Background)
}

function Wait-UI([double]$Seconds) {
    $until = (Get-Date).AddSeconds($Seconds)
    while ((Get-Date) -lt $until) { Start-Sleep -Milliseconds 100; Update-UI }
}

function Write-Log {
    param([string]$Message, [ValidateSet('INFO', 'WARN', 'ERROR', 'CHANGE')][string]$Level = 'INFO')
    $line = '{0:yyyy-MM-dd HH:mm:ss} [{1}] {2}' -f (Get-Date), $Level, $Message
    $ui.txtLog.AppendText($line + [Environment]::NewLine)
    $ui.txtLog.ScrollToEnd()
    try { Add-Content -Path (Join-Path $script:LogDir ('{0:yyyyMMdd}.log' -f (Get-Date))) -Value $line -Encoding UTF8 } catch { }
    Update-UI
}

function Show-Message([string]$Text, [string]$Icon = 'Information', [string]$Buttons = 'OK') {
    [System.Windows.MessageBox]::Show($window, $Text, 'Autopilot Group Tag Manager',
        [System.Windows.MessageBoxButton]$Buttons, [System.Windows.MessageBoxImage]$Icon)
}

$script:BusyButtons = @('btnConnect', 'btnDisconnect', 'btnLoad', 'btnStage', 'btnStageClear', 'btnImportCsv', 'btnImportSerials',
    'btnUnstage', 'btnApply', 'btnSync', 'btnExport')
function Set-Busy([bool]$Busy) {
    foreach ($b in $script:BusyButtons) { if ($Busy) { $ui[$b].IsEnabled = $false } }
    if (-not $Busy) { Update-ButtonState }
    $window.Cursor = if ($Busy) { [System.Windows.Input.Cursors]::Wait } else { $null }
    Update-UI
}

function Update-ButtonState {
    $connected = $null -ne $script:Auth
    $hasRows = $script:Rows.Count -gt 0
    $ui.btnConnect.IsEnabled = $true
    $ui.btnDisconnect.IsEnabled = $connected
    $ui.btnLoad.IsEnabled = $connected
    $ui.btnSync.IsEnabled = $connected
    foreach ($b in 'btnStage', 'btnStageClear', 'btnUnstage', 'btnApply', 'btnExport') { $ui[$b].IsEnabled = $hasRows }
    $ui.btnImportCsv.IsEnabled = $connected
    $ui.btnImportSerials.IsEnabled = $connected
    $ui.txtToken.IsEnabled = [bool]$ui.rbToken.IsChecked
    $ui.chkDeviceCode.IsEnabled = [bool]$ui.rbInteractive.IsChecked
}

function Set-ConnStatus([string]$Text, [string]$State) {
    $ui.txtConnStatus.Text = $Text
    $color = switch ($State) { 'ok' { '#E3F4E5' } 'warn' { '#FFF6D5' } 'error' { '#FDE2E1' } default { '#EEF0F3' } }
    $ui.bdStatus.Background = (New-Object System.Windows.Media.BrushConverter).ConvertFromString($color)
}

# --- Tenant list ----------------------------------------------------------------------
function Get-SavedTenants {
    if (Test-Path $script:TenantFile) {
        try { return @(Get-Content $script:TenantFile -Raw | ConvertFrom-Json) } catch { Write-Log "Could not read tenants.json: $_" 'WARN' }
    }
    return @()
}
function Save-Tenants($list) {
    ConvertTo-Json -InputObject @($list) -Depth 3 | Set-Content -Path $script:TenantFile -Encoding UTF8
}
function Refresh-TenantCombo([string]$SelectId) {
    $list = Get-SavedTenants | Sort-Object Name
    $ui.cmbTenants.ItemsSource = $null
    $ui.cmbTenants.ItemsSource = @($list)
    if ($SelectId) {
        $match = $list | Where-Object { $_.TenantId -eq $SelectId } | Select-Object -First 1
        if ($match) { $ui.cmbTenants.SelectedItem = $match }
    }
}

# --- Token handling -------------------------------------------------------------------
function ConvertFrom-Jwt([string]$Token) {
    $parts = $Token.Split('.')
    if ($parts.Count -lt 3) { throw 'That does not look like a JWT access token (expected three dot-separated parts).' }
    $p = $parts[1].Replace('-', '+').Replace('_', '/')
    switch ($p.Length % 4) { 2 { $p += '==' } 3 { $p += '=' } }
    [Text.Encoding]::UTF8.GetString([Convert]::FromBase64String($p)) | ConvertFrom-Json
}

function Assert-TokenValid {
    if ($script:Auth.Mode -eq 'Token' -and $script:Auth.Expires -and (Get-Date) -ge $script:Auth.Expires) {
        throw "The bearer token expired at $($script:Auth.Expires). Paste a fresh token and click Connect."
    }
}

# --- Graph ----------------------------------------------------------------------------
function Get-HttpStatus($ErrRecord) {
    try {
        $r = $ErrRecord.Exception.Response
        if ($r -and $r.StatusCode) { return [int]$r.StatusCode }
    } catch { }
    $msg = "$($ErrRecord.Exception.Message)"
    if ($msg -match 'TooManyRequests|\b429\b') { return 429 }
    if ($msg -match 'ServiceUnavailable|\b503\b') { return 503 }
    if ($msg -match 'GatewayTimeout|\b504\b') { return 504 }
    return 0
}

function Get-RetryAfter($ErrRecord) {
    try {
        $h = $ErrRecord.Exception.Response.Headers
        if ($h -is [System.Net.WebHeaderCollection]) { $v = $h['Retry-After']; if ($v) { return [int]$v } }
        elseif ($h -and $h.RetryAfter -and $h.RetryAfter.Delta) { return [int]$h.RetryAfter.Delta.TotalSeconds }
    } catch { }
    return 0
}

function Get-GraphErrorText($ErrRecord) {
    $raw = $ErrRecord.ErrorDetails.Message
    if (-not $raw) { $raw = $ErrRecord.Exception.Message }
    try {
        $j = $raw | ConvertFrom-Json -ErrorAction Stop
        if ($j.error.message) { return "$($j.error.code): $($j.error.message)" }
    } catch { }
    return $raw
}

function Invoke-Graph {
    param([string]$Method = 'GET', [Parameter(Mandatory)][string]$Uri, $Body)
    if (-not $script:Auth) { throw 'Not connected.' }
    $json = if ($null -ne $Body) { $Body | ConvertTo-Json -Depth 10 -Compress } else { $null }

    $maxAttempts = 6
    for ($attempt = 1; $attempt -le $maxAttempts; $attempt++) {
        try {
            if ($script:Auth.Mode -eq 'Token') {
                Assert-TokenValid
                $p = @{
                    Method      = $Method
                    Uri         = $Uri
                    Headers     = @{ Authorization = "Bearer $($script:Auth.Token)"; 'ConsistencyLevel' = 'eventual' }
                    ContentType = 'application/json'
                    ErrorAction = 'Stop'
                }
                if ($json) { $p.Body = [Text.Encoding]::UTF8.GetBytes($json) }
                return Invoke-RestMethod @p
            }
            else {
                $p = @{ Method = $Method; Uri = $Uri; OutputType = 'PSObject'; ErrorAction = 'Stop' }
                if ($json) { $p.Body = $json; $p.ContentType = 'application/json' }
                return Invoke-MgGraphRequest @p
            }
        }
        catch {
            $code = Get-HttpStatus $_
            if (($code -eq 429 -or $code -ge 500) -and $attempt -lt $maxAttempts) {
                $wait = Get-RetryAfter $_
                if ($wait -le 0) { $wait = [math]::Min(60, [math]::Pow(2, $attempt)) }
                Write-Log "Graph returned HTTP $code - retrying in $wait s (attempt $attempt/$maxAttempts)" 'WARN'
                Wait-UI $wait
                continue
            }
            throw (Get-GraphErrorText $_)
        }
    }
}

function Get-GraphPaged([string]$Uri) {
    $all = New-Object System.Collections.Generic.List[object]
    $next = $Uri
    while ($next) {
        $resp = Invoke-Graph -Uri $next
        if ($resp.value) { foreach ($v in $resp.value) { $all.Add($v) } }
        $next = $resp.'@odata.nextLink'
        $ui.txtCount.Text = "Loading... $($all.Count) devices"
        Update-UI
    }
    return $all
}

# --- Connect / disconnect -------------------------------------------------------------
function Connect-Tenant {
    $tenantInput = $ui.txtTenantId.Text.Trim()

    if ($ui.rbToken.IsChecked) {
        $tok = ($ui.txtToken.Text -replace '^\s*(?i)bearer\s+', '') -replace '\s', ''
        if (-not $tok) { throw 'Paste a bearer token first.' }
        $claims = ConvertFrom-Jwt $tok

        $validAud = @('https://graph.microsoft.com', 'https://graph.microsoft.com/', '00000003-0000-0000-c000-000000000000', 'https://canary.graph.microsoft.com')
        if ($validAud -notcontains $claims.aud) {
            throw "This token is for '$($claims.aud)', not Microsoft Graph. Copy a token whose audience is https://graph.microsoft.com."
        }
        $expires = [DateTimeOffset]::FromUnixTimeSeconds([int64]$claims.exp).LocalDateTime
        if ((Get-Date) -ge $expires) { throw "This token already expired at $expires." }

        $perms = @()
        if ($claims.scp) { $perms += ($claims.scp -split ' ') }
        if ($claims.roles) { $perms += $claims.roles }
        $identity = @($claims.upn, $claims.unique_name, $claims.preferred_username, $claims.app_displayname) | Where-Object { $_ } | Select-Object -First 1

        if ($tenantInput -and $tenantInput -match '^[0-9a-fA-F-]{36}$' -and $tenantInput -ne $claims.tid) {
            $r = Show-Message "The token belongs to tenant $($claims.tid), but the Tenant ID box says $tenantInput.`n`nContinue with the token's tenant?" 'Warning' 'YesNo'
            if ("$r" -ne 'Yes') { return }
        }

        $script:Auth = @{ Mode = 'Token'; Token = $tok; TenantId = $claims.tid; Identity = $identity; Expires = $expires; Perms = $perms }
        $ui.txtTenantId.Text = $claims.tid
    }
    else {
        if (-not (Get-Module -ListAvailable -Name Microsoft.Graph.Authentication)) {
            $r = Show-Message "Interactive login needs the Microsoft.Graph.Authentication PowerShell module, which isn't installed.`n`nInstall it now for the current user?" 'Question' 'YesNo'
            if ("$r" -ne 'Yes') { return }
            Write-Log 'Installing Microsoft.Graph.Authentication (CurrentUser)...'
            Install-Module Microsoft.Graph.Authentication -Scope CurrentUser -Force -AllowClobber -ErrorAction Stop
        }
        Import-Module Microsoft.Graph.Authentication -ErrorAction Stop
        try { Disconnect-MgGraph -ErrorAction SilentlyContinue | Out-Null } catch { }

        $p = @{ Scopes = @($script:RequiredPerm); ErrorAction = 'Stop' }
        if ($tenantInput) { $p.TenantId = $tenantInput }
        if ($ui.chkDeviceCode.IsChecked) { $p.UseDeviceCode = $true; Write-Log 'Device code sign-in: check the PowerShell console window for the code.' 'WARN' }
        if ((Get-Command Connect-MgGraph).Parameters.ContainsKey('NoWelcome')) { $p.NoWelcome = $true }

        Write-Log "Signing in$(if ($tenantInput) { " to $tenantInput" })..."
        Connect-MgGraph @p | Out-Null
        $ctx = Get-MgContext
        if (-not $ctx) { throw 'Sign-in did not complete.' }

        $script:Auth = @{ Mode = 'Interactive'; TenantId = $ctx.TenantId; Identity = $ctx.Account; Expires = $null; Perms = @($ctx.Scopes) }
        $ui.txtTenantId.Text = $ctx.TenantId
    }

    # Best-effort tenant display name
    $script:Auth.TenantName = $null
    try {
        $org = Invoke-Graph -Uri 'https://graph.microsoft.com/v1.0/organization?$select=displayName,id'
        if ($org.value) { $script:Auth.TenantName = $org.value[0].displayName }
    } catch { }

    # Any devices loaded for a previous tenant must not be acted on
    $script:Rows.Clear(); $script:LoadedTenant = $null; Update-Count

    $hasWrite = ($script:Auth.Perms -contains $script:RequiredPerm)
    $hasRead = $hasWrite -or ($script:Auth.Perms -contains 'DeviceManagementServiceConfig.Read.All')
    $name = if ($script:Auth.TenantName) { "$($script:Auth.TenantName) ($($script:Auth.TenantId))" } else { $script:Auth.TenantId }
    $text = "Connected to $name as $($script:Auth.Identity) via $($script:Auth.Mode.ToLower())"
    if ($script:Auth.Expires) { $text += " - token expires $($script:Auth.Expires.ToString('HH:mm:ss'))" }

    if (-not $hasRead) {
        Set-ConnStatus "$text. WARNING: token lacks DeviceManagementServiceConfig permissions - loading will probably fail." 'warn'
    }
    elseif (-not $hasWrite) {
        Set-ConnStatus "$text. Read-only: token lacks $($script:RequiredPerm), so tag updates will fail." 'warn'
    }
    else { Set-ConnStatus $text 'ok' }

    Write-Log "Connected: tenant=$name identity=$($script:Auth.Identity) mode=$($script:Auth.Mode)"
    Refresh-TenantCombo $script:Auth.TenantId
}

function Disconnect-Tenant {
    if ($script:Auth -and $script:Auth.Mode -eq 'Interactive') { try { Disconnect-MgGraph -ErrorAction SilentlyContinue | Out-Null } catch { } }
    $script:Auth = $null
    $script:Rows.Clear(); $script:LoadedTenant = $null
    Set-ConnStatus 'Not connected' 'none'
    Update-Count
    Write-Log 'Disconnected.'
}

# --- Devices --------------------------------------------------------------------------
function Load-Devices {
    $items = Get-GraphPaged "$($script:GraphBase)/deviceManagement/windowsAutopilotDeviceIdentities"
    $script:Rows.Clear()
    foreach ($d in ($items | Sort-Object serialNumber)) {
        $row = New-Object AutopilotTagRow
        $row.Id = $d.id
        $row.SerialNumber = $d.serialNumber
        $row.GroupTag = $d.groupTag
        $row.Model = $d.model
        $row.Manufacturer = $d.manufacturer
        $row.DisplayName = $d.displayName
        $row.UserPrincipal = $d.userPrincipalName
        $row.EnrollmentState = $d.enrollmentState
        $row.AzureAdDeviceId = $d.azureActiveDirectoryDeviceId
        $lc = $d.lastContactedDateTime
        if ($lc) {
            try { $dt = [datetime]$lc; if ($dt.Year -gt 1) { $row.LastContacted = $dt.ToLocalTime().ToString('yyyy-MM-dd HH:mm') } } catch { }
        }
        $script:Rows.Add($row)
    }
    $script:LoadedTenant = $script:Auth.TenantId
    Refresh-TagFilter
    Update-Count
    Write-Log "Loaded $($script:Rows.Count) Autopilot devices from tenant $($script:Auth.TenantId)."
}

function Refresh-TagFilter {
    $current = $ui.cmbTagFilter.SelectedItem
    $tags = @('(all)', '(no tag)') + @($script:Rows | ForEach-Object { $_.GroupTag } | Where-Object { $_ } | Sort-Object -Unique)
    $ui.cmbTagFilter.ItemsSource = $tags
    if ($current -and $tags -contains $current) { $ui.cmbTagFilter.SelectedItem = $current } else { $ui.cmbTagFilter.SelectedIndex = 0 }
}

# Note: never return the ICollectionView from a function - PowerShell would unroll it into its rows.
function Get-VisibleRows {
    $list = New-Object System.Collections.Generic.List[object]
    foreach ($r in $script:View) { $list.Add($r) }
    return $list   # unrolled on purpose; callers wrap in @()
}

function Update-Filter {
    $search = $ui.txtSearch.Text.Trim()
    $tag = [string]$ui.cmbTagFilter.SelectedItem
    $onlyStaged = [bool]$ui.chkOnlyStaged.IsChecked
    $script:View.Filter = [Predicate[object]] {
        param($r)
        if ($onlyStaged -and -not $r.Pending) { return $false }
        if ($tag -eq '(no tag)' -and $r.GroupTag) { return $false }
        if ($tag -and $tag -ne '(all)' -and $tag -ne '(no tag)' -and $r.GroupTag -ne $tag) { return $false }
        if ($search) {
            $hay = "$($r.SerialNumber)|$($r.GroupTag)|$($r.Model)|$($r.DisplayName)|$($r.UserPrincipal)|$($r.Manufacturer)"
            if ($hay.IndexOf($search, [StringComparison]::OrdinalIgnoreCase) -lt 0) { return $false }
        }
        return $true
    }.GetNewClosure()
    Update-Count
}

function Update-Count {
    $visible = @(Get-VisibleRows).Count
    $checked = @($script:Rows | Where-Object { $_.Selected }).Count
    $staged = @($script:Rows | Where-Object { $_.Pending }).Count
    $ui.txtCount.Text = "$visible shown of $($script:Rows.Count)  |  $checked checked  |  $staged staged"
    Update-ButtonState
}

function Get-TargetRows {
    $rows = @($script:Rows | Where-Object { $_.Selected })
    if ($rows.Count -eq 0) { $rows = @($ui.dgDevices.SelectedItems | ForEach-Object { $_ }) }
    return $rows
}

function Stage-Tag([string]$Tag) {
    $rows = Get-TargetRows
    if ($rows.Count -eq 0) { Show-Message 'Check or highlight at least one device first.' 'Warning' | Out-Null; return }
    foreach ($r in $rows) {
        if ("$($r.GroupTag)" -ceq $Tag) { $r.Pending = $false; $r.NewTag = $null; continue }
        $r.NewTag = $Tag; $r.Pending = $true; $r.Status = 'Staged'
    }
    $label = if ($Tag) { "'$Tag'" } else { '(clear)' }
    Write-Log "Staged group tag $label for $($rows.Count) device(s)."
    Update-Count
}

# Reads a serial list from CSV/TXT. Accepts:
#   * a header row with a serial column (SerialNumber / Serial / Device Serial Number) and optional tag column
#     (GroupTag / Group Tag / Tag / OrderID) - this includes Autopilot hardware-hash CSVs
#   * no header at all: one serial per line (first field of each line is used)
# Returns @{ Entries = list of [pscustomobject]@{Serial; Tag}; HasTagColumn = bool; Path = file }
function Read-SerialFile {
    $dlg = New-Object Microsoft.Win32.OpenFileDialog
    $dlg.Filter = 'CSV or text files (*.csv;*.txt)|*.csv;*.txt|All files (*.*)|*.*'
    if (-not $dlg.ShowDialog($window)) { return $null }
    $path = $dlg.FileName

    $lines = @(Get-Content -Path $path | Where-Object { "$_".Trim() })
    if ($lines.Count -eq 0) { throw 'The file is empty.' }

    $first = $lines[0]
    $delim = if ($first -match "`t") { "`t" } elseif ($first -match ';' -and $first -notmatch ',') { ';' } else { ',' }
    $headers = @($first.Split($delim) | ForEach-Object { $_.Trim().Trim('"').Trim() })
    $serialRx = '^(serial ?number|serial ?no\.?|serial|device serial number|serial_number)$'
    $tagRx = '^(group ?tag|grouptag|group_tag|tag|order ?id)$'
    $serialCol = $headers | Where-Object { $_ -match $serialRx } | Select-Object -First 1
    $tagCol = $headers | Where-Object { $_ -match $tagRx } | Select-Object -First 1

    $entries = New-Object System.Collections.Generic.List[object]
    if ($serialCol) {
        foreach ($row in (Import-Csv -Path $path -Delimiter $delim)) {
            $serial = "$($row.$serialCol)".Trim()
            if (-not $serial) { continue }
            $tag = if ($tagCol) { "$($row.$tagCol)".Trim() } else { $null }
            $entries.Add([pscustomobject]@{ Serial = $serial; Tag = $tag })
        }
    }
    elseif ($headers.Count -gt 1 -and ($headers | Where-Object { $_ -match '[a-z]{3,} [a-z]{3,}' })) {
        throw "Couldn't find a serial number column. Found columns: $($headers -join ', ')`nName the column SerialNumber, or use a file with one serial per line."
    }
    else {
        # No header: one serial per line
        foreach ($l in $lines) {
            $serial = ($l.Split($delim)[0]).Trim().Trim('"').Trim()
            if ($serial -and $serial -notmatch '^(serial|serialnumber|serial number)$') {
                $entries.Add([pscustomobject]@{ Serial = $serial; Tag = $null })
            }
        }
    }
    if ($entries.Count -eq 0) { throw 'No serial numbers found in the file.' }
    Write-Log "Read $($entries.Count) serial(s) from $path$(if ($tagCol) { " (tag column: $tagCol)" })"
    return @{ Entries = $entries; HasTagColumn = [bool]$tagCol; Path = $path }
}

# Stages tags for a list of @{Serial; Tag} against the loaded devices
function Stage-FromEntries($Entries, [string]$Source) {
    $bySerial = @{}
    foreach ($r in $script:Rows) {
        $k = "$($r.SerialNumber)".Trim().ToUpperInvariant()
        if (-not $bySerial.ContainsKey($k)) { $bySerial[$k] = New-Object System.Collections.Generic.List[object] }
        $bySerial[$k].Add($r)
    }

    $staged = 0; $same = 0; $seen = @{}
    $missing = New-Object System.Collections.Generic.List[string]
    foreach ($e in $Entries) {
        $k = $e.Serial.ToUpperInvariant()
        if ($seen.ContainsKey($k)) { continue }; $seen[$k] = $true
        if (-not $bySerial.ContainsKey($k)) { $missing.Add($e.Serial); continue }
        if ($bySerial[$k].Count -gt 1) { Write-Log "Serial $($e.Serial) matches $($bySerial[$k].Count) Autopilot records - staging all of them." 'WARN' }
        foreach ($r in $bySerial[$k]) {
            if ("$($r.GroupTag)" -ceq "$($e.Tag)") { $same++; $r.Status = 'Already correct'; continue }
            $r.NewTag = "$($e.Tag)"; $r.Pending = $true; $r.Status = "Staged ($Source)"; $staged++
        }
    }

    Write-Log "$Source import: $($seen.Count) unique serial(s) - $staged staged, $same already correct, $($missing.Count) not found in this tenant."
    if ($missing.Count -gt 0) {
        Write-Log ('Not found: ' + ($missing -join ', ')) 'WARN'
        $r = Show-Message "$($missing.Count) serial number(s) weren't found in this tenant's Autopilot devices.`n`nSave them to a CSV so you can check them?" 'Warning' 'YesNo'
        if ("$r" -eq 'Yes') {
            $dlg = New-Object Microsoft.Win32.SaveFileDialog
            $dlg.Filter = 'CSV files (*.csv)|*.csv'
            $dlg.FileName = 'SerialsNotFound_{0:yyyyMMdd_HHmm}.csv' -f (Get-Date)
            if ($dlg.ShowDialog($window)) {
                $missing | ForEach-Object { [pscustomobject]@{ SerialNumber = $_ } } | Export-Csv -Path $dlg.FileName -NoTypeInformation -Encoding UTF8
                Write-Log "Saved not-found serials to $($dlg.FileName)"
            }
        }
    }
    $ui.chkOnlyStaged.IsChecked = $true
    $ui.cmbTagFilter.SelectedIndex = 0
    Update-Filter
    if ($staged -gt 0) {
        Show-Message "$staged device(s) staged. Review the yellow rows, then click 'Apply staged changes'." 'Information' | Out-Null
    }
}

function Ensure-DevicesLoaded {
    if ($script:Rows.Count -eq 0 -or $script:LoadedTenant -ne $script:Auth.TenantId) {
        Write-Log 'Loading devices first...'
        Load-Devices
    }
}

function Get-TagToApply {
    $tag = $ui.txtNewTag.Text.Trim()
    if (-not $tag) {
        Add-Type -AssemblyName Microsoft.VisualBasic
        $tag = [Microsoft.VisualBasic.Interaction]::InputBox("Group tag to set on every serial in the file:`n(type CLEAR to remove the tag instead)", 'Group tag', '').Trim()
        if (-not $tag) { return $null }
        if ($tag -ne 'CLEAR') { $ui.txtNewTag.Text = $tag }
    }
    if ($tag -eq 'CLEAR') { return '' }
    return $tag
}

# Serial list -> one tag (typed in the New group tag box)
function Import-SerialList {
    if (-not $script:Auth) { throw 'Connect to a tenant first.' }
    $tag = Get-TagToApply
    if ($null -eq $tag) { return }
    $file = Read-SerialFile
    if (-not $file) { return }
    if ($file.HasTagColumn) {
        $r = Show-Message "This file also has a group tag column.`n`nYes = ignore it and set every device to '$(if ($tag) { $tag } else { '(clear)' })'`nNo = use the tags from the file" 'Question' 'YesNoCancel'
        if ("$r" -eq 'Cancel') { return }
        if ("$r" -eq 'No') { Ensure-DevicesLoaded; Stage-FromEntries $file.Entries 'CSV'; return }
    }
    foreach ($e in $file.Entries) { $e.Tag = $tag }
    Ensure-DevicesLoaded
    Stage-FromEntries $file.Entries 'serial list'
}

# CSV with per-row tags; falls back to the typed tag when the file only has serials
function Import-TagCsv {
    if (-not $script:Auth) { throw 'Connect to a tenant first.' }
    $file = Read-SerialFile
    if (-not $file) { return }
    if (-not $file.HasTagColumn) {
        Write-Log 'No group tag column in the file - using the New group tag box for every serial.'
        $tag = Get-TagToApply
        if ($null -eq $tag) { return }
        foreach ($e in $file.Entries) { $e.Tag = $tag }
    }
    Ensure-DevicesLoaded
    Stage-FromEntries $file.Entries 'CSV'
}

function Apply-Staged {
    if ($script:LoadedTenant -ne $script:Auth.TenantId) {
        Show-Message 'The loaded device list is from a different tenant than the current connection. Reload devices first.' 'Error' | Out-Null
        return
    }
    $rows = @($script:Rows | Where-Object { $_.Pending })
    if ($rows.Count -eq 0) { Show-Message 'Nothing is staged.' 'Information' | Out-Null; return }

    $dry = [bool]$ui.chkDryRun.IsChecked
    $tenantLabel = if ($script:Auth.TenantName) { "$($script:Auth.TenantName) ($($script:Auth.TenantId))" } else { $script:Auth.TenantId }
    $summary = ($rows | Group-Object { if ($_.NewTag) { $_.NewTag } else { '(clear)' } } | ForEach-Object { "  $($_.Name): $($_.Count) device(s)" }) -join "`n"
    $verb = if ($dry) { 'DRY RUN - simulate updating' } else { 'Update' }
    $r = Show-Message "$verb the group tag on $($rows.Count) Autopilot device(s) in tenant:`n$tenantLabel`n`n$summary`n`nContinue?" 'Question' 'YesNo'
    if ("$r" -ne 'Yes') { return }

    $ok = 0; $fail = 0; $i = 0
    foreach ($row in $rows) {
        $i++
        $ui.txtCount.Text = "Applying $i / $($rows.Count)..."
        $newLabel = if ($row.NewTag) { $row.NewTag } else { '(clear)' }
        if ($dry) {
            Write-Log "[DRY RUN] $($row.SerialNumber): '$($row.GroupTag)' -> '$newLabel'"
            $row.Status = 'Dry run OK'
            continue
        }
        try {
            $body = @{ groupTag = [string]$row.NewTag }
            Invoke-Graph -Method POST -Uri "$($script:GraphBase)/deviceManagement/windowsAutopilotDeviceIdentities/$($row.Id)/updateDeviceProperties" -Body $body | Out-Null
            Write-Log "tenant=$($script:Auth.TenantId) serial=$($row.SerialNumber) id=$($row.Id) groupTag '$($row.GroupTag)' -> '$newLabel' by $($script:Auth.Identity)" 'CHANGE'
            $row.GroupTag = $row.NewTag
            $row.NewTag = $null; $row.Pending = $false; $row.Status = 'Updated'; $row.Selected = $false
            $ok++
        }
        catch {
            $row.Status = 'Failed'
            Write-Log "$($row.SerialNumber): $_" 'ERROR'
            $fail++
        }
        Update-UI
    }
    if (-not $dry) {
        Write-Log "Done: $ok updated, $fail failed. Intune can take a few minutes to show new tags; dynamic groups re-evaluate afterwards."
        Refresh-TagFilter
    }
    Update-Filter
}

function Export-View {
    $dlg = New-Object Microsoft.Win32.SaveFileDialog
    $dlg.Filter = 'CSV files (*.csv)|*.csv'
    $dlg.FileName = 'AutopilotGroupTags_{0}_{1:yyyyMMdd_HHmm}.csv' -f ($script:Auth.TenantName -replace '[^\w\-]', ''), (Get-Date)
    if (-not $dlg.ShowDialog($window)) { return }
    @(Get-VisibleRows) |
    Select-Object SerialNumber, GroupTag, @{n = 'StagedGroupTag'; e = { $_.NewTagDisplay } }, Model, Manufacturer, DisplayName, UserPrincipal, EnrollmentState, LastContacted, Status, Id, AzureAdDeviceId |
    Export-Csv -Path $dlg.FileName -NoTypeInformation -Encoding UTF8
    Write-Log "Exported view to $($dlg.FileName)"
}

function Save-Template {
    $dlg = New-Object Microsoft.Win32.SaveFileDialog
    $dlg.Filter = 'CSV files (*.csv)|*.csv'
    $dlg.FileName = 'GroupTagImport.csv'
    if (-not $dlg.ShowDialog($window)) { return }
    $rows = @(Get-TargetRows)
    if ($rows.Count -eq 0) { $rows = @(Get-VisibleRows) }
    if ($rows.Count -gt 0) {
        $rows | Select-Object SerialNumber, GroupTag | Export-Csv -Path $dlg.FileName -NoTypeInformation -Encoding UTF8
    }
    else {
        "SerialNumber,GroupTag`r`nABC1234567,EXAMPLE-TAG" | Set-Content -Path $dlg.FileName -Encoding UTF8
    }
    Write-Log "CSV template saved to $($dlg.FileName) - edit the GroupTag column and use Import CSV."
}

function Invoke-AutopilotSync {
    Invoke-Graph -Method POST -Uri "$($script:GraphBase)/deviceManagement/windowsAutopilotSettings/sync" | Out-Null
    Write-Log 'Autopilot sync requested (Intune allows one sync every ~10 minutes).'
}

# Wrap handlers so errors land in the log + a dialog rather than killing the window
function Invoke-Safe([scriptblock]$Action, [string]$What) {
    Set-Busy $true
    try { & $Action }
    catch {
        Write-Log "$What failed: $_" 'ERROR'
        Show-Message "$What failed:`n`n$_" 'Error' | Out-Null
    }
    finally { Set-Busy $false; Update-Count }
}

# --- Wire up events -------------------------------------------------------------------
$ui.dgDevices.ItemsSource = $script:Rows

$ui.rbToken.Add_Checked({ Update-ButtonState })
$ui.rbInteractive.Add_Checked({ Update-ButtonState })

$ui.cmbTenants.Add_SelectionChanged({
        $t = $ui.cmbTenants.SelectedItem
        if ($t) { $ui.txtTenantId.Text = $t.TenantId }
    })

$ui.btnSaveTenant.Add_Click({
        $id = $ui.txtTenantId.Text.Trim()
        if (-not $id) { Show-Message 'Enter a tenant ID or domain first (or connect, which fills it in).' 'Warning' | Out-Null; return }
        Add-Type -AssemblyName Microsoft.VisualBasic
        $default = if ($script:Auth -and $script:Auth.TenantId -eq $id -and $script:Auth.TenantName) { $script:Auth.TenantName } else { $id }
        $name = [Microsoft.VisualBasic.Interaction]::InputBox('Friendly name for this tenant:', 'Save tenant', $default)
        if (-not $name) { return }
        $list = @(Get-SavedTenants | Where-Object { $_.TenantId -ne $id })
        $list += [pscustomobject]@{ Name = $name; TenantId = $id }
        Save-Tenants $list
        Refresh-TenantCombo $id
        Write-Log "Saved tenant '$name' ($id)."
    })

$ui.btnRemoveTenant.Add_Click({
        $t = $ui.cmbTenants.SelectedItem
        if (-not $t) { return }
        Save-Tenants @(Get-SavedTenants | Where-Object { $_.TenantId -ne $t.TenantId })
        Refresh-TenantCombo
        Write-Log "Removed saved tenant '$($t.Name)'."
    })

$ui.btnConnect.Add_Click({ Invoke-Safe { Connect-Tenant } 'Connect' })
$ui.btnDisconnect.Add_Click({ Invoke-Safe { Disconnect-Tenant } 'Disconnect' })
$ui.btnLoad.Add_Click({ Invoke-Safe { Load-Devices; Update-Filter } 'Loading devices' })

$ui.txtSearch.Add_TextChanged({ Update-Filter })
$ui.cmbTagFilter.Add_SelectionChanged({ Update-Filter })
$ui.chkOnlyStaged.Add_Click({ Update-Filter })

$ui.btnCheckVisible.Add_Click({ foreach ($r in @(Get-VisibleRows)) { $r.Selected = $true }; Update-Count })
$ui.btnUncheckAll.Add_Click({ foreach ($r in $script:Rows) { $r.Selected = $false }; Update-Count })
$ui.dgDevices.Add_PreviewMouseLeftButtonUp({ $window.Dispatcher.BeginInvoke([action] { Update-Count }) | Out-Null })

$ui.btnStage.Add_Click({
        $tag = $ui.txtNewTag.Text.Trim()
        if (-not $tag) { Show-Message 'Type the new group tag first (use "Stage clear tag" to remove tags).' 'Warning' | Out-Null; return }
        Stage-Tag $tag
    })
$ui.btnStageClear.Add_Click({ Stage-Tag '' })
$ui.btnUnstage.Add_Click({
        foreach ($r in $script:Rows) { if ($r.Pending) { $r.Pending = $false; $r.NewTag = $null; $r.Status = $null } }
        Write-Log 'Discarded all staged changes.'
        Update-Filter
    })
$ui.btnImportCsv.Add_Click({ Invoke-Safe { Import-TagCsv } 'CSV import' })
$ui.btnImportSerials.Add_Click({ Invoke-Safe { Import-SerialList } 'Serial list import' })
$ui.btnApply.Add_Click({ Invoke-Safe { Apply-Staged } 'Apply' })
$ui.btnSync.Add_Click({ Invoke-Safe { Invoke-AutopilotSync } 'Autopilot sync' })
$ui.btnExport.Add_Click({ Invoke-Safe { Export-View } 'Export' })
$ui.btnTemplate.Add_Click({ Invoke-Safe { Save-Template } 'Save template' })

$window.Add_Closing({
        $pending = @($script:Rows | Where-Object { $_.Pending }).Count
        if ($pending -gt 0) {
            $r = Show-Message "$pending staged change(s) have not been applied. Close anyway?" 'Warning' 'YesNo'
            if ("$r" -ne 'Yes') { $_.Cancel = $true }
        }
    })

# --- Start ----------------------------------------------------------------------------
Refresh-TenantCombo
Update-ButtonState
Update-Count
Write-Log "Ready. Audit log folder: $script:LogDir"
$null = $window.ShowDialog()