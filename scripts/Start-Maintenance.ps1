#requires -Version 5.1

[CmdletBinding()]
param(
    [string]$ProjectRoot = (Split-Path -Parent $PSScriptRoot),
    [switch]$Fast,
    [switch]$SkipOpen
)

$ErrorActionPreference = 'Stop'
$ProjectRoot = [System.IO.Path]::GetFullPath($ProjectRoot)
$scriptRoot = Join-Path $ProjectRoot 'scripts'
$buildScript = Join-Path $scriptRoot 'Build-CleanupManifest.ps1'
$collectScript = Join-Path $scriptRoot 'Collect-SystemStatus.ps1'
$openScript = Join-Path $scriptRoot 'Open-Dashboard.ps1'

foreach ($required in @($buildScript, $collectScript, $openScript)) {
    if (-not (Test-Path -LiteralPath $required -PathType Leaf)) {
        throw ('找不到维护脚本：{0}' -f $required)
    }
}

. (Join-Path $scriptRoot 'Protect.Common.ps1')
$runtimeRoot = Initialize-ProtectRuntime -ProjectRoot $ProjectRoot
$runId = Get-Date -Format 'yyyyMMdd-HHmmss-fff'
$scanLabel = if ($Fast) { '快速扫描' } else { '全盘扫描' }

Write-Output ('开始{0}，只读阶段不会删除文件。' -f $scanLabel)
$buildOutput = @(& $buildScript -ProjectRoot $ProjectRoot -RunId $runId -Fast:$Fast)
if (-not $?) { throw '清理候选清单生成失败。' }
$buildOutput | Write-Output

$statusOutput = @(& $collectScript -ProjectRoot $ProjectRoot -RunId $runId)
if (-not $?) { throw '系统状态采集失败。' }
$statusOutput | Write-Output

Write-Output ('报告已写入：{0}' -f (Join-Path $runtimeRoot ('reports\{0}' -f $runId)))
if (-not $SkipOpen) {
    & $openScript -ProjectRoot $ProjectRoot
    if (-not $?) { throw '打开本地报告页面失败。' }
}
