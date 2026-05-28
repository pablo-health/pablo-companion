#Requires -Version 7.0
<#
Build the Microsoft Store .msixupload for Pablo Companion.

Produces a single bundle containing both x64 and arm64 .msix packages,
unsigned (Partner Center re-signs with the Microsoft publisher cert).
This is the CLI equivalent of the Visual Studio "Publish > Create App
Packages > Microsoft Store" wizard.

Usage:
    pwsh windows/scripts/store-build.ps1
    pwsh windows/scripts/store-build.ps1 -Version 1.0.1
    pwsh windows/scripts/store-build.ps1 -Clean

Notes:
    - Store rejects re-uploads of the same version. Bump -Version on every
      submission, or edit Package.appxmanifest <Identity Version="..."/>
      manually before running.
    - The mspdbcmf.exe warning about symbol-package generation is a known
      issue with the current .NET 10 + WinAppSDK toolchain. It does not
      affect the produced .msixupload; only Partner Center crash-dashboard
      symbol resolution. Safe to ignore for 1.0.
#>

[CmdletBinding()]
param(
    [string]$Version,
    [switch]$Clean
)

$ErrorActionPreference = 'Stop'

$repoRoot     = (Resolve-Path (Join-Path $PSScriptRoot '..\..')).Path
$windowsDir   = Join-Path $repoRoot 'windows'
$projPath     = Join-Path $windowsDir 'PabloCompanion\PabloCompanion.csproj'
$manifestPath = Join-Path $windowsDir 'PabloCompanion\Package.appxmanifest'
$outputDir    = Join-Path $windowsDir 'PabloCompanion\AppPackages'

if (-not (Test-Path $projPath))     { throw "Project not found: $projPath" }
if (-not (Test-Path $manifestPath)) { throw "Manifest not found: $manifestPath" }

# -- Optionally bump manifest version --
if ($Version) {
    if ($Version -notmatch '^\d+\.\d+\.\d+\.\d+$') {
        # Partner Center wants 4-part version; pad if user passed 3-part
        if ($Version -match '^\d+\.\d+\.\d+$') {
            $Version = "$Version.0"
        } else {
            throw "Version must be N.N.N or N.N.N.N (got: $Version)"
        }
    }

    Write-Host "Bumping manifest version to $Version" -ForegroundColor Cyan
    $content = Get-Content $manifestPath -Raw
    $newContent = $content -replace 'Version="\d+\.\d+\.\d+\.\d+"', "Version=`"$Version`""
    if ($newContent -eq $content) {
        throw "Could not find Identity Version in manifest to replace"
    }
    Set-Content -Path $manifestPath -Value $newContent -NoNewline
}

# -- Optional clean --
if ($Clean) {
    Write-Host "Cleaning previous build output..." -ForegroundColor Cyan
    Remove-Item -Path (Join-Path $windowsDir 'PabloCompanion\bin') -Recurse -Force -ErrorAction SilentlyContinue
    Remove-Item -Path (Join-Path $windowsDir 'PabloCompanion\obj') -Recurse -Force -ErrorAction SilentlyContinue
    Remove-Item -Path $outputDir -Recurse -Force -ErrorAction SilentlyContinue
}

# -- Build --
# Flags mirror what the VS Publish > Create App Packages > Microsoft Store
# wizard sets when both architectures are ticked and symbols are enabled.
Write-Host "Building .msixupload (x64 + arm64)..." -ForegroundColor Cyan

Push-Location $windowsDir
try {
    dotnet publish PabloCompanion/PabloCompanion.csproj `
        -c Release `
        -p:Platform=x64 `
        -p:GenerateAppxPackageOnBuild=true `
        -p:AppxPackageSigningEnabled=false `
        -p:UapAppxPackageBuildMode=StoreUpload `
        -p:AppxBundle=Always `
        -p:AppxBundlePlatforms="x64|arm64" `
        -p:AppxSymbolPackageEnabled=true `
        --nologo
}
finally { Pop-Location }

# Note: dotnet may exit non-zero due to the mspdbcmf.exe symbol-package
# error even when the .msixupload itself is produced. Verify by file
# existence rather than $LASTEXITCODE.

# -- Locate output --
$bundle = Get-ChildItem $outputDir -Filter '*.msixupload' -ErrorAction SilentlyContinue |
    Sort-Object LastWriteTime -Descending | Select-Object -First 1

if (-not $bundle) {
    throw "No .msixupload produced in $outputDir. Check build output above."
}

$sizeMB = [Math]::Round($bundle.Length / 1MB, 1)

Write-Host ""
Write-Host "=== Build succeeded ===" -ForegroundColor Green
Write-Host "Bundle : $($bundle.FullName)"
Write-Host "Size   : ${sizeMB} MB"
Write-Host ""
Write-Host "Next steps:" -ForegroundColor Cyan
Write-Host "  1. (Optional) Test on a clean Windows machine before uploading:"
Write-Host "     pwsh windows/scripts/sideload-dev.ps1 -Rebuild"
Write-Host "  2. Upload to Partner Center:"
Write-Host "     https://partner.microsoft.com/dashboard/apps-and-games/overview"
Write-Host "     -> Pablo Health -> Submissions -> Packages -> drag the .msixupload"
