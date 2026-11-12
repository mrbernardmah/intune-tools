# Runs one generated script against the mocks and prints the outcome as JSON.
param([string]$Script)
. (Join-Path $PSScriptRoot 'mocks.ps1')
$out = & $Script
$code = $LASTEXITCODE
[pscustomobject]@{
    exit  = $code
    out   = (@($out) -join "`n")
    calls = @($global:Calls)
    svc   = $global:Svc
    reg   = $global:Reg
    dirs  = @(Microsoft.PowerShell.Management\Get-ChildItem -Path $env:SystemRoot -Recurse -Directory | ForEach-Object Name)
} | ConvertTo-Json -Depth 6 -Compress
