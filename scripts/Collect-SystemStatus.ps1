#requires -Version 5.1

[CmdletBinding()]
param(
    [string]$ProjectRoot = (Split-Path -Parent $PSScriptRoot),
    [string]$RunId = (Get-Date -Format 'yyyyMMdd-HHmmss')
)

. (Join-Path $PSScriptRoot 'Protect.Common.ps1')

$ErrorActionPreference = 'Stop'
$runtimeRoot = Initialize-ProtectRuntime -ProjectRoot $ProjectRoot
$runRoot = Join-Path (Join-Path $runtimeRoot 'reports') $RunId
New-Item -ItemType Directory -Force -Path $runRoot | Out-Null
$generatedAt = (Get-Date).ToUniversalTime().ToString('o')
$isAdmin = Test-ProtectAdministrator

function Get-PhysicalDiskLabel {
    param([string]$MountPoint)

    try {
        $letter = $MountPoint.TrimEnd(':')
        $partition = Get-Partition -DriveLetter $letter -ErrorAction Stop
        $disk = Get-Disk -Number $partition.DiskNumber -ErrorAction Stop
        return ('SSD {0} · {1}' -f $disk.Number, $disk.FriendlyName)
    } catch {
        return '物理磁盘未核验'
    }
}

function Get-DiskReports {
    $reports = @()
    foreach ($volume in @(Get-CimInstance Win32_LogicalDisk -Filter "DriveType=3" | Where-Object { $_.DeviceID })) {
        $size = [long]$volume.Size
        $free = [long]$volume.FreeSpace
        $percent = if ($size -gt 0) { [math]::Round(100 * $free / $size, 1) } else { 0 }
        $reports += [ordered]@{
            id = ('disk-' + $volume.DeviceID.TrimEnd(':').ToLowerInvariant())
            mountPoint = $volume.DeviceID
            label = if ($volume.VolumeName) { $volume.VolumeName } else { '未命名磁盘' }
            totalBytes = $size
            freeBytes = $free
            freePercent = $percent
            status = Get-ProtectSpaceStatus -FreePercent $percent
            physicalDisk = Get-PhysicalDiskLabel -MountPoint $volume.DeviceID
        }
    }
    return $reports
}

function Get-FirewallReport {
    try {
        $profiles = @(Get-NetFirewallProfile)
        $enabled = @($profiles | Where-Object { $_.Enabled -eq $true })
        $status = if ($profiles.Count -gt 0 -and $enabled.Count -eq $profiles.Count) { 'pass' } else { 'attention' }
        return [ordered]@{
            status = $status
            summary = if ($status -eq 'pass') { '所有可见网络配置文件均已启用防火墙。' } else { '至少有一个网络配置文件没有启用防火墙。' }
            profiles = @($profiles | ForEach-Object {
                [ordered]@{ name = $_.Name; enabled = [bool]$_.Enabled }
            })
        }
    } catch {
        return [ordered]@{ status = 'unknown'; summary = '无法读取防火墙状态。'; error = $_.Exception.Message }
    }
}

function Get-AntivirusReport {
    $products = @()
    try {
        $products = @(Get-CimInstance -Namespace root/SecurityCenter2 -ClassName AntiVirusProduct | ForEach-Object {
            [ordered]@{
                name = $_.displayName
                productState = $_.productState
                executable = $_.pathToSignedProductExe
            }
        })
    } catch {}

    $defender = $null
    try { $defender = Get-MpComputerStatus -ErrorAction Stop } catch {}
    $realtime = if ($defender) { [bool]$defender.RealTimeProtectionEnabled } else { $false }
    $status = if ($realtime) { 'pass' } else { 'attention' }
    $summary = if ($realtime) {
        '检测到 Defender 实时保护已开启。'
    } else {
        '当前没有日常常驻实时防护；这是按需防护策略，请定期手动扫描。'
    }
    return [ordered]@{
        status = $status
        summary = $summary
        policy = '按需防护'
        defenderRealtime = $realtime
        products = $products
    }
}

function Get-UpdateReport {
    try {
        $service = Get-Service -Name 'wuauserv' -ErrorAction Stop
        $hotfix = @(Get-HotFix | Sort-Object InstalledOn -Descending | Select-Object -First 1)
        $latest = if ($hotfix.Count -gt 0) { $hotfix[0] } else { $null }
        return [ordered]@{
            status = if ($service.Status -eq 'Running') { 'pass' } else { 'attention' }
            summary = if ($service.Status -eq 'Running') { 'Windows Update 服务正在运行。' } else { 'Windows Update 服务当前没有运行。' }
            serviceStatus = [string]$service.Status
            latestHotfix = if ($latest) { [ordered]@{ id = $latest.HotFixID; installedOn = [string]$latest.InstalledOn } } else { $null }
        }
    } catch {
        return [ordered]@{ status = 'unknown'; summary = '无法读取 Windows Update 状态。'; error = $_.Exception.Message }
    }
}

function Get-BackupReport {
    if (-not $isAdmin) {
        return [ordered]@{ status = 'unknown'; summary = '需要管理员权限才能核验备份和系统还原点。'; requiresAdmin = $true }
    }
    try {
        $points = @(Get-ComputerRestorePoint -ErrorAction Stop)
        if ($points.Count -gt 0) {
            return [ordered]@{
                status = 'pass'
                summary = ('发现 {0} 个系统还原点。' -f $points.Count)
                restorePointCount = $points.Count
                requiresAdmin = $true
            }
        }
        return [ordered]@{ status = 'attention'; summary = '没有发现可用的系统还原点。'; restorePointCount = 0; requiresAdmin = $true }
    } catch {
        return [ordered]@{ status = 'unknown'; summary = '管理员权限下仍无法读取备份和还原点。'; error = $_.Exception.Message; requiresAdmin = $true }
    }
}

function Get-StorageHealthReport {
    try {
        $disks = @(Get-Disk)
        $healthy = @($disks | Where-Object { $_.HealthStatus -eq 'Healthy' })
        $status = if ($disks.Count -gt 0 -and $healthy.Count -eq $disks.Count) { 'pass' } else { 'attention' }
        return [ordered]@{
            status = $status
            summary = if ($status -eq 'pass') { '系统报告物理磁盘健康。' } else { '至少有一个物理磁盘需要进一步检查。' }
            disks = @($disks | ForEach-Object {
                [ordered]@{ number = $_.Number; name = $_.FriendlyName; health = [string]$_.HealthStatus; operational = [string]$_.OperationalStatus }
            })
        }
    } catch {
        return [ordered]@{ status = 'unknown'; summary = '无法读取物理磁盘健康状态。'; error = $_.Exception.Message }
    }
}

function Get-SystemReport {
    $os = $null
    try { $os = Get-CimInstance Win32_OperatingSystem -ErrorAction Stop } catch {}
    $lastBoot = if ($os) { $os.LastBootUpTime.ToUniversalTime().ToString('o') } else { $null }
    $uptimeHours = if ($os) { [math]::Round(((Get-Date).ToUniversalTime() - $os.LastBootUpTime.ToUniversalTime()).TotalHours, 1) } else { $null }
    $pendingReboot = $false
    try {
        $pendingReboot = (Test-Path 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Component Based Servicing\RebootPending') -or
            (Test-Path 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\WindowsUpdate\Auto Update\RebootRequired') -or
            (Get-ItemProperty 'HKLM:\SYSTEM\CurrentControlSet\Control\Session Manager' -Name PendingFileRenameOperations -ErrorAction SilentlyContinue)
    } catch {}
    $crashRoot = Join-Path $env:LOCALAPPDATA 'CrashDumps'
    $crashFiles = if (Test-Path -LiteralPath $crashRoot) { @(Get-ChildItem -LiteralPath $crashRoot -File -Force -ErrorAction SilentlyContinue) } else { @() }
    $criticalEvents = @()
    try {
        $criticalEvents = @(Get-WinEvent -FilterHashtable @{ LogName = 'System'; Level = 1; StartTime = (Get-Date).AddDays(-7) } -MaxEvents 100 -ErrorAction Stop)
    } catch {}
    return [ordered]@{
        isAdministrator = $isAdmin
        os = if ($os) { $os.Caption } else { '系统信息未核验' }
        version = if ($os) { $os.Version } else { $null }
        lastBoot = $lastBoot
        uptimeHours = $uptimeHours
        pendingReboot = [bool]$pendingReboot
        crashDumpCount = $crashFiles.Count
        crashDumpBytes = [long](($crashFiles | Measure-Object -Property Length -Sum).Sum)
        criticalSystemEventsLast7Days = $criticalEvents.Count
    }
}

$disks = @(Get-DiskReports)
$firewall = Get-FirewallReport
$antivirus = Get-AntivirusReport
$updates = Get-UpdateReport
$backup = Get-BackupReport
$storageHealth = Get-StorageHealthReport
$system = Get-SystemReport

$manifestPath = Join-Path $runtimeRoot 'data\pending-cleanup.json'
$manifest = $null
if (Test-Path -LiteralPath $manifestPath) {
    try { $manifest = Get-Content -LiteralPath $manifestPath -Raw -Encoding UTF8 | ConvertFrom-Json } catch {}
}
if ($null -eq $manifest) {
    $manifest = [pscustomobject]@{ candidateCount = 0; candidateBytes = 0; candidates = @(); topDirectories = @(); scanErrors = @() }
}

$checkRows = @()
foreach ($disk in $disks) {
    $checkRows += [ordered]@{
        id = ('storage.' + $disk.mountPoint.TrimEnd(':').ToLowerInvariant() + '.free-space')
        category = 'storage'
        status = $disk.status
        title = ($disk.mountPoint + ' 空间')
        summary = if ($disk.status -eq 'pass') { '可用空间已达到 20% 健康线。' } else { '可用空间尚未达到 20% 健康线。' }
        evidence = @(
            ('剩余 {0} / {1}' -f (Format-ProtectBytes $disk.freeBytes), (Format-ProtectBytes $disk.totalBytes)),
            ('可用率 {0}%' -f $disk.freePercent)
        )
        checkedAt = $generatedAt
    }
}
$checkRows += [ordered]@{ id = 'security.firewall'; category = 'protection'; status = $firewall.status; title = '防火墙'; summary = $firewall.summary; evidence = @($firewall.profiles | ForEach-Object { ('{0}: {1}' -f $_.name, $_.enabled) }); checkedAt = $generatedAt }
$checkRows += [ordered]@{ id = 'security.antivirus'; category = 'protection'; status = $antivirus.status; title = '常驻杀毒'; summary = $antivirus.summary; evidence = @('策略：' + $antivirus.policy, ('Defender 实时防护：' + $antivirus.defenderRealtime)); checkedAt = $generatedAt }
$checkRows += [ordered]@{ id = 'system.updates'; category = 'reliability'; status = $updates.status; title = '系统更新'; summary = $updates.summary; evidence = @('Windows Update 服务：' + $updates.serviceStatus); checkedAt = $generatedAt }
$checkRows += [ordered]@{ id = 'system.backup'; category = 'reliability'; status = $backup.status; title = '备份与还原点'; summary = $backup.summary; evidence = @('管理员权限：' + $isAdmin); checkedAt = $generatedAt }
$checkRows += [ordered]@{ id = 'storage.physical-health'; category = 'storage'; status = $storageHealth.status; title = '物理硬盘'; summary = $storageHealth.summary; evidence = @($storageHealth.disks | ForEach-Object { ('磁盘 {0}: {1}' -f $_.number, $_.health) }); checkedAt = $generatedAt }

$statusValues = @($checkRows | ForEach-Object { $_.status })
$overallStatus = if ($statusValues -contains 'critical') { 'critical' } elseif ($statusValues -contains 'attention' -or $statusValues -contains 'unknown') { 'attention' } else { 'pass' }
$reasons = @($checkRows | Where-Object { $_.status -ne 'pass' } | Select-Object -First 5 | ForEach-Object { $_.summary })
$overallSummary = switch ($overallStatus) {
    'critical' { '有需要立即处理的空间或系统问题。请先查看优先事项和清理清单。' }
    'attention' { '电脑可以继续使用，但有几项需要你查看或按需处理。' }
    default { '关键检查均已通过，可以继续保持定期检查。' }
}

$previousIndexPath = Join-Path $runtimeRoot 'data\report-index.json'
$history = @()
if (Test-Path -LiteralPath $previousIndexPath) {
    try { $history = @(Get-Content -LiteralPath $previousIndexPath -Raw -Encoding UTF8 | ConvertFrom-Json) } catch { $history = @() }
}
$historyEntry = [ordered]@{
    runId = $RunId
    date = (Get-Date).ToString('yyyy-MM-dd')
    disks = [ordered]@{}
    overall = $overallStatus
}
foreach ($disk in $disks) { $historyEntry.disks[$disk.mountPoint] = $disk.freePercent }
$history = @($history + [pscustomobject]$historyEntry)
if ($history.Count -gt 90) { $history = @($history | Select-Object -Last 90) }

$report = [ordered]@{
    schemaVersion = 1
    demo = $false
    runId = $RunId
    generatedAt = $generatedAt
    host = [ordered]@{
        computerName = $env:COMPUTERNAME
        os = $system.os
        lastBoot = $system.lastBoot
        uptimeHours = $system.uptimeHours
    }
    overall = [ordered]@{
        status = $overallStatus
        label = Get-ProtectStatusLabel -Status $overallStatus
        summary = $overallSummary
        reasons = $reasons
    }
    disks = $disks
    cleanup = [ordered]@{
        candidateCount = [int]$manifest.candidateCount
        candidateBytes = [long]$manifest.candidateBytes
        approvedCount = 0
        approvedBytes = 0
        status = if ([int]$manifest.candidateCount -gt 0) { 'awaiting-review' } else { 'empty' }
        categories = @($manifest.candidates | Group-Object category | ForEach-Object {
            [ordered]@{
                name = $_.Name
                count = $_.Count
                bytes = [long](($_.Group | Measure-Object -Property bytes -Sum).Sum)
            }
        })
    }
    protection = [ordered]@{
        firewall = $firewall
        antivirus = $antivirus
        updates = $updates
        backup = $backup
        storageHealth = $storageHealth
    }
    system = $system
    checks = $checkRows
    history = $history
}

Write-ProtectJson -Object $report -Path (Join-Path $runRoot 'status.json')
Write-ProtectJson -Object $report -Path (Join-Path $runtimeRoot 'data\latest-status.json')
Write-ProtectBrowserScript -Object $report -Path (Join-Path $runtimeRoot 'data\latest-status.js') -VariableName 'PROTECT_RUNTIME_STATUS'
Write-ProtectJson -Object $history -Path $previousIndexPath
Write-ProtectBrowserScript -Object ([ordered]@{ entries = $history }) -Path (Join-Path $runtimeRoot 'data\report-index.js') -VariableName 'PROTECT_RUNTIME_HISTORY'

Write-Output ('STATUS_RUN_ID={0}' -f $RunId)
Write-Output ('OVERALL_STATUS={0}' -f $overallStatus)
Write-Output ('DISK_COUNT={0}' -f $disks.Count)
Write-Output ('CANDIDATE_COUNT={0}' -f $manifest.candidateCount)
