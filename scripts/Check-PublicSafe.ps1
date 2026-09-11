#requires -Version 5.1

[CmdletBinding()]
param(
    [string]$ProjectRoot = (Split-Path -Parent $PSScriptRoot),
    [switch]$History
)

$ErrorActionPreference = 'Stop'
$ProjectRoot = [System.IO.Path]::GetFullPath($ProjectRoot)

function Invoke-ProtectGitLines {
    param([Parameter(Mandatory = $true)][string[]]$Arguments)

    $lines = @(& git -C $ProjectRoot @Arguments 2>$null | ForEach-Object { [string]$_ })
    if ($LASTEXITCODE -ne 0) { throw ('Git 命令失败：{0}' -f ($Arguments -join ' ')) }
    return $lines
}

function Normalize-ProtectRepoPath {
    param([Parameter(Mandatory = $true)][string]$Path)
    return ($Path -replace '\\', '/')
}

function Test-ProtectAllowedPath {
    param([Parameter(Mandatory = $true)][string]$Path)

    $normalized = Normalize-ProtectRepoPath -Path $Path
    $exact = @(
        'PRODUCT.md', 'DESIGN.md', 'README.md', 'PRIVACY.md', 'LICENSE', '.gitignore', '.gitattributes',
        '.editorconfig', 'Setup.ps1', 'Start-Maintenance.cmd', 'Apply-Approved-Cleanup.cmd', 'Open-Dashboard.cmd',
        'index.html', 'styles.css', 'app.js'
    )
    if ($exact -contains $normalized) { return $true }
    if ($normalized -match '^scripts/[^/]+\.ps1$') { return $true }
    if ($normalized -match '^scripts/[^/]+\.cmd$') { return $true }
    if ($normalized -match '^sample/[^/]+\.js$') { return $true }
    if ($normalized -match '^docs/[^/]+\.md$') { return $true }
    if ($normalized -match '^\.github/workflows/[^/]+\.(yml|yaml)$') { return $true }
    if ($normalized -match '^\.githooks/[^/]+$') { return $true }
    return $false
}

function Test-ProtectTextPath {
    param([Parameter(Mandatory = $true)][string]$Path)

    $normalized = Normalize-ProtectRepoPath -Path $Path
    if ($normalized -in @('.gitignore', '.gitattributes', '.editorconfig', 'LICENSE')) { return $true }
    return [System.IO.Path]::GetExtension($normalized).ToLowerInvariant() -in @('.md', '.txt', '.js', '.html', '.css', '.ps1', '.cmd', '.yml', '.yaml', '.json')
}

$findings = New-Object System.Collections.Generic.List[object]
$findingKeys = @{}
function Add-ProtectFinding {
    param(
        [Parameter(Mandatory = $true)][string]$Kind,
        [Parameter(Mandatory = $true)][string]$Path,
        [string]$Commit = 'worktree'
    )

    $normalized = Normalize-ProtectRepoPath -Path $Path
    $key = '{0}|{1}|{2}' -f $Kind, $Commit, $normalized
    if ($findingKeys.ContainsKey($key)) { return }
    $findingKeys[$key] = $true
    $findings.Add([pscustomobject]@{ kind = $Kind; path = $normalized; commit = $Commit }) | Out-Null
}

$patterns = [ordered]@{
    'private-key' = '-----BEGIN (RSA |EC |OPENSSH |DSA )?PRIVATE KEY-----'
    'github-token' = '(?i)\b(?:ghp|gho|ghs|ghu|ghr)_[A-Za-z0-9_]{20,}\b|\bgithub_pat_[A-Za-z0-9_]{20,}\b'
    'cloud-key' = '\bAKIA[0-9A-Z]{16}\b'
    'jwt' = '\beyJ[A-Za-z0-9_-]{10,}\.[A-Za-z0-9_-]{10,}\.[A-Za-z0-9_-]{10,}\b'
    'secret-assignment' = '(?im)\b(?:password|passwd|secret|client_secret|access_token|refresh_token|api[_-]?key)\b\s*[:=]\s*["''][^"'']{8,}["'']'
}
$userProfile = [Environment]::GetFolderPath('UserProfile')
if ($userProfile) {
    $patterns['current-user-path'] = [regex]::Escape($userProfile.TrimEnd('\', '/'))
}
if ($env:USERNAME) {
    $patterns['current-user-name'] = '(?i)(?<![A-Za-z0-9_<-])' + [regex]::Escape($env:USERNAME) + '(?![A-Za-z0-9_>-])'
}

if (-not (Test-Path -LiteralPath (Join-Path $ProjectRoot '.git'))) {
    throw '当前目录不是 Git 仓库。'
}

$worktreePaths = @((Invoke-ProtectGitLines -Arguments @('ls-files', '--cached')) + (Invoke-ProtectGitLines -Arguments @('ls-files', '--others', '--exclude-standard')) | Sort-Object -Unique)
foreach ($path in $worktreePaths) {
    if (-not (Test-ProtectAllowedPath -Path $path)) {
        Add-ProtectFinding -Kind 'unapproved-path' -Path $path
        continue
    }
    if ((Test-ProtectTextPath -Path $path) -and (Normalize-ProtectRepoPath -Path $path) -ne 'scripts/Check-PublicSafe.ps1') {
        $fullPath = Join-Path $ProjectRoot ($path -replace '/', '\')
        try {
            $text = Get-Content -LiteralPath $fullPath -Raw -Encoding UTF8 -ErrorAction Stop
            foreach ($pattern in $patterns.GetEnumerator()) {
                if ($text -match $pattern.Value) {
                    Add-ProtectFinding -Kind $pattern.Key -Path $path
                }
            }
        } catch {
            Add-ProtectFinding -Kind 'unreadable-file' -Path $path
        }
    }
}

foreach ($line in (Invoke-ProtectGitLines -Arguments @('ls-files', '--stage'))) {
    if ($line -match '^120000\s') {
        $symlinkPath = ($line -split "`t", 2)[-1]
        Add-ProtectFinding -Kind 'symlink' -Path $symlinkPath
    }
}

if ($History) {
    $commits = @(Invoke-ProtectGitLines -Arguments @('rev-list', '--all'))
    foreach ($commit in $commits) {
        $historyPaths = @(Invoke-ProtectGitLines -Arguments @('ls-tree', '-r', '--name-only', $commit))
        foreach ($path in $historyPaths) {
            if (-not (Test-ProtectAllowedPath -Path $path)) {
                Add-ProtectFinding -Kind 'unapproved-history-path' -Path $path -Commit $commit.Substring(0, [Math]::Min(12, $commit.Length))
                continue
            }
            if ((Test-ProtectTextPath -Path $path) -and (Normalize-ProtectRepoPath -Path $path) -ne 'scripts/Check-PublicSafe.ps1') {
                $object = '{0}:{1}' -f $commit, $path
                $historyText = @(& git -C $ProjectRoot show $object 2>$null | ForEach-Object { [string]$_ }) -join [Environment]::NewLine
                if ($LASTEXITCODE -ne 0) {
                    Add-ProtectFinding -Kind 'unreadable-history-file' -Path $path -Commit $commit.Substring(0, [Math]::Min(12, $commit.Length))
                    continue
                }
                foreach ($pattern in $patterns.GetEnumerator()) {
                    if ($historyText -match $pattern.Value) {
                        Add-ProtectFinding -Kind $pattern.Key -Path $path -Commit $commit.Substring(0, [Math]::Min(12, $commit.Length))
                    }
                }
            }
        }
    }
}

if ($findings.Count -gt 0) {
    Write-Output 'PUBLIC_SAFE=BLOCKED'
    foreach ($finding in $findings) {
        Write-Output ('FINDING kind={0} path={1} commit={2}' -f $finding.kind, $finding.path, $finding.commit)
    }
    exit 1
}

Write-Output 'PUBLIC_SAFE=PASS'
