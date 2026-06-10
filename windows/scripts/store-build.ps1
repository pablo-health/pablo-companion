#Requires -Version 7.0
<#
Build the Microsoft Store .msixupload for Pablo Companion.

Produces a single .msixupload containing x64 and arm64 .msix packages,
unsigned (Partner Center re-signs with the Microsoft publisher cert).

For self-contained .NET MSIX (.NET 10), AppxBundle's per-arch iteration
trips NETSDK1032 because the outer -p:Platform=x64 leaks PlatformTarget
into the arm64 sub-build. So we publish each platform separately and
bundle with makeappx.

Usage:
    pwsh windows/scripts/store-build.ps1
    pwsh windows/scripts/store-build.ps1 -Version 1.0.1
    pwsh windows/scripts/store-build.ps1 -Clean

Notes:
    - Store rejects re-uploads of the same version. Bump -Version on every
      submission, or edit Package.appxmanifest <Identity Version="..."/>
      manually before running.
    - Self-contained: .NET 10 runtime is bundled into each .msix (no
      undisclosed-dependency rejection under Store policy 10.2.4.1).
    - The .msixupload here is a zip of the .msixbundle + per-arch .appxsym
      files, same shape Partner Center expects.
#>

[CmdletBinding()]
param(
    [string]$Version,
    [switch]$Clean
)

$ErrorActionPreference = 'Stop'

$repoRoot     = (Resolve-Path (Join-Path $PSScriptRoot '..\..')).Path
$windowsDir   = Join-Path $repoRoot 'windows'
$projDir      = Join-Path $windowsDir 'PabloCompanion'
$projPath     = Join-Path $projDir 'PabloCompanion.csproj'
$manifestPath = Join-Path $projDir 'Package.appxmanifest'
$outputDir    = Join-Path $projDir 'AppPackages'

if (-not (Test-Path $projPath))     { throw "Project not found: $projPath" }
if (-not (Test-Path $manifestPath)) { throw "Manifest not found: $manifestPath" }

# -- Locate makeappx in Windows SDK --
$makeappx = Get-ChildItem 'C:\Program Files (x86)\Windows Kits\10\bin\*\x64\makeappx.exe' -ErrorAction SilentlyContinue |
    Sort-Object FullName -Descending | Select-Object -First 1
if (-not $makeappx) { throw 'makeappx.exe not found. Install Windows SDK.' }

# -- Optionally bump manifest version --
if ($Version) {
    if ($Version -notmatch '^\d+\.\d+\.\d+\.\d+$') {
        if ($Version -match '^\d+\.\d+\.\d+$') {
            $Version = "$Version.0"
        } else {
            throw "Version must be N.N.N or N.N.N.N (got: $Version)"
        }
    }

    # Store rejects packages with a non-zero revision (4th) digit. It reserves
    # that slot for its own use. Enforce here so we don't waste a Partner Center
    # upload finding out the hard way.
    if ($Version -notmatch '\.0$') {
        throw "Store packages must end in '.0' (got: $Version). Bump Major/Minor/Patch instead."
    }

    Write-Host "Bumping manifest version to $Version" -ForegroundColor Cyan
    $content = Get-Content $manifestPath -Raw
    $newContent = $content -replace 'Version="\d+\.\d+\.\d+\.\d+"', "Version=`"$Version`""
    if ($newContent -eq $content) {
        throw "Could not find Identity Version in manifest to replace"
    }
    Set-Content -Path $manifestPath -Value $newContent -NoNewline
} else {
    # Read current version from manifest
    $content = Get-Content $manifestPath -Raw
    if ($content -match 'Version="(\d+\.\d+\.\d+\.\d+)"') {
        $Version = $matches[1]
    } else {
        throw "Could not parse version from manifest"
    }
}
Write-Host "Building version $Version" -ForegroundColor Cyan

# -- Optional clean --
if ($Clean) {
    Write-Host 'Cleaning previous build output...' -ForegroundColor Cyan
    Remove-Item -Path (Join-Path $projDir 'bin')  -Recurse -Force -ErrorAction SilentlyContinue
    Remove-Item -Path (Join-Path $projDir 'obj')  -Recurse -Force -ErrorAction SilentlyContinue
    Remove-Item -Path $outputDir                  -Recurse -Force -ErrorAction SilentlyContinue
}

New-Item -ItemType Directory -Path $outputDir -Force | Out-Null
$msixStaging = Join-Path $outputDir '_staging_msix'
$symStaging  = Join-Path $outputDir '_staging_sym'
Remove-Item $msixStaging,$symStaging -Recurse -Force -ErrorAction SilentlyContinue
New-Item -ItemType Directory -Path $msixStaging -Force | Out-Null
New-Item -ItemType Directory -Path $symStaging  -Force | Out-Null

# -- Per-arch self-contained publish --
foreach ($plat in @('x64','arm64')) {
    $rid = "win-$plat"
    Write-Host ''
    Write-Host "=== Publishing $plat (self-contained) ===" -ForegroundColor Cyan

    Push-Location $windowsDir
    try {
        dotnet publish PabloCompanion/PabloCompanion.csproj `
            -c Release `
            -p:Platform=$plat `
            -r $rid `
            --self-contained true `
            -p:GenerateAppxPackageOnBuild=true `
            -p:AppxPackageSigningEnabled=false `
            -p:UapAppxPackageBuildMode=SideloadOnly `
            -p:AppxBundle=Never `
            -p:AppxSymbolPackageEnabled=true `
            --nologo
        if ($LASTEXITCODE -ne 0) { throw "dotnet publish failed for $plat" }
    }
    finally { Pop-Location }

    # Locate the produced .msix (search both AppPackages and bin in case the
    # SDK puts it in either spot, take the newest matching this arch).
    $msix = Get-ChildItem -Path @($outputDir, (Join-Path $projDir 'bin')) `
                          -Recurse -Filter '*.msix' -ErrorAction SilentlyContinue |
        Where-Object { $_.Name -match "_${plat}\.msix$" -and $_.FullName -notlike "*_staging_*" } |
        Sort-Object LastWriteTime -Descending | Select-Object -First 1
    if (-not $msix) { throw "No .msix produced for $plat" }
    Write-Host "  msix : $($msix.Name)" -ForegroundColor Green
    Copy-Item $msix.FullName -Destination $msixStaging -Force

    # Collect matching symbol package if present
    $sym = Get-ChildItem -Path @($outputDir, (Join-Path $projDir 'bin')) `
                         -Recurse -Filter '*.appxsym' -ErrorAction SilentlyContinue |
        Where-Object { $_.Name -match "_${plat}\.appxsym$" } |
        Sort-Object LastWriteTime -Descending | Select-Object -First 1
    if ($sym) {
        Write-Host "  sym  : $($sym.Name)" -ForegroundColor Green
        Copy-Item $sym.FullName -Destination $symStaging -Force
    }
}

# -- Bundle into a single .msixbundle --
Write-Host ''
Write-Host '=== Bundling .msixbundle ===' -ForegroundColor Cyan
$bundleName = "PabloCompanion_${Version}_x64_arm64.msixbundle"
$bundlePath = Join-Path $outputDir $bundleName
Remove-Item $bundlePath -Force -ErrorAction SilentlyContinue
& $makeappx.FullName bundle /d $msixStaging /p $bundlePath /bv $Version /o
if ($LASTEXITCODE -ne 0) { throw 'makeappx bundle failed' }

# -- Wrap into .msixupload (zip containing .msixbundle + .appxsym files) --
Write-Host ''
Write-Host '=== Wrapping .msixupload ===' -ForegroundColor Cyan
$uploadStaging = Join-Path $outputDir '_staging_upload'
Remove-Item $uploadStaging -Recurse -Force -ErrorAction SilentlyContinue
New-Item -ItemType Directory -Path $uploadStaging -Force | Out-Null
Copy-Item $bundlePath -Destination $uploadStaging -Force
Get-ChildItem $symStaging -Filter '*.appxsym' | Copy-Item -Destination $uploadStaging -Force

$uploadName = "PabloCompanion_${Version}_x64_arm64_bundle.msixupload"
$uploadPath = Join-Path $outputDir $uploadName
Remove-Item $uploadPath -Force -ErrorAction SilentlyContinue
# .msixupload is just a zip with a different extension
$tmpZip = [IO.Path]::ChangeExtension($uploadPath, 'zip')
Compress-Archive -Path (Join-Path $uploadStaging '*') -DestinationPath $tmpZip
Move-Item $tmpZip $uploadPath

# -- Cleanup staging --
Remove-Item $msixStaging,$symStaging,$uploadStaging -Recurse -Force -ErrorAction SilentlyContinue

$sizeMB = [Math]::Round((Get-Item $uploadPath).Length / 1MB, 1)

Write-Host ''
Write-Host '=== Build succeeded ===' -ForegroundColor Green
Write-Host "Upload : $uploadPath"
Write-Host "Size   : ${sizeMB} MB"
Write-Host ''
Write-Host 'Next steps:' -ForegroundColor Cyan
Write-Host '  1. (Optional) Sideload-test locally:'
Write-Host '     pwsh windows/scripts/sideload-dev.ps1 -Rebuild'
Write-Host '  2. Upload to Partner Center:'
Write-Host '     https://partner.microsoft.com/dashboard/apps-and-games/overview'
Write-Host '     -> Pablo Health -> Submissions -> Packages -> drag the .msixupload'
