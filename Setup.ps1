#requires -Version 5.1

[CmdletBinding()]
param(
    [string]$ProjectRoot = (Split-Path -Parent $MyInvocation.MyCommand.Path),
    [switch]$InstallSync
)

$ErrorActionPreference = 'Stop'
$ProjectRoot = [System.IO.Path]::GetFullPath($ProjectRoot)
. (Join-Path $ProjectRoot 'scripts\Protect.Common.ps1')

$runtimeRoot = Initialize-ProtectRuntime -ProjectRoot $ProjectRoot
$powerShellVersion = $PSVersionTable.PSVersion.ToString()
Write-Output ('SETUP_OK=TRUE')
Write-Output ('POWERSHELL_VERSION={0}' -f $powerShellVersion)
Write-Output ('RUNTIME_ROOT={0}' -f $runtimeRoot)
Write-Output '实时杀毒策略未被本工具修改；页面会如实显示当前状态。'

if ($InstallSync) {
    & (Join-Path $ProjectRoot 'scripts\Install-PublicSync.ps1') -ProjectRoot $ProjectRoot
    if (-not $?) { throw '自动同步安装失败。' }
}
