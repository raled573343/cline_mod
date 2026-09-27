#Requires -Version 5.1
<#
.SYNOPSIS
    Unofficial patcher that raises hard-coded truncation limits inside the installed
    Cline for VS Code extension bundle.

.DESCRIPTION
    Edits only numeric constants in <extension>\dist\extension.js, one exact-match anchor
    per change. Every anchor must occur exactly once in the bundle, otherwise nothing is
    written (fail closed). A timestamped backup of extension.js and package.json plus a
    patch-manifest.json (with before/after SHA-256) is always created before writing.

    Upstream context: cline/cline#13263 (issue), cline/cline#13693 (unmerged PR).
    This script is independent and unofficial, and is not affiliated with Cline.
    Upstream licence: Apache-2.0, Copyright 2026 Cline Bot Inc.
    See NOTICE-UPSTREAM.md and docs/limits-map.md.

.PARAMETER Report
    Default mode. Prints every anchor, its occurrence count and status. Writes nothing.

.PARAMETER Apply
    Applies the edits after creating a backup.

.PARAMETER ExtensionRoot
    Explicit extension folder (containing dist\extension.js). Auto-detected when omitted.

.PARAMETER ExpectedVersion
    Version the anchors were verified against. Default 4.1.21. Override with -Force.

.PARAMETER BackupRoot
    Where backups are written. Default: %USERPROFILE%\.cline-limits-patch\backup

.PARAMETER Force
    Skip the installed-version guard.

.EXAMPLE
    pwsh -File scripts/patch_cline_limits.ps1 -Report

.EXAMPLE
    pwsh -File scripts/patch_cline_limits.ps1 -Apply
#>
[CmdletBinding(DefaultParameterSetName = 'Report')]
param(
    [Parameter(ParameterSetName = 'Report')]
    [switch]$Report,

    [Parameter(ParameterSetName = 'Apply')]
    [switch]$Apply,

    [string]$ExtensionRoot,
    [string]$ExpectedVersion = '4.1.21',
    [string]$BackupRoot = (Join-Path $env:USERPROFILE '.cline-limits-patch\backup'),

    # Optional path to anchors/anchors.json. When omitted the script looks next to itself
    # (..\anchors\anchors.json) and falls back to the embedded 4.1.21 table.
    [string]$AnchorsPath,

    [switch]$Force
)

$ErrorActionPreference = 'Stop'

# --- the complete edit table -------------------------------------------------------
# Old = exact bytes present in the shipped bundle; New = replacement.
# Every Old anchor occurs exactly once in the verified 4.1.21 bundle.
$script:Edits = @(
    [pscustomobject]@{ Id = 1;  Area = 'run_commands output';    Old = 'e.maxChars??48e3'; New = 'e.maxChars??2e5' }
    [pscustomobject]@{ Id = 2;  Area = 'search output';          Old = 'WQt=48e3';         New = 'WQt=2e5' }
    [pscustomobject]@{ Id = 3;  Area = 'read output chars';      Old = 'nXo=48e3';         New = 'nXo=2e5' }
    [pscustomobject]@{ Id = 4;  Area = 'read max lines';         Old = 'QQt=2e3';          New = 'QQt=2e4' }
    [pscustomobject]@{ Id = 5;  Area = 'read per-line chars';    Old = 'jCn=2e3';          New = 'jCn=2e4' }
    [pscustomobject]@{ Id = 6;  Area = 'attached file content';  Old = 'function Xku(t,e=409600)'; New = 'function Xku(t,e=4e6)' }
    [pscustomobject]@{ Id = 7;  Area = 'web fetch slice';        Old = 'A.slice(0,5e4)';   New = 'A.slice(0,2e5)' }
    [pscustomobject]@{ Id = 8;  Area = 'web fetch length check'; Old = 'A.length>5e4&&';   New = 'A.length>2e5&&' }
    [pscustomobject]@{ Id = 9;  Area = 'web fetch notice text';  Old = 'showing first 50000 of'; New = 'showing first 200000 of' }
    [pscustomobject]@{ Id = 10; Area = 'editor payload guard';   Old = 'E0e=6e3';          New = 'E0e=1e5' }
    [pscustomobject]@{ Id = 11; Area = 'message builder caps';   Old = 'e5p=8e3,t5p=5e4,r5p=6e6,n5p=2e5,i5p=12e3,a5p=65536,jet=2e3,LVo=4e4,o5p=8'
                                                                 New = 'e5p=3e5,t5p=2e5,r5p=6e6,n5p=4e5,i5p=1e5,a5p=65536,jet=2e3,LVo=4e4,o5p=8' }
    [pscustomobject]@{ Id = 12; Area = 'sdk tool budgets';       Old = 'Suo=102400,Zfo=12e4,Wad=262144,OKe=102400,qad=2e3,Gad=200,Had=40,zad=5e4'
                                                                 New = 'Suo=5e5,Zfo=12e4,Wad=2e6,OKe=2e5,qad=2e4,Gad=2e3,Had=100,zad=2e5' }
)

# --- helpers -----------------------------------------------------------------------

function Get-NodeExe {
    $candidates = @()
    $cmd = Get-Command node -ErrorAction SilentlyContinue
    if ($cmd) { $candidates += $cmd.Source }
    $candidates += 'C:\Program Files\nodejs\node.exe'
    $candidates += 'C:\Program Files (x86)\nodejs\node.exe'
    foreach ($candidate in $candidates) {
        if ($candidate -and (Test-Path $candidate)) { return $candidate }
    }
    return $null
}

function Resolve-ClineExtension {
    param([string]$Explicit)

    if ($Explicit) {
        $root = (Resolve-Path -LiteralPath $Explicit).Path
        if (-not (Test-Path (Join-Path $root 'dist\extension.js'))) {
            throw "No dist\extension.js under '$root'."
        }
        return $root
    }

    $searchRoots = @(
        (Join-Path $env:USERPROFILE '.vscode\extensions'),
        (Join-Path $env:USERPROFILE '.cursor\extensions'),
        (Join-Path $env:USERPROFILE '.vscode-insiders\extensions')
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

function Get-AnchorState {
    param([string]$Text, [pscustomobject]$Edit)

    $oldCount = ([regex]::Matches($Text, [regex]::Escape($Edit.Old))).Count
    $newCount = ([regex]::Matches($Text, [regex]::Escape($Edit.New))).Count

    if ($oldCount -eq 1 -and $newCount -eq 0) { return 'READY' }
    if ($oldCount -eq 0 -and $newCount -eq 1) { return 'ALREADY_PATCHED' }
    if ($oldCount -eq 0 -and $newCount -eq 0) { return 'MISSING' }
    return ('AMBIGUOUS(old={0},new={1})' -f $oldCount, $newCount)
}

function Test-BundleSyntax {
    param([string]$BundlePath)

    $node = Get-NodeExe
    if (-not $node) {
        Write-Warning 'Node.js not found - syntax validation skipped.'
        return $false
    }
    # `node --check` is used instead of `node -e "<script>"` because Windows
    # PowerShell 5.1 mangles double quotes inside a native command argument.
    $out = & $node --check $BundlePath 2>&1
    if ($LASTEXITCODE -ne 0) {
        throw "Bundle failed syntax validation: $out"
    }
    Write-Host '  syntax validation: OK (node --check)' -ForegroundColor DarkGray
    return $true
}

# --- main --------------------------------------------------------------------------

$extensionRoot = Resolve-ClineExtension -Explicit $ExtensionRoot
$bundlePath    = Join-Path $extensionRoot 'dist\extension.js'
$manifestPath  = Join-Path $extensionRoot 'package.json'

$manifest = Get-Content -LiteralPath $manifestPath -Raw | ConvertFrom-Json
$version = $manifest.version

Write-Host ''
Write-Host 'Cline limits patch (unofficial)' -ForegroundColor Cyan
Write-Host ('  extension : {0}' -f $extensionRoot)
Write-Host ('  version   : {0}' -f $version)

if (-not $Force -and $version -ne $ExpectedVersion) {
    throw ("Installed version {0} differs from the verified version {1}. Inspect with -Report, re-verify the anchors, then use -Force only if you accept the risk." -f $version, $ExpectedVersion)
}

# --- anchor table -------------------------------------------------------------------
# anchors/anchors.json (produced by tools/cline-limits-tool.mjs) wins over the embedded
# table, so a new Cline version needs no change to this script.
$anchorsFile = $AnchorsPath
if (-not $anchorsFile) {
    $candidate = Join-Path (Split-Path -Parent $PSScriptRoot) 'anchors\anchors.json'
    if (Test-Path -LiteralPath $candidate) { $anchorsFile = $candidate }
}

$expectedBundleHash = $null
$anchorsNote = 'embedded table'
if ($anchorsFile -and (Test-Path -LiteralPath $anchorsFile)) {
    $anchors = Get-Content -LiteralPath $anchorsFile -Raw | ConvertFrom-Json
    $entry = $null
    if ($anchors.versions) {
        $prop = $anchors.versions.PSObject.Properties[$version]
        if ($prop) { $entry = $prop.Value }
    }
    if ($entry -and $entry.edits -and @($entry.edits).Count -gt 0) {
        $index = 0
        $script:Edits = @($entry.edits | ForEach-Object {
                $index += 1
                [pscustomobject]@{ Id = $index; Area = ('anchors[{0}]' -f $index); Old = $_.old; New = $_.new }
            })
        $expectedBundleHash = $entry.bundleSha256Before
        $anchorsNote = ('{0} ({1} edits, status {2})' -f (Split-Path -Leaf $anchorsFile), @($entry.edits).Count, $entry.status)
    } else {
        $anchorsNote = ('{0} has no entry for {1} - using embedded table' -f (Split-Path -Leaf $anchorsFile), $version)
    }
}

$bundleFile = Get-Item -LiteralPath $bundlePath
$beforeHash = (Get-FileHash -LiteralPath $bundlePath -Algorithm SHA256).Hash.ToLower()
Write-Host ('  bundle    : {0} bytes  sha256 {1}' -f $bundleFile.Length, $beforeHash)
Write-Host ('  anchors   : {0}' -f $anchorsNote)
Write-Host ''

$text = [IO.File]::ReadAllText($bundlePath)
$states = @()
foreach ($edit in $script:Edits) {
    $states += [pscustomobject]@{
        Id     = $edit.Id
        Area   = $edit.Area
        Status = (Get-AnchorState -Text $text -Edit $edit)
    }
}
$states | Format-Table -AutoSize | Out-String -Width 200 | Write-Host

$bad = @($states | Where-Object { $_.Status -ne 'READY' -and $_.Status -ne 'ALREADY_PATCHED' })
$patchedCount = @($states | Where-Object { $_.Status -eq 'ALREADY_PATCHED' }).Count
$allPatched = ($patchedCount -eq $script:Edits.Count)

if ($PSCmdlet.ParameterSetName -eq 'Report') {
    if ($allPatched) {
        Write-Host 'Status: already patched - nothing to do.' -ForegroundColor Yellow
    } elseif ($bad.Count -gt 0) {
        Write-Host 'Status: unusable anchors on this build - do NOT apply.' -ForegroundColor Red
    } else {
        Write-Host 'Status: ready - re-run with -Apply.' -ForegroundColor Green
    }
    return
}

if ($allPatched) {
    Write-Host 'Already patched - nothing to do.' -ForegroundColor Yellow
    return
}
if ($bad.Count -gt 0) {
    $detail = ($bad | ForEach-Object { '#{0} {1}' -f $_.Id, $_.Status }) -join ', '
    throw "Refusing to write: unusable anchors -> $detail"
}
if ($bundleFile.IsReadOnly) {
    throw "Bundle file is read-only: $bundlePath"
}
if ($expectedBundleHash -and $expectedBundleHash -ne $beforeHash) {
    Write-Warning (('Bundle hash {0} differs from the recorded pre-patch hash {1} for version {2}; the anchors may not match this exact build.' -f $beforeHash, $expectedBundleHash, $version))
}

$stamp  = Get-Date -Format 'yyyyMMdd-HHmmss'
$backup = Join-Path $BackupRoot $stamp
New-Item -ItemType Directory -Path $backup -Force | Out-Null
Copy-Item -LiteralPath $bundlePath -Destination (Join-Path $backup 'extension.js') -Force
Copy-Item -LiteralPath $manifestPath -Destination (Join-Path $backup 'package.json') -Force

$patched = $text
foreach ($edit in $script:Edits) { $patched = $patched.Replace($edit.Old, $edit.New) }

$utf8NoBom = New-Object System.Text.UTF8Encoding($false)

# Validate the patched text as a file *before* the live bundle is touched, so a
# failure leaves the installed extension untouched.
$staged = Join-Path $backup 'extension.patched.js'
[IO.File]::WriteAllText($staged, $patched, $utf8NoBom)
Test-BundleSyntax -BundlePath $staged | Out-Null

[IO.File]::WriteAllText($bundlePath, $patched, $utf8NoBom)

$afterHash = (Get-FileHash -LiteralPath $bundlePath -Algorithm SHA256).Hash.ToLower()
$record = [pscustomobject]@{
    patchedAtUtc       = (Get-Date).ToUniversalTime().ToString('o')
    extensionRoot      = $extensionRoot
    extensionVersion   = $version
    bundlePath         = $bundlePath
    bundleBytesBefore  = $bundleFile.Length
    bundleSha256Before = $beforeHash
    bundleSha256After  = $afterHash
    nodeExe            = (Get-NodeExe)
    anchorsFile        = $anchorsFile
    expectedBundleHash = $expectedBundleHash
    edits              = @($script:Edits | ForEach-Object {
            [pscustomobject]@{ id = $_.Id; area = $_.Area; old = $_.Old; new = $_.New }
        })
}
$record | ConvertTo-Json -Depth 5 | Set-Content -LiteralPath (Join-Path $backup 'patch-manifest.json') -Encoding UTF8

Write-Host ''
Write-Host 'Patched.' -ForegroundColor Green
Write-Host ('  backup : {0}' -f $backup)
Write-Host ('  sha256 : {0} -> {1}' -f $beforeHash, $afterHash)
Write-Host ''
Write-Host 'Next: in VS Code run "Developer: Reload Window".' -ForegroundColor Cyan


