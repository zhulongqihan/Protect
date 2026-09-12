#requires -Version 5.1

[CmdletBinding(SupportsShouldProcess = $true, ConfirmImpact = 'High')]
param(
    [string]$ProjectRoot = (Split-Path -Parent $PSScriptRoot),
    [string]$ApprovalFile,
    [switch]$Permanent,
    [switch]$AllowHighRisk,
    [switch]$DeepRefresh,
    [switch]$IncrementalRefresh
)

$ErrorActionPreference = 'Stop'
$simulate = [bool]$WhatIfPreference
$WhatIfPreference = $false
$ProjectRoot = [System.IO.Path]::GetFullPath($ProjectRoot)
$scriptRoot = Join-Path $ProjectRoot 'scripts'
. (Join-Path $scriptRoot 'Protect.Common.ps1')
$runtimeRoot = Initialize-ProtectRuntime -ProjectRoot $ProjectRoot
$manifestPath = Join-Path $runtimeRoot 'data\pending-cleanup.json'

if ($DeepRefresh -and $IncrementalRefresh) {
    throw 'DeepRefresh 和 IncrementalRefresh 不能同时使用。'
}

if (-not $ApprovalFile) {
    $ApprovalFile = Get-ChildItem -LiteralPath (Join-Path $runtimeRoot 'approvals') -Filter 'approval-*.json' -File -ErrorAction SilentlyContinue |
        Sort-Object LastWriteTimeUtc -Descending |
        Select-Object -First 1 -ExpandProperty FullName
}
if (-not $ApprovalFile -or -not (Test-Path -LiteralPath $ApprovalFile -PathType Leaf)) {
    throw '没有找到审批文件。请先在页面逐项勾选后导出 approval-*.json，再把文件路径传给本脚本。'
}
if (-not (Test-Path -LiteralPath $manifestPath -PathType Leaf)) {
    throw '没有找到待审清单。请先运行 Start-Maintenance.ps1。'
}

try {
    $manifest = Get-Content -LiteralPath $manifestPath -Raw -Encoding UTF8 | ConvertFrom-Json
    $approval = Get-Content -LiteralPath $ApprovalFile -Raw -Encoding UTF8 | ConvertFrom-Json
} catch {
    throw ('审批文件或清单不是有效 JSON：{0}' -f $_.Exception.Message)
}

if ($null -eq $approval.PSObject.Properties['schemaVersion'] -or [int]$approval.schemaVersion -ne 1) {
    throw '审批文件版本不受支持。'
}
if ($null -eq $approval.PSObject.Properties['runId'] -or [string]$approval.runId -ne [string]$manifest.runId) {
    throw '审批文件对应的扫描批次已变化。请重新打开页面并导出最新审批文件。'
}
if ($null -eq $approval.PSObject.Properties['approvedCandidateIds']) {
    throw '审批文件缺少 approvedCandidateIds。'
}

$mode = if ($Permanent) { 'permanent' } else { [string]$approval.mode }
if ($mode -notin @('recycle', 'permanent')) { throw '审批文件的操作模式无效。' }
if ($mode -eq 'permanent' -and -not $Permanent) {
    throw '永久删除必须显式传入 -Permanent。'
}

$approvedIds = @($approval.approvedCandidateIds | ForEach-Object { [string]$_ } | Where-Object { $_ } | Select-Object -Unique)
$candidateMap = @{}
foreach ($candidate in @($manifest.candidates)) {
    $candidateMap[[string]$candidate.id] = $candidate
}

$blocked = New-Object System.Collections.Generic.List[object]
$ready = New-Object System.Collections.Generic.List[object]

function Test-ProtectFixedFilePath {
    param([Parameter(Mandatory = $true)][string]$Path)

    try {
        $root = [System.IO.Path]::GetPathRoot($Path)
        if (-not $root -or $root.Length -ne 3 -or $root[1] -ne ':' -or [System.IO.Path]::GetFullPath($Path).TrimEnd('\').Length -le 2) { return $false }
        $drive = New-Object System.IO.DriveInfo($root)
        return $drive.DriveType -eq [System.IO.DriveType]::Fixed
    } catch { return $false }
}

function Convert-ProtectUtcTimestamp {
    param([Parameter(Mandatory = $true)]$Value)

    if ($Value -is [DateTime]) { return $Value.ToUniversalTime() }
    return [DateTime]::Parse(
        [string]$Value,
        [Globalization.CultureInfo]::InvariantCulture,
        [Globalization.DateTimeStyles]::RoundtripKind
    ).ToUniversalTime()
}

foreach ($id in $approvedIds) {
    if (-not $candidateMap.ContainsKey($id)) {
        $blocked.Add([ordered]@{ id = $id; reason = '审批项不在当前清单中。' }) | Out-Null
        continue
    }

    $candidate = $candidateMap[$id]
    $path = [string]$candidate.path
    $blockReason = Get-ProtectProtectedPathReason -Path $path
    $safeSystemCleanup = $blockReason -eq 'system-path' -and
        (Test-ProtectSafeCleanupPath -Path $path) -and
        [string]$candidate.category -in @('cache', 'temp', 'log')
    if ($blockReason -and -not $safeSystemCleanup) {
        $blocked.Add([ordered]@{ id = $id; path = $path; reason = '系统保护路径不允许清理。' }) | Out-Null
        continue
    }
    $personalReason = Get-ProtectPersonalPathReason -Path $path
    if ($personalReason) {
        $blocked.Add([ordered]@{ id = $id; path = $path; reason = '个人资料策略禁止移动或删除。' }) | Out-Null
        continue
    }
    if ([string]$candidate.risk -eq 'high' -and -not $AllowHighRisk) {
        $blocked.Add([ordered]@{ id = $id; path = $path; reason = '高风险大文件需要显式传入 -AllowHighRisk。' }) | Out-Null
        continue
    }
    if (-not (Test-ProtectFixedFilePath -Path $path)) {
        $blocked.Add([ordered]@{ id = $id; path = $path; reason = '只允许处理本机固定磁盘上的文件。' }) | Out-Null
        continue
    }

    $fingerprint = Get-ProtectFingerprint -Path $path
    $sameFile = $false
    try {
        if ([string]$candidate.fingerprint.kind -eq 'directory') {
            $currentWrite = Convert-ProtectUtcTimestamp -Value $fingerprint.latestWriteUtc
            $expectedWrite = Convert-ProtectUtcTimestamp -Value $candidate.fingerprint.latestWriteUtc
            $sameFile = $fingerprint.kind -eq 'directory' -and
                [long]$fingerprint.bytes -eq [long]$candidate.fingerprint.bytes -and
                [int]$fingerprint.fileCount -eq [int]$candidate.fingerprint.fileCount -and
                $currentWrite.Ticks -eq $expectedWrite.Ticks
        } else {
            $currentWrite = Convert-ProtectUtcTimestamp -Value $fingerprint.lastWriteUtc
            $expectedWrite = Convert-ProtectUtcTimestamp -Value $candidate.fingerprint.lastWriteUtc
            $sameFile = $fingerprint.kind -eq 'file' -and
                [long]$fingerprint.bytes -eq [long]$candidate.fingerprint.bytes -and
                $currentWrite.Ticks -eq $expectedWrite.Ticks
        }
    } catch {}
    if (-not $sameFile) {
        $blocked.Add([ordered]@{ id = $id; path = $path; reason = '文件在审批后发生变化，已停止处理。' }) | Out-Null
        continue
    }
    $ready.Add($candidate) | Out-Null
}

$resultRunId = Get-Date -Format 'yyyyMMdd-HHmmss-fff'
$result = [ordered]@{
    schemaVersion = 1
    runId = $resultRunId
    approvalRunId = [string]$approval.runId
    generatedAt = (Get-Date).ToUniversalTime().ToString('o')
    mode = $mode
    approvedCount = $approvedIds.Count
    blockedCount = $blocked.Count
    applied = @()
    blocked = @($blocked.ToArray())
    skipped = @()
    errors = @()
}

if ($blocked.Count -gt 0) {
    $result.errors = @('预检发现阻断项，未处理任何文件。')
    $resultPath = Join-Path $runtimeRoot ('approvals\apply-{0}.json' -f $resultRunId)
    Write-ProtectJson -Object $result -Path $resultPath
    Write-Output ('APPLY_BLOCKED={0}' -f $blocked.Count)
    Write-Output ('APPLY_RESULT={0}' -f $resultPath)
    exit 1
}

if ($ready.Count -gt 0 -and $mode -eq 'recycle') {
    Add-Type -AssemblyName Microsoft.VisualBasic
}

$applied = New-Object System.Collections.Generic.List[object]
$errors = New-Object System.Collections.Generic.List[object]
$skipped = New-Object System.Collections.Generic.List[object]
foreach ($candidate in $ready) {
    try {
        $actionLabel = if ($mode -eq 'recycle') { '送入回收站' } else { '永久删除' }
        if ($simulate) {
            $skipped.Add([ordered]@{ id = [string]$candidate.id; path = [string]$candidate.path; reason = 'WhatIf 模式未执行。' }) | Out-Null
        } elseif ($PSCmdlet.ShouldProcess([string]$candidate.path, $actionLabel)) {
            if ($mode -eq 'recycle') {
                if ([string]$candidate.fingerprint.kind -eq 'directory') {
                    [Microsoft.VisualBasic.FileIO.FileSystem]::DeleteDirectory(
                        [string]$candidate.path,
                        [Microsoft.VisualBasic.FileIO.UIOption]::OnlyErrorDialogs,
                        [Microsoft.VisualBasic.FileIO.RecycleOption]::SendToRecycleBin
                    )
                } else {
                    [Microsoft.VisualBasic.FileIO.FileSystem]::DeleteFile(
                        [string]$candidate.path,
                        [Microsoft.VisualBasic.FileIO.UIOption]::OnlyErrorDialogs,
                        [Microsoft.VisualBasic.FileIO.RecycleOption]::SendToRecycleBin
                    )
                }
            } else {
                if ([string]$candidate.fingerprint.kind -eq 'directory') {
                    [System.IO.Directory]::Delete([string]$candidate.path, $true)
                } else {
                    Remove-Item -LiteralPath ([string]$candidate.path) -Force -ErrorAction Stop
                }
            }
            $applied.Add([ordered]@{ id = [string]$candidate.id; path = [string]$candidate.path; bytes = [long]$candidate.bytes }) | Out-Null
        } else {
            $skipped.Add([ordered]@{ id = [string]$candidate.id; path = [string]$candidate.path; reason = '用户确认未执行。' }) | Out-Null
        }
    } catch {
        $errors.Add([ordered]@{ id = [string]$candidate.id; path = [string]$candidate.path; reason = $_.Exception.Message }) | Out-Null
    }
}

$result.applied = @($applied.ToArray())
$result.errors = @($errors.ToArray())
$result.skipped = @($skipped.ToArray())
$result.blockedCount = $blocked.Count
$resultPath = Join-Path $runtimeRoot ('approvals\apply-{0}.json' -f $resultRunId)
Write-ProtectJson -Object $result -Path $resultPath

$appliedBytes = [long]0
foreach ($item in $applied) { $appliedBytes += [long]$item.bytes }
Write-Output ('APPLIED_COUNT={0}' -f $applied.Count)
Write-Output ('APPLIED_BYTES={0}' -f $appliedBytes)
Write-Output ('APPLY_ERRORS={0}' -f $errors.Count)
Write-Output ('APPLY_SKIPPED={0}' -f $skipped.Count)
Write-Output ('APPLY_RESULT={0}' -f $resultPath)

$collectScript = Join-Path $scriptRoot 'Collect-SystemStatus.ps1'
$useIncrementalRefresh = $IncrementalRefresh -or -not $DeepRefresh
if ($useIncrementalRefresh) {
    $appliedIds = @($applied | ForEach-Object { [string]$_.id })
    $remainingCandidates = @($manifest.candidates | Where-Object { $appliedIds -notcontains [string]$_.id })
    $remainingBytes = [long]0
    foreach ($candidate in $remainingCandidates) { $remainingBytes += [long]$candidate.bytes }

    $remainingTopDirectories = @()
    if ($null -ne $manifest.topDirectories) {
        foreach ($topDirectory in @($manifest.topDirectories)) {
            if ($null -eq $topDirectory) { continue }
            $topPath = [string]$topDirectory.path
            $topBytes = [long]$topDirectory.bytes
            $topFileCount = [int]$topDirectory.fileCount
            foreach ($item in $applied) {
                $itemPath = [string]$item.path
                if ($itemPath.Equals($topPath, [StringComparison]::OrdinalIgnoreCase) -or
                    $itemPath.StartsWith($topPath + '\', [StringComparison]::OrdinalIgnoreCase)) {
                    $topBytes -= [long]$item.bytes
                    $topFileCount -= 1
                }
            }
            $remainingTopDirectories += [ordered]@{
                path = $topPath
                bytes = [math]::Max([long]0, $topBytes)
                fileCount = [math]::Max(0, $topFileCount)
            }
        }
    }
    $remainingTopDirectories = @($remainingTopDirectories | Sort-Object -Property bytes -Descending | Select-Object -First 100)
    $incrementalManifest = [ordered]@{
        schemaVersion = $manifest.schemaVersion
        runId = $resultRunId
        generatedAt = (Get-Date).ToUniversalTime().ToString('o')
        scanMode = 'incremental'
        minimumLargeFileBytes = $manifest.minimumLargeFileBytes
        candidateCount = $remainingCandidates.Count
        candidateBytes = $remainingBytes
        excludedByPolicy = $manifest.excludedByPolicy
        candidates = $remainingCandidates
        topDirectories = $remainingTopDirectories
        scanErrors = @($manifest.scanErrors)
    }
    Write-ProtectJson -Object $incrementalManifest -Path (Join-Path $runtimeRoot ('reports\{0}\cleanup-manifest.json' -f $resultRunId))
    Write-ProtectJson -Object $incrementalManifest -Path (Join-Path $runtimeRoot 'data\pending-cleanup.json')
    Write-ProtectBrowserScript -Object $incrementalManifest -Path (Join-Path $runtimeRoot 'data\pending-cleanup.js') -VariableName 'PROTECT_RUNTIME_CLEANUP'
    Write-Output ('MANIFEST_RUN_ID={0}' -f $resultRunId)
    Write-Output ('CANDIDATE_COUNT={0}' -f $incrementalManifest.candidateCount)
    Write-Output ('CANDIDATE_BYTES={0}' -f $incrementalManifest.candidateBytes)
    Write-Output ('SCAN_MODE={0}' -f $incrementalManifest.scanMode)
} else {
    $buildScript = Join-Path $scriptRoot 'Build-CleanupManifest.ps1'
    $refreshParams = @{ ProjectRoot = $ProjectRoot; RunId = $resultRunId }
    if (-not $DeepRefresh) { $refreshParams['Fast'] = $true }
    & $buildScript @refreshParams | Write-Output
    if (-not $?) { throw '清理后的候选清单刷新失败。' }
}
& $collectScript -ProjectRoot $ProjectRoot -RunId $resultRunId | Write-Output
if (-not $?) { throw '清理后的状态报告刷新失败。' }
