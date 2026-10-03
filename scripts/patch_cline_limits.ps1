#Requires -Version 5.1
<#
.SYNOPSIS
    Self-contained unofficial patcher for Cline VS Code truncation limits.

.DESCRIPTION
    Normal usage needs exactly this one file. With no switches the script:
      1. finds the installed Cline extension;
      2. prints a safety report;
      3. asks whether to apply only when the build is exactly supported.

    -Report is read-only and non-interactive.
    -Apply is non-interactive and applies only after all safety checks pass.

    The release workflow embeds the exact anchor table and expected clean/patched
    SHA-256 for the supported Cline build directly into this script.

.EXAMPLE
    .\patch_cline_limits.ps1

.EXAMPLE
    powershell -ExecutionPolicy Bypass -File .\patch_cline_limits.ps1

.EXAMPLE
    .\patch_cline_limits.ps1 -Report

.EXAMPLE
    .\patch_cline_limits.ps1 -Apply
#>
[CmdletBinding()]
param(
    [switch]$Report,
    [switch]$Apply,
    [string]$ExtensionRoot,
    [string]$BackupRoot = (Join-Path $HOME '.cline-limits-patch/backup')
)

$ErrorActionPreference = 'Stop'

# BEGIN EMBEDDED_ANCHORS
$script:EmbeddedAnchorsJson = @'
{
  "schema": "cline-mod-standalone-v1",
  "versions": {
    "4.1.21": {
      "status": "AUTO",
      "bundleSha256Before": "0035a6327275fd3f750ae7cbabf944f2d31f6f36f53a37a808eff7b0421e2121",
      "bundleSha256After": "db84361b262e38720ca488377aaedf60ecbaaa83db03b62136f9c556e1ca3316",
      "edits": [
        {"old":"maxChars??48e3","new":"maxChars??200000"},
        {"old":"WQt=48e3","new":"WQt=200000"},
        {"old":"nXo=48e3","new":"nXo=200000"},
        {"old":"QQt=2e3","new":"QQt=20000"},
        {"old":"jCn=2e3","new":"jCn=20000"},
        {"old":",e=409600){if(t.length<=e)return t","new":",e=4000000){if(t.length<=e)return t"},
        {"old":"slice(0,5e4)","new":"slice(0,200000)"},
        {"old":"A.length>5e4&&","new":"A.length>200000&&"},
        {"old":"showing first 50000 of","new":"showing first 200000 of"},
        {"old":"E0e=6e3","new":"E0e=100000"},
        {"old":"e5p=8e3","new":"e5p=300000"},
        {"old":"t5p=5e4","new":"t5p=200000"},
        {"old":"n5p=2e5","new":"n5p=400000"},
        {"old":"i5p=12e3","new":"i5p=100000"},
        {"old":"Suo=102400,","new":"Suo=500000,"},
        {"old":"Wad=262144,","new":"Wad=2000000,"},
        {"old":"OKe=102400,","new":"OKe=200000,"},
        {"old":"qad=2e3,","new":"qad=20000,"},
        {"old":"Gad=200,","new":"Gad=2000,"},
        {"old":"Had=40,","new":"Had=100,"},
        {"old":"zad=5e4","new":"zad=200000"}
      ]
    },
    "4.1.22": {
      "status": "AUTO",
      "bundleSha256Before": "369bfc6bd01de72d26013ed6ebac2c7c9cb5a564bb8ff14679d6a1ba2ab76178",
      "bundleSha256After": "804f1902e95904934e64f9b43386aac8fc4c080d391ac36eee6a7a95b02f873e",
      "edits": [
        {"old":"maxChars??48e3","new":"maxChars??200000"},
        {"old":"sNt=48e3","new":"sNt=200000"},
        {"old":"u5o=48e3","new":"u5o=200000"},
        {"old":"oNt=2e3","new":"oNt=20000"},
        {"old":"uhn=2e3","new":"uhn=20000"},
        {"old":",e=409600){if(t.length<=e)return t","new":",e=4000000){if(t.length<=e)return t"},
        {"old":"slice(0,5e4)","new":"slice(0,200000)"},
        {"old":"A.length>5e4&&","new":"A.length>200000&&"},
        {"old":"showing first 50000 of","new":"showing first 200000 of"},
        {"old":"Hhe=6e3","new":"Hhe=100000"},
        {"old":"fAp=8e3","new":"fAp=300000"},
        {"old":"hAp=5e4","new":"hAp=200000"},
        {"old":"gAp=2e5","new":"gAp=400000"},
        {"old":"AAp=12e3","new":"AAp=100000"},
        {"old":"tVa=102400,","new":"tVa=500000,"},
        {"old":"YUc=262144,","new":"YUc=2000000,"},
        {"old":"lVe=102400,","new":"lVe=200000,"},
        {"old":"XUc=2e3,","new":"XUc=20000,"},
        {"old":"ZUc=200,","new":"ZUc=2000,"},
        {"old":"eWc=40,","new":"eWc=100,"},
        {"old":"tWc=5e4","new":"tWc=200000"}
      ]
    }
  }
}
'@
# END EMBEDDED_ANCHORS

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
        if (-not (Test-Path (Join-Path $root 'package.json'))) {
            throw "No package.json under '$root'."
        }
        return $root
    }

    $searchRoots = @(
        (Join-Path $HOME '.vscode/extensions'),
        (Join-Path $HOME '.cursor/extensions'),
        (Join-Path $HOME '.vscode-insiders/extensions')
    )

    $found = @()
    foreach ($root in $searchRoots) {
        if (Test-Path $root) {
            $found += @(Get-ChildItem -LiteralPath $root -Directory -Filter 'saoudrizwan.claude-dev-*' -ErrorAction SilentlyContinue)
        }
    }
    if ($found.Count -eq 0) {
        throw 'Cline extension folder not found. Use -ExtensionRoot only for an advanced/custom installation.'
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

    $oldCount = ([regex]::Matches($Text, [regex]::Escape([string]$Edit.old))).Count
    $newCount = ([regex]::Matches($Text, [regex]::Escape([string]$Edit.new))).Count

    if ($oldCount -eq 1 -and $newCount -eq 0) { return 'READY' }
    if ($oldCount -eq 0 -and $newCount -eq 1) { return 'ALREADY_PATCHED' }
    if ($oldCount -eq 0 -and $newCount -eq 0) { return 'MISSING' }
    return ('AMBIGUOUS(old={0},new={1})' -f $oldCount, $newCount)
}

function Test-BundleSyntax {
    param([string]$BundlePath)

    $node = Get-NodeExe
    if (-not $node) {
        throw 'Node.js was not found. Refusing to patch because node --check is a required safety gate.'
    }
    $out = & $node --check $BundlePath 2>&1
    if ($LASTEXITCODE -ne 0) {
        throw "Bundle failed syntax validation: $out"
    }
    Write-Host '  syntax validation: OK (node --check)' -ForegroundColor DarkGray
}

function Show-Status {
    param([string]$Status, [ConsoleColor]$Color = [ConsoleColor]::White)
    Write-Host ''
    Write-Host ('Status: {0}' -f $Status) -ForegroundColor $Color
}

if ($Report -and $Apply) {
    throw 'Choose either -Report or -Apply, not both.'
}

$catalog = $script:EmbeddedAnchorsJson | ConvertFrom-Json
$supportedVersions = @($catalog.versions.PSObject.Properties.Name)

$extensionRoot = Resolve-ClineExtension -Explicit $ExtensionRoot
$bundlePath = Join-Path $extensionRoot 'dist\extension.js'
$manifestPath = Join-Path $extensionRoot 'package.json'
$manifest = Get-Content -LiteralPath $manifestPath -Raw | ConvertFrom-Json
$version = [string]$manifest.version
$entryProp = $catalog.versions.PSObject.Properties[$version]

Write-Host ''
Write-Host 'Cline limits patch (unofficial)' -ForegroundColor Cyan
Write-Host ('  extension : {0}' -f $extensionRoot)
Write-Host ('  version   : {0}' -f $version)
Write-Host ('  supports  : {0}' -f ($supportedVersions -join ', '))

if (-not $entryProp) {
    Show-Status -Status 'UNSUPPORTED' -Color Red
    Write-Host ('This patcher does not contain anchors for installed Cline {0}.' -f $version) -ForegroundColor Red
    Write-Host 'Download the patch_cline_limits.ps1 asset from the matching GitHub release.' -ForegroundColor Yellow
    if ($Apply) { throw "Unsupported Cline version $version." }
    return
}

$entry = $entryProp.Value
if ([string]$entry.status -ne 'AUTO' -and [string]$entry.status -ne 'VERIFIED') {
    Show-Status -Status 'UNUSABLE' -Color Red
    Write-Host ('Embedded anchors for {0} have status {1}; refusing to patch.' -f $version, $entry.status) -ForegroundColor Red
    if ($Apply) { throw "Embedded anchors for $version are not approved." }
    return
}

$bundleFile = Get-Item -LiteralPath $bundlePath
$beforeHash = (Get-FileHash -LiteralPath $bundlePath -Algorithm SHA256).Hash.ToLower()
$expectedBefore = ([string]$entry.bundleSha256Before).ToLower()
$expectedAfter = ([string]$entry.bundleSha256After).ToLower()

Write-Host ('  bundle    : {0} bytes' -f $bundleFile.Length)
Write-Host ('  sha256    : {0}' -f $beforeHash)
Write-Host ('  expected  : {0}' -f $expectedBefore)
Write-Host ''

$text = [IO.File]::ReadAllText($bundlePath)
$edits = @($entry.edits)
$states = @()
$index = 0
foreach ($edit in $edits) {
    $index += 1
    $states += [pscustomobject]@{
        Id = $index
        Status = (Get-AnchorState -Text $text -Edit $edit)
        Old = [string]$edit.old
        New = [string]$edit.new
    }
}
$states | Select-Object Id, Status | Format-Table -AutoSize | Out-String -Width 200 | Write-Host

$readyCount = @($states | Where-Object { $_.Status -eq 'READY' }).Count
$patchedCount = @($states | Where-Object { $_.Status -eq 'ALREADY_PATCHED' }).Count
$bad = @($states | Where-Object { $_.Status -ne 'READY' -and $_.Status -ne 'ALREADY_PATCHED' })

$status = 'UNUSABLE'
if ($beforeHash -eq $expectedAfter -and $patchedCount -eq $edits.Count) {
    $status = 'ALREADY_PATCHED'
} elseif ($beforeHash -ne $expectedBefore) {
    $status = 'HASH_MISMATCH'
} elseif ($bad.Count -gt 0 -or $readyCount -ne $edits.Count) {
    $status = 'UNUSABLE'
} else {
    $status = 'READY'
}

switch ($status) {
    'READY' {
        Show-Status -Status 'READY' -Color Green
        Write-Host ('All {0} edits are ready and the clean bundle hash matches.' -f $edits.Count)
    }
    'ALREADY_PATCHED' {
        Show-Status -Status 'ALREADY_PATCHED' -Color Yellow
        Write-Host 'The installed bundle already has the recorded patched SHA-256.'
    }
    'HASH_MISMATCH' {
        Show-Status -Status 'HASH_MISMATCH' -Color Red
        Write-Host 'Installed bundle SHA-256 is neither the recorded clean hash nor the recorded patched hash.' -ForegroundColor Red
        Write-Host 'Refusing to modify an unknown/same-version build.' -ForegroundColor Red
    }
    default {
        Show-Status -Status 'UNUSABLE' -Color Red
        if ($bad.Count -gt 0) {
            Write-Host ('Unusable anchors: {0}' -f (($bad | ForEach-Object { '#{0}={1}' -f $_.Id, $_.Status }) -join ', ')) -ForegroundColor Red
        } else {
            Write-Host 'Anchor state is mixed or inconsistent with the clean bundle.' -ForegroundColor Red
        }
    }
}

if ($Report) { return }
if ($status -eq 'ALREADY_PATCHED') { return }
if ($status -ne 'READY') {
    if ($Apply) { throw "Refusing to patch because status is $status." }
    return
}

$shouldApply = $Apply
if (-not $Apply) {
    Write-Host ''
    $answer = Read-Host 'Apply patch now? [Y/N]'
    if ($answer -ne 'Y' -and $answer -ne 'y') {
        Write-Host 'No changes made.' -ForegroundColor Yellow
        return
    }
    $shouldApply = $true
}
if (-not $shouldApply) { return }

if ($bundleFile.IsReadOnly) {
    throw "Bundle file is read-only: $bundlePath"
}

$patched = $text
foreach ($edit in $edits) {
    $patched = $patched.Replace([string]$edit.old, [string]$edit.new)
}

$stamp = Get-Date -Format 'yyyyMMdd-HHmmss'
$backup = Join-Path $BackupRoot $stamp
New-Item -ItemType Directory -Path $backup -Force | Out-Null
Copy-Item -LiteralPath $bundlePath -Destination (Join-Path $backup 'extension.js') -Force
Copy-Item -LiteralPath $manifestPath -Destination (Join-Path $backup 'package.json') -Force

$utf8NoBom = New-Object System.Text.UTF8Encoding($false)
$staged = Join-Path $backup 'extension.patched.js'
[IO.File]::WriteAllText($staged, $patched, $utf8NoBom)
Test-BundleSyntax -BundlePath $staged

$stagedHash = (Get-FileHash -LiteralPath $staged -Algorithm SHA256).Hash.ToLower()
if ($stagedHash -ne $expectedAfter) {
    throw ("Patched bundle hash {0} differs from recorded expected hash {1}. Live bundle was not modified." -f $stagedHash, $expectedAfter)
}

[IO.File]::WriteAllText($bundlePath, $patched, $utf8NoBom)
$afterHash = (Get-FileHash -LiteralPath $bundlePath -Algorithm SHA256).Hash.ToLower()
if ($afterHash -ne $expectedAfter) {
    Copy-Item -LiteralPath (Join-Path $backup 'extension.js') -Destination $bundlePath -Force
    throw ("Post-write SHA-256 verification failed ({0}); original bundle restored from backup." -f $afterHash)
}

$record = [pscustomobject]@{
    patchedAtUtc = (Get-Date).ToUniversalTime().ToString('o')
    extensionRoot = $extensionRoot
    extensionVersion = $version
    bundlePath = $bundlePath
    bundleBytesBefore = $bundleFile.Length
    bundleSha256Before = $beforeHash
    bundleSha256After = $afterHash
    nodeExe = (Get-NodeExe)
    embeddedCatalogSchema = $catalog.schema
    edits = @($edits)
}
$record | ConvertTo-Json -Depth 6 | Set-Content -LiteralPath (Join-Path $backup 'patch-manifest.json') -Encoding UTF8

Write-Host ''
Write-Host 'Patched.' -ForegroundColor Green
Write-Host ('  backup : {0}' -f $backup)
Write-Host ('  sha256 : {0} -> {1}' -f $beforeHash, $afterHash)
Write-Host ''
Write-Host 'Next: in VS Code run "Developer: Reload Window".' -ForegroundColor Cyan
