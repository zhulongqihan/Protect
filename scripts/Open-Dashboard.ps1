#requires -Version 5.1

[CmdletBinding()]
param(
    [string]$ProjectRoot = (Split-Path -Parent $PSScriptRoot)
)

$ErrorActionPreference = 'Stop'
$indexPath = Join-Path ([System.IO.Path]::GetFullPath($ProjectRoot)) 'index.html'
if (-not (Test-Path -LiteralPath $indexPath -PathType Leaf)) {
    throw ('找不到报告页面：{0}' -f $indexPath)
}
Start-Process -FilePath $indexPath
Write-Output ('DASHBOARD_OPENED={0}' -f $indexPath)
