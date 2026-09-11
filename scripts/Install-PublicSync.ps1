#requires -Version 5.1

[CmdletBinding()]
param(
    [string]$ProjectRoot = (Split-Path -Parent $PSScriptRoot)
)

$ErrorActionPreference = 'Stop'
$ProjectRoot = [System.IO.Path]::GetFullPath($ProjectRoot)
$checkScript = Join-Path $ProjectRoot 'scripts\Check-PublicSafe.ps1'
$hooksPath = Join-Path $ProjectRoot '.githooks'
if (-not (Test-Path -LiteralPath (Join-Path $ProjectRoot '.git'))) { throw '当前目录不是 Git 仓库。' }
if (-not (Test-Path -LiteralPath $hooksPath -PathType Container)) { throw '找不到 .githooks 目录。' }
if (-not (Test-Path -LiteralPath $checkScript -PathType Leaf)) { throw '找不到公开安全检查脚本。' }

& $checkScript -ProjectRoot $ProjectRoot -History
if (-not $?) { throw '公开安全检查未通过，未安装自动同步。' }

$remote = @(& git -C $ProjectRoot remote 2>$null | Where-Object { $_ })
if ($LASTEXITCODE -ne 0 -or $remote.Count -eq 0) { throw '当前 Git 仓库没有远程地址。' }
& git -C $ProjectRoot config core.hooksPath .githooks
if ($LASTEXITCODE -ne 0) { throw 'Git hooks 配置失败。' }

Write-Output 'PUBLIC_SYNC=INSTALLED'
Write-Output '后续提交会先通过公开安全检查，再自动推送当前分支。'
