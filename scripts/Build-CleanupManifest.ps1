#requires -Version 5.1

[CmdletBinding()]
param(
    [string]$ProjectRoot = (Split-Path -Parent $PSScriptRoot),
    [string]$RunId = (Get-Date -Format 'yyyyMMdd-HHmmss'),
    [long]$MinLargeFileBytes = 500MB,
    [switch]$Fast,
    [string[]]$ScanRoots,
    [switch]$SkipVolumes
)

. (Join-Path $PSScriptRoot 'Protect.Common.ps1')

$ErrorActionPreference = 'Stop'
$runtimeRoot = Initialize-ProtectRuntime -ProjectRoot $ProjectRoot
$runRoot = Join-Path (Join-Path $runtimeRoot 'reports') $RunId
New-Item -ItemType Directory -Force -Path $runRoot | Out-Null

$fixedVolumes = @(Get-CimInstance Win32_LogicalDisk -Filter "DriveType=3" | Where-Object { $_.DeviceID })
$candidateById = @{}
$topDirectoryTotals = @{}
$scanErrors = New-Object System.Collections.Generic.List[object]
$policyExclusions = New-Object System.Collections.Generic.List[object]

function Add-ManifestRecord {
    param([Parameter(Mandatory = $true)]$Record)

    if ($Record.PSObject.Properties['ProtectedReason'] -and $Record.ProtectedReason) { return }
    $category = Get-ProtectCategoryForPath -Path $Record.Path -Bytes $Record.Bytes -LastWriteTime $Record.LastWriteTime
    if ($null -eq $category) { return }

    $personalReason = Get-ProtectPersonalPathReason -Path $Record.Path
    if ($personalReason) {
        $policyExclusions.Add([ordered]@{ reason = $personalReason; bytes = [long]$Record.Bytes }) | Out-Null
        return
    }

    if ($Record.Bytes -lt $MinLargeFileBytes -and $category.category -eq 'large-file') { return }
    $id = Get-ProtectCandidateId -Path $Record.Path -Bytes $Record.Bytes -LastWriteUtc $Record.LastWriteTimeUtc
    if ($candidateById.ContainsKey($id)) { return }

    $candidateById[$id] = [ordered]@{
        id = $id
        category = $category.category
        path = $Record.Path
        bytes = [long]$Record.Bytes
        lastWriteUtc = $Record.LastWriteTimeUtc
        risk = $category.risk
        action = $category.action
        reversible = [bool]$category.reversible
        reason = $category.reason
        fingerprint = [ordered]@{
            kind = 'file'
            bytes = [long]$Record.Bytes
            lastWriteUtc = $Record.LastWriteTimeUtc
        }
    }
}

function Add-ManifestDirectoryRecord {
    param(
        [Parameter(Mandatory = $true)][string]$Path,
        [Parameter(Mandatory = $true)][long]$Bytes,
        [Parameter(Mandatory = $true)][int]$FileCount,
        [Parameter(Mandatory = $true)][string]$LastWriteUtc,
        [Parameter(Mandatory = $true)][datetime]$LastWriteTime
    )

    if (Get-ProtectProtectedPathReason -Path $Path) { return }
    $category = Get-ProtectCategoryForPath -Path $Path -Bytes $Bytes -LastWriteTime $LastWriteTime
    if ($null -eq $category) { return }
    $personalReason = Get-ProtectPersonalPathReason -Path $Path
    if ($personalReason) {
        $policyExclusions.Add([ordered]@{ reason = $personalReason; bytes = $Bytes }) | Out-Null
        return
    }
    $id = Get-ProtectCandidateId -Path $Path -Bytes $Bytes -LastWriteUtc $LastWriteUtc
    if ($candidateById.ContainsKey($id)) { return }

    $candidateById[$id] = [ordered]@{
        id = $id
        category = $category.category
        path = $Path
        bytes = $Bytes
        fileCount = $FileCount
        lastWriteUtc = $LastWriteUtc
        risk = $category.risk
        action = $category.action
        reversible = [bool]$category.reversible
        reason = $category.reason
        fingerprint = [ordered]@{
            kind = 'directory'
            bytes = $Bytes
            fileCount = $FileCount
            latestWriteUtc = $LastWriteUtc
        }
    }
}

function Add-TopDirectoryTotal {
    param([Parameter(Mandatory = $true)]$Record)

    try {
        $root = [System.IO.Path]::GetPathRoot($Record.Path)
        $relative = $Record.Path.Substring($root.Length).TrimStart('\')
        $first = ($relative -split '\\')[0]
        if (-not $first) { $first = '[root files]' }
        $key = Join-Path $root $first
        if (-not $topDirectoryTotals.ContainsKey($key)) {
            $topDirectoryTotals[$key] = [ordered]@{ path = $key; bytes = [long]0; fileCount = 0 }
        }
        $topDirectoryTotals[$key].bytes += [long]$Record.Bytes
        $topDirectoryTotals[$key].fileCount += 1
    } catch {
        $scanErrors.Add([ordered]@{ path = $Record.Path; message = $_.Exception.Message }) | Out-Null
    }
}

function Scan-Root {
    param(
        [Parameter(Mandatory = $true)][string]$Root,
        [switch]$IncludeProtected,
        [switch]$AggregateDirectory,
        [switch]$AggregateKnownDirectories,
        [string[]]$SkipRoots
    )

    if (-not (Test-Path -LiteralPath $Root)) { return }
    Write-Verbose ('Scanning {0}' -f $Root)
    $aggregateBytes = [long]0
    $aggregateFileCount = 0
    $latestWrite = $null
    Get-ProtectFileRecords -Root $Root -IncludeProtected:$IncludeProtected -SkipRoots $SkipRoots -AggregateKnownDirectories:$AggregateKnownDirectories | ForEach-Object {
        $record = $_
        Add-TopDirectoryTotal -Record $record
        if ($AggregateDirectory) {
            $aggregateBytes += [long]$record.Bytes
            $aggregateFileCount += 1
            if ($null -eq $latestWrite -or $record.LastWriteTime -gt $latestWrite) { $latestWrite = $record.LastWriteTime }
        } elseif ($record.PSObject.Properties['IsDirectory'] -and $record.IsDirectory) {
            Add-ManifestDirectoryRecord -Path $record.Path -Bytes $record.Bytes -FileCount $record.FileCount -LastWriteUtc $record.LastWriteTimeUtc -LastWriteTime $record.LastWriteTime
        } else {
            Add-ManifestRecord -Record $record
        }
        if (-not $Fast -and $record.Seen % 5000 -eq 0) {
            Write-Progress -Activity '扫描文件' -Status '本地文件系统' -CurrentOperation ('已读取 {0} 个文件' -f $record.Seen)
        }
    }
    if ($AggregateDirectory -and $aggregateFileCount -gt 0) {
        if ($null -eq $latestWrite) { $latestWrite = (Get-Item -LiteralPath $Root -Force).LastWriteTime }
        Add-ManifestDirectoryRecord -Path ([System.IO.Path]::GetFullPath($Root).TrimEnd('\')) -Bytes $aggregateBytes -FileCount $aggregateFileCount -LastWriteUtc $latestWrite.ToUniversalTime().ToString('o') -LastWriteTime $latestWrite
    }
}

$safeRoots = Get-ProtectSafeCleanupRoots

if ($ScanRoots) {
    $safeRoots = @($ScanRoots | Where-Object { $_ -and (Test-Path -LiteralPath $_) } | Select-Object -Unique)
}

foreach ($safeRoot in $safeRoots) {
    Scan-Root -Root $safeRoot -IncludeProtected -AggregateDirectory
}

if ($SkipVolumes) {
    Write-Verbose 'SkipVolumes enabled; only explicit scan roots were inspected.'
} elseif ($Fast) {
    foreach ($volume in $fixedVolumes) {
        $root = $volume.DeviceID + '\'
        foreach ($file in (Get-ChildItem -LiteralPath $root -File -Force -ErrorAction SilentlyContinue)) {
            $record = [pscustomobject]@{
                Path = $file.FullName
                Bytes = [long]$file.Length
                LastWriteTimeUtc = $file.LastWriteTimeUtc.ToString('o')
                LastWriteTime = $file.LastWriteTime
                ProtectedReason = Get-ProtectProtectedPathReason -Path $file.FullName
                Seen = 0
            }
            Add-TopDirectoryTotal -Record $record
            Add-ManifestRecord -Record $record
        }
    }
} else {
    foreach ($volume in $fixedVolumes) {
        Scan-Root -Root ($volume.DeviceID + '\') -SkipRoots $safeRoots -AggregateKnownDirectories
    }
}

Write-Progress -Activity '扫描文件' -Completed

$candidates = @($candidateById.Values | Sort-Object -Property bytes -Descending)
$candidateBytes = [long]0
foreach ($candidate in $candidates) { $candidateBytes += [long]$candidate.bytes }
$excludedBytes = [long]0
foreach ($excluded in $policyExclusions) { $excludedBytes += [long]$excluded.bytes }
$topDirectories = @()
if ($topDirectoryTotals.Count -gt 0) {
    $topDirectories = @($topDirectoryTotals.Values | Sort-Object -Property bytes -Descending | Select-Object -First 100)
}
$manifest = [ordered]@{
    schemaVersion = 1
    runId = $RunId
    generatedAt = (Get-Date).ToUniversalTime().ToString('o')
    scanMode = if ($Fast) { 'fast' } else { 'deep' }
    minimumLargeFileBytes = $MinLargeFileBytes
    candidateCount = $candidates.Count
    candidateBytes = $candidateBytes
    excludedByPolicy = [ordered]@{
        count = $policyExclusions.Count
        bytes = $excludedBytes
        reason = '个人资料和常见个人文件类型只统计为受保护项，不进入清理审批清单。'
    }
    candidates = $candidates
    topDirectories = $topDirectories
    scanErrors = @($scanErrors.ToArray())
}

Write-ProtectJson -Object $manifest -Path (Join-Path $runRoot 'cleanup-manifest.json')
Write-ProtectJson -Object $manifest -Path (Join-Path $runtimeRoot 'data\pending-cleanup.json')
Write-ProtectBrowserScript -Object $manifest -Path (Join-Path $runtimeRoot 'data\pending-cleanup.js') -VariableName 'PROTECT_RUNTIME_CLEANUP'

Write-Output ('MANIFEST_RUN_ID={0}' -f $RunId)
Write-Output ('CANDIDATE_COUNT={0}' -f $manifest.candidateCount)
Write-Output ('CANDIDATE_BYTES={0}' -f $manifest.candidateBytes)
Write-Output ('SCAN_MODE={0}' -f $manifest.scanMode)
