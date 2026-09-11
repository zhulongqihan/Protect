#requires -Version 5.1

Set-StrictMode -Version Latest

function Get-ProtectProjectRoot {
    return (Split-Path -Parent $PSScriptRoot)
}

function Get-ProtectRuntimeRoot {
    param([string]$ProjectRoot = (Get-ProtectProjectRoot))
    return (Join-Path $ProjectRoot 'runtime')
}

function Initialize-ProtectRuntime {
    param([string]$ProjectRoot = (Get-ProtectProjectRoot))

    $runtimeRoot = Get-ProtectRuntimeRoot -ProjectRoot $ProjectRoot
    $directories = @(
        $runtimeRoot,
        (Join-Path $runtimeRoot 'reports'),
        (Join-Path $runtimeRoot 'approvals'),
        (Join-Path $runtimeRoot 'data')
    )
    foreach ($directory in $directories) {
        New-Item -ItemType Directory -Force -Path $directory | Out-Null
    }
    return $runtimeRoot
}

function Write-ProtectUtf8Text {
    param(
        [Parameter(Mandatory = $true)][string]$Path,
        [Parameter(Mandatory = $true)][string]$Text
    )

    $parent = Split-Path -Parent $Path
    if ($parent) {
        New-Item -ItemType Directory -Force -Path $parent | Out-Null
    }
    $encoding = New-Object System.Text.UTF8Encoding($false)
    [System.IO.File]::WriteAllText($Path, $Text, $encoding)
}

function Write-ProtectJson {
    param(
        [Parameter(Mandatory = $true)]$Object,
        [Parameter(Mandatory = $true)][string]$Path
    )

    $json = $Object | ConvertTo-Json -Depth 20
    Write-ProtectUtf8Text -Path $Path -Text $json
}

function Write-ProtectBrowserScript {
    param(
        [Parameter(Mandatory = $true)]$Object,
        [Parameter(Mandatory = $true)][string]$Path,
        [Parameter(Mandatory = $true)][string]$VariableName
    )

    $json = $Object | ConvertTo-Json -Depth 20 -Compress
    Write-ProtectUtf8Text -Path $Path -Text ("window.{0} = {1};" -f $VariableName, $json)
}

function Test-ProtectAdministrator {
    $identity = [Security.Principal.WindowsIdentity]::GetCurrent()
    $principal = New-Object Security.Principal.WindowsPrincipal($identity)
    return $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
}

function Format-ProtectBytes {
    param([long]$Bytes)

    if ($Bytes -lt 1KB) { return ('{0} B' -f $Bytes) }
    if ($Bytes -lt 1MB) { return ('{0:N1} KB' -f ($Bytes / 1KB)) }
    if ($Bytes -lt 1GB) { return ('{0:N1} MB' -f ($Bytes / 1MB)) }
    if ($Bytes -lt 1TB) { return ('{0:N1} GB' -f ($Bytes / 1GB)) }
    return ('{0:N2} TB' -f ($Bytes / 1TB))
}

function Get-ProtectSpaceStatus {
    param([double]$FreePercent)

    if ($FreePercent -lt 10) { return 'critical' }
    if ($FreePercent -lt 20) { return 'attention' }
    return 'pass'
}

function Get-ProtectStatusLabel {
    param([string]$Status)

    switch ($Status) {
        'pass' { return '正常' }
        'attention' { return '需要关注' }
        'critical' { return '立即处理' }
        default { return '未核验' }
    }
}

function Get-ProtectFingerprint {
    param([Parameter(Mandatory = $true)][string]$Path)

    try {
        $item = Get-Item -LiteralPath $Path -Force -ErrorAction Stop
        if ($item.PSIsContainer) {
            $files = @(Get-ChildItem -LiteralPath $Path -File -Force -Recurse -ErrorAction SilentlyContinue)
            $latest = $files | Sort-Object LastWriteTimeUtc -Descending | Select-Object -First 1
            $bytes = ($files | Measure-Object -Property Length -Sum).Sum
            if ($null -eq $bytes) { $bytes = 0 }
            return [ordered]@{
                kind = 'directory'
                fileCount = $files.Count
                bytes = [long]$bytes
                latestWriteUtc = if ($latest) { $latest.LastWriteTimeUtc.ToString('o') } else { $null }
            }
        }
        return [ordered]@{
            kind = 'file'
            bytes = [long]$item.Length
            lastWriteUtc = $item.LastWriteTimeUtc.ToString('o')
        }
    } catch {
        return [ordered]@{
            kind = 'unavailable'
            error = $_.Exception.Message
        }
    }
}

function Get-ProtectCandidateId {
    param(
        [Parameter(Mandatory = $true)][string]$Path,
        [Parameter(Mandatory = $true)][long]$Bytes,
        [Parameter(Mandatory = $true)][string]$LastWriteUtc
    )

    $text = '{0}|{1}|{2}' -f $Path.ToLowerInvariant(), $Bytes, $LastWriteUtc
    $sha = [Security.Cryptography.SHA256]::Create()
    try {
        $hash = $sha.ComputeHash([Text.Encoding]::UTF8.GetBytes($text))
        return ([BitConverter]::ToString($hash)).Replace('-', '').ToLowerInvariant().Substring(0, 20)
    } finally {
        $sha.Dispose()
    }
}

function Get-ProtectProtectedPathReason {
    param([Parameter(Mandatory = $true)][string]$Path)

    $fullPath = [System.IO.Path]::GetFullPath($Path).TrimEnd('\')
    $programFilesX86 = [Environment]::GetEnvironmentVariable('ProgramFiles(x86)')
    $systemRoots = @(
        $env:windir,
        $env:ProgramFiles,
        $programFilesX86,
        $env:ProgramData
    ) | Where-Object { $_ } | ForEach-Object { $_.TrimEnd('\') }

    foreach ($root in $systemRoots) {
        if ($fullPath.Equals($root, [StringComparison]::OrdinalIgnoreCase) -or
            $fullPath.StartsWith($root + '\', [StringComparison]::OrdinalIgnoreCase)) {
            return 'system-path'
        }
    }

    $segments = $fullPath -split '\\'
    $protectedNames = @(
        'System Volume Information',
        'Recovery',
        '$Recycle.Bin',
        'pagefile.sys',
        'swapfile.sys',
        'hiberfil.sys',
        '.ssh',
        '.aws',
        '.git',
        'NTUSER.DAT'
    )
    foreach ($segment in $segments) {
        if ($protectedNames -contains $segment) {
            return 'protected-name'
        }
    }
    return $null
}

function Get-ProtectPersonalPathReason {
    param([Parameter(Mandatory = $true)][string]$Path)

    try {
        $fullPath = [System.IO.Path]::GetFullPath($Path).TrimEnd('\')
        $profileRoot = [Environment]::GetFolderPath('UserProfile')
        if ($profileRoot) {
            $profileRoot = $profileRoot.TrimEnd('\')
        $personalFolders = @('Desktop', 'Documents', 'Downloads', 'Music', 'Pictures', 'Videos', 'OneDrive')
            foreach ($folder in $personalFolders) {
                $root = Join-Path $profileRoot $folder
                if ($fullPath.Equals($root, [StringComparison]::OrdinalIgnoreCase) -or
                    $fullPath.StartsWith($root + '\', [StringComparison]::OrdinalIgnoreCase)) {
                    return 'personal-folder'
                }
            }
        }

        $pathSegments = $fullPath -split '\\'
        if (@('Desktop', 'Documents', 'Downloads', 'Music', 'Pictures', 'Videos', 'OneDrive') | Where-Object { $pathSegments -contains $_ }) {
            return 'personal-folder'
        }

        $extension = [System.IO.Path]::GetExtension($fullPath).ToLowerInvariant()
        $personalExtensions = @(
            '.jpg', '.jpeg', '.png', '.gif', '.webp', '.heic', '.raw', '.tif', '.tiff',
            '.mp4', '.mov', '.mkv', '.avi', '.wmv', '.m4v',
            '.mp3', '.wav', '.flac', '.m4a',
            '.doc', '.docx', '.xls', '.xlsx', '.ppt', '.pptx', '.pdf', '.txt',
            '.zip', '.7z', '.rar'
        )
        if ($personalExtensions -contains $extension) { return 'personal-file-type' }
    } catch {}
    return $null
}

function Get-ProtectCategoryForPath {
    param(
        [Parameter(Mandatory = $true)][string]$Path,
        [Parameter(Mandatory = $true)][long]$Bytes,
        [Parameter(Mandatory = $true)][datetime]$LastWriteTime
    )

    $lower = $Path.ToLowerInvariant()
    $ageDays = ([DateTime]::UtcNow - $LastWriteTime.ToUniversalTime()).TotalDays
    if ($lower -match '\\(temp|crashdumps|d3dscache|npm-cache|pnpm-cache|\.pnpm-store|go-build)(\\|$)' -or
        $lower -match '\\(cache|caches)(\\|$)') {
        return [ordered]@{ category = 'cache'; risk = 'low'; action = 'permanent'; reversible = $false; reason = '缓存或可重新生成的数据，清理后应用可能需要重新生成。' }
    }
    if ($lower -match '\.(log|tmp|dmp|etl)$' -and $ageDays -ge 7) {
        return [ordered]@{ category = 'log'; risk = 'low'; action = 'permanent'; reversible = $false; reason = '超过 7 天的日志或诊断文件，需先确认没有正在排障。' }
    }
    if ($lower -match '\\(node_modules|target|__pycache__|\.gradle\\caches|build|dist)(\\|$)') {
        return [ordered]@{ category = 'build'; risk = 'medium'; action = 'review'; reversible = $true; reason = '可重新生成的构建产物，但可能是当前项目正在使用的依赖。' }
    }
    if ($Bytes -ge 500MB) {
        return [ordered]@{ category = 'large-file'; risk = 'high'; action = 'review'; reversible = $true; reason = '大文件，无法只凭路径判断是否可以删除。' }
    }
    return $null
}

function Get-ProtectFileRecords {
    param(
        [Parameter(Mandatory = $true)][string]$Root,
        [switch]$IncludeProtected
    )

    $errors = New-Object System.Collections.Generic.List[object]
    $stack = New-Object System.Collections.Generic.Stack[string]
    $stack.Push($Root)
    $seen = 0

    while ($stack.Count -gt 0) {
        $directory = $stack.Pop()
        try {
            $directoryInfo = New-Object System.IO.DirectoryInfo($directory)
            if (($directoryInfo.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) { continue }
            foreach ($file in $directoryInfo.EnumerateFiles('*', [IO.SearchOption]::TopDirectoryOnly)) {
                $seen += 1
                if (($file.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) { continue }
                $protectedReason = Get-ProtectProtectedPathReason -Path $file.FullName
                if ($protectedReason -and -not $IncludeProtected) { continue }
                [pscustomobject]@{
                    Path = $file.FullName
                    Bytes = [long]$file.Length
                    LastWriteTimeUtc = $file.LastWriteTimeUtc.ToString('o')
                    LastWriteTime = $file.LastWriteTime
                    ProtectedReason = $protectedReason
                    Seen = $seen
                }
            }
            foreach ($child in $directoryInfo.EnumerateDirectories('*', [IO.SearchOption]::TopDirectoryOnly)) {
                if (($child.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) { continue }
                if ($child.Name -in @('System Volume Information', 'Recovery')) { continue }
                $stack.Push($child.FullName)
            }
        } catch {
            $errors.Add([ordered]@{ path = $directory; message = $_.Exception.Message }) | Out-Null
        }
    }
    if ($errors.Count -gt 0) {
        Write-Verbose ('Skipped {0} inaccessible directories.' -f $errors.Count)
    }
}
