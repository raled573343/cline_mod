#Requires -Version 5.1
<#
.SYNOPSIS
    Restores the Cline extension bundle from a backup created by patch_cline_limits.ps1.

.DESCRIPTION
    Default action restores the newest backup (or the one given via -BackupDir) and
    verifies the restored file against the SHA-256 recorded in patch-manifest.json.
    -List only reports available backups. -ReinstallOfficialVsix re-installs the official
    release package instead of copying files, which is the strongest reset.

.EXAMPLE
    pwsh -File scripts/revert_cline_limits.ps1 -List

.EXAMPLE
    pwsh -File scripts/revert_cline_limits.ps1

.EXAMPLE
    pwsh -File scripts/revert_cline_limits.ps1 -ReinstallOfficialVsix -VsixPath .\cline-4.1.21.vsix
#>
[CmdletBinding(DefaultParameterSetName = 'Restore')]
param(
    [Parameter(ParameterSetName = 'List')]
    [switch]$List,

    [Parameter(ParameterSetName = 'Restore')]
    [string]$BackupDir,

    [Parameter(ParameterSetName = 'Official')]
    [switch]$ReinstallOfficialVsix,

    [Parameter(ParameterSetName = 'Official')]
    [string]$VsixPath,

    [string]$BackupRoot = (Join-Path $HOME '.cline-limits-patch/backup'),
    [string]$ExtensionRoot
)

$ErrorActionPreference = 'Stop'

function Get-BackupRecords {
    param([string]$Root)

    if (-not (Test-Path $Root)) { return @() }
    $records = @()
    foreach ($dir in (Get-ChildItem -LiteralPath $Root -Directory -ErrorAction SilentlyContinue | Sort-Object Name -Descending)) {
        $manifestPath = Join-Path $dir.FullName 'patch-manifest.json'
        $manifest = $null
        if (Test-Path $manifestPath) {
            try { $manifest = Get-Content -LiteralPath $manifestPath -Raw | ConvertFrom-Json } catch { $manifest = $null }
        }
        $records += [pscustomobject]@{
            Name       = $dir.Name
            Path       = $dir.FullName
            Version    = if ($manifest) { $manifest.extensionVersion } else { 'unknown' }
            BeforeHash = if ($manifest) { $manifest.bundleSha256Before } else { 'unknown' }
            HasManifest = [bool]$manifest
        }
    }
    return $records
}

function Show-Backups {
    param([string]$Root)

    $records = @(Get-BackupRecords -Root $Root)
    if ($records.Count -eq 0) {
        Write-Host ("No backups under {0}" -f $Root) -ForegroundColor Yellow
        return $records
    }
    Write-Host ("Backups under {0}" -f $Root) -ForegroundColor Cyan
    $records | Select-Object Name, Version, BeforeHash | Format-Table -AutoSize | Out-String -Width 200 | Write-Host
    return $records
}

function Resolve-InstalledClineExtension {
    $userHome = $HOME
    $searchRoots = @(
        (Join-Path $userHome '.vscode/extensions'),
        (Join-Path $userHome '.cursor/extensions'),
        (Join-Path $userHome '.vscode-insiders/extensions')
    )
    $found = @()
    foreach ($r in $searchRoots) {
        if (Test-Path $r) {
            $found += @(Get-ChildItem -LiteralPath $r -Directory -Filter 'saoudrizwan.claude-dev-*' -ErrorAction SilentlyContinue)
        }
    }
    if ($found.Count -eq 0) {
        throw 'Cline extension folder not found. Pass -ExtensionRoot explicitly.'
    }
    $sorted = $found | Sort-Object -Property @{
        Expression = {
            $v = $_.Name -replace '^saoudrizwan\.claude-dev-', ''
            try { [version]$v } catch { [version]'0.0.0' }
        }
        Descending = $true
    }
    return $sorted[0].FullName
}

if ($List) {
    Show-Backups -Root $BackupRoot | Out-Null
    return
}

if ($PSCmdlet.ParameterSetName -eq 'Official') {
    if (-not $VsixPath) { throw 'Pass -VsixPath <path to cline-<version>.vsix>.' }
    $vsix = (Resolve-Path -LiteralPath $VsixPath).Path
    $codeCandidates = @(
        (Join-Path $env:LOCALAPPDATA 'Programs\Microsoft VS Code\bin\code.cmd'),
        (Join-Path $env:ProgramFiles 'Microsoft VS Code\bin\code.cmd')
    )
    $code = $codeCandidates | Where-Object { Test-Path $_ } | Select-Object -First 1
    if (-not $code) { throw 'VS Code CLI (code.cmd) not found. Install the VSIX manually via VS Code.' }

    Write-Host ("Re-installing official build: {0}" -f $vsix) -ForegroundColor Cyan
    & $code --install-extension $vsix --force
    if ($LASTEXITCODE -ne 0) { throw "code --install-extension failed with exit code $LASTEXITCODE" }
    Write-Host 'Done. Reload the VS Code window.' -ForegroundColor Green
    return
}

$records = @(Get-BackupRecords -Root $BackupRoot)
if ($BackupDir) {
    $target = (Resolve-Path -LiteralPath $BackupDir).Path
} else {
    if ($records.Count -eq 0) { throw ("No backups under {0}. Use -ReinstallOfficialVsix to reset from the official build." -f $BackupRoot) }
    $target = $records[0].Path
}

$manifestPath = Join-Path $target 'patch-manifest.json'
$targetManifest = $null
if (Test-Path $manifestPath) {
    $targetManifest = Get-Content -LiteralPath $manifestPath -Raw | ConvertFrom-Json
}

if ($ExtensionRoot) {
    $root = (Resolve-Path -LiteralPath $ExtensionRoot).Path
} elseif ($targetManifest -and $targetManifest.extensionRoot) {
    $root = $targetManifest.extensionRoot
} else {
    $root = Resolve-InstalledClineExtension
    Write-Warning ("Backup has no manifest - using detected extension folder: {0}" -f $root)
}

$bundlePath = Join-Path $root 'dist\extension.js'
if (-not (Test-Path $bundlePath)) { throw "No bundle at $bundlePath" }

$currentHash = (Get-FileHash -LiteralPath $bundlePath -Algorithm SHA256).Hash.ToLower()
if ($targetManifest -and $targetManifest.bundleSha256After -and $currentHash -ne $targetManifest.bundleSha256After) {
    Write-Warning ("Current bundle hash ({0}) differs from the recorded patched hash ({1})." -f $currentHash, $targetManifest.bundleSha256After)
}

Copy-Item -LiteralPath (Join-Path $target 'extension.js') -Destination $bundlePath -Force
$packageBackup = Join-Path $target 'package.json'
if (Test-Path $packageBackup) {
    Copy-Item -LiteralPath $packageBackup -Destination (Join-Path $root 'package.json') -Force
}

$restoredHash = (Get-FileHash -LiteralPath $bundlePath -Algorithm SHA256).Hash.ToLower()
Write-Host ''
Write-Host 'Restored.' -ForegroundColor Green
Write-Host ('  from   : {0}' -f $target)
Write-Host ('  sha256 : {0}' -f $restoredHash)

if ($targetManifest -and $targetManifest.bundleSha256Before) {
    if ($restoredHash -eq $targetManifest.bundleSha256Before) {
        Write-Host '  verified against manifest: OK' -ForegroundColor Green
    } else {
        Write-Warning ("Restored hash does not match the recorded pre-patch hash ({0})." -f $targetManifest.bundleSha256Before)
    }
} else {
    Write-Warning 'No manifest in this backup; hash was not verified.'
}

Write-Host ''
Write-Host 'Next: in VS Code run "Developer: Reload Window".' -ForegroundColor Cyan
