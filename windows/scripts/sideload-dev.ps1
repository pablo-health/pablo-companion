#Requires -Version 7.0
<#
Sideload-test the packaged MSIX build.

User-context steps (creating dev cert + signing the bundle) run without admin.
Trust + install steps need admin (LocalMachine\TrustedPeople + Add-AppxPackage
for a sideloaded package signed with a non-CA cert).

Usage:
    # First time (creates cert, signs bundle):
    pwsh windows/scripts/sideload-dev.ps1

    # Then re-run in elevated PowerShell to trust + install:
    pwsh windows/scripts/sideload-dev.ps1

    # Force a fresh rebuild before signing:
    pwsh windows/scripts/sideload-dev.ps1 -Rebuild
#>

[CmdletBinding()]
param(
    [switch]$Rebuild,
    [ValidateSet('x64','arm64')]
    [string]$Platform = $(if ($env:PROCESSOR_ARCHITECTURE -eq 'ARM64') { 'arm64' } else { 'x64' }),
    [string]$PublisherCN = 'CN=42DEB728-5FF9-4489-A5D8-F80DC15B972F',
    [string]$PackageName = 'PabloHealthLLC.PabloHealth'
)

$ErrorActionPreference = 'Stop'

$repoRoot = (Resolve-Path (Join-Path $PSScriptRoot '..\..')).Path
$projDir  = Join-Path $repoRoot 'windows\PabloCompanion'
$isAdmin  = [Security.Principal.WindowsPrincipal]::new(
    [Security.Principal.WindowsIdentity]::GetCurrent()
).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)

# -- 1. Dev code-signing cert (no admin) --
$cert = Get-ChildItem Cert:\CurrentUser\My |
    Where-Object Subject -eq $PublisherCN |
    Select-Object -First 1

if (-not $cert) {
    Write-Host "Creating dev code-signing cert: $PublisherCN" -ForegroundColor Cyan
    $cert = New-SelfSignedCertificate `
        -Type CodeSigningCert `
        -Subject $PublisherCN `
        -KeyUsage DigitalSignature `
        -FriendlyName 'Pablo Companion Dev Cert' `
        -CertStoreLocation 'Cert:\CurrentUser\My' `
        -TextExtension @('2.5.29.37={text}1.3.6.1.5.5.7.3.3', '2.5.29.19={text}') `
        -NotAfter (Get-Date).AddYears(2)
}
Write-Host "Cert thumbprint: $($cert.Thumbprint)"

# -- 2. Build (optional) --
if ($Rebuild) {
    Write-Host "Rebuilding packaged Release/$Platform..." -ForegroundColor Cyan
    Push-Location (Join-Path $repoRoot 'windows')
    try {
        dotnet build PabloCompanion/PabloCompanion.csproj `
            -c Release -p:Platform=$Platform `
            -p:GenerateAppxPackageOnBuild=true `
            -p:AppxPackageSigningEnabled=false `
            -p:UapAppxPackageBuildMode=SideloadOnly
        if ($LASTEXITCODE -ne 0) { throw 'dotnet build failed' }
    }
    finally { Pop-Location }
}

# -- 3. Find latest .msixbundle for the requested platform --
# Bundle filenames follow pattern: PabloCompanion_<version>_<arch>.msixbundle
$bundle = Get-ChildItem (Join-Path $projDir 'AppPackages') -Recurse -Filter *.msixbundle -ErrorAction SilentlyContinue |
    Where-Object { $_.Name -match "_${Platform}\.msixbundle$" } |
    Sort-Object LastWriteTime -Descending | Select-Object -First 1
if (-not $bundle) {
    throw "No $Platform .msixbundle found under $projDir\AppPackages. Run with -Rebuild."
}
Write-Host "Bundle: $($bundle.FullName)"

# -- 4. Sign (no admin) --
$signtool = Get-ChildItem 'C:\Program Files (x86)\Windows Kits\10\bin\*\x64\signtool.exe' -ErrorAction SilentlyContinue |
    Sort-Object FullName -Descending | Select-Object -First 1
if (-not $signtool) { throw 'signtool.exe not found. Install Windows SDK.' }

Write-Host 'Signing bundle...' -ForegroundColor Cyan
& $signtool.FullName sign /fd SHA256 /sha1 $cert.Thumbprint $bundle.FullName
if ($LASTEXITCODE -ne 0) { throw 'signtool sign failed' }
Write-Host 'Signed.' -ForegroundColor Green

# -- 5. Trust + install (ADMIN required) --
if (-not $isAdmin) {
    Write-Host ''
    Write-Host 'Cert created and bundle signed.' -ForegroundColor Green
    Write-Host 'To trust the cert and install the package, re-run this script in an ELEVATED PowerShell:' -ForegroundColor Yellow
    Write-Host '  pwsh windows/scripts/sideload-dev.ps1' -ForegroundColor Yellow
    return
}

# Trust cert in LocalMachine\TrustedPeople
$trustedPath = Join-Path 'Cert:\LocalMachine\TrustedPeople' $cert.Thumbprint
if (-not (Test-Path $trustedPath)) {
    Write-Host 'Importing cert into LocalMachine\TrustedPeople...' -ForegroundColor Cyan
    $cerPath = Join-Path $env:TEMP "$($cert.Thumbprint).cer"
    Export-Certificate -Cert $cert -FilePath $cerPath -Type CERT | Out-Null
    Import-Certificate -FilePath $cerPath -CertStoreLocation Cert:\LocalMachine\TrustedPeople | Out-Null
    Remove-Item $cerPath -Force
} else {
    Write-Host 'Cert already trusted in LocalMachine\TrustedPeople.'
}

# Remove any existing install
$existing = Get-AppxPackage -Name $PackageName -ErrorAction SilentlyContinue
if ($existing) {
    Write-Host "Removing previously installed $PackageName..." -ForegroundColor Cyan
    $existing | Remove-AppxPackage
}

Write-Host 'Installing package...' -ForegroundColor Cyan
Add-AppxPackage -Path $bundle.FullName

$installed = Get-AppxPackage -Name $PackageName -ErrorAction SilentlyContinue
if ($installed) {
    Write-Host ''
    Write-Host "Installed: $($installed.PackageFullName)" -ForegroundColor Green
    Write-Host "Install location: $($installed.InstallLocation)"
    Write-Host "Launch from Start menu as 'Pablo'." -ForegroundColor Green
} else {
    Write-Host 'Install completed but package not found via Get-AppxPackage. Check Start menu.' -ForegroundColor Yellow
}
