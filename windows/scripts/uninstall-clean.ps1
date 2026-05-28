#Requires -Version 7.0
<#
Completely remove Pablo Companion from this Windows machine.

Removes the installed MSIX package (which takes the per-package AppData
and Credential Manager entries with it -- MSIX isolation makes cleanup
clean by design) and, optionally, the dev signing certificate created by
sideload-dev.ps1.

Usage:
    # Remove the installed package only (no admin required):
    pwsh windows/scripts/uninstall-clean.ps1

    # Also remove the sideload dev cert (requires admin to clear
    # LocalMachine\TrustedPeople):
    pwsh windows/scripts/uninstall-clean.ps1 -RemoveDevCert

    # Skip the "are you sure" prompt:
    pwsh windows/scripts/uninstall-clean.ps1 -Force
#>

[CmdletBinding()]
param(
    [switch]$RemoveDevCert,
    [switch]$Force,
    [string]$PackageName = 'PabloHealthLLC.PabloHealth',
    [string]$DevCertSubject = 'CN=42DEB728-5FF9-4489-A5D8-F80DC15B972F'
)

$ErrorActionPreference = 'Stop'

$isAdmin = [Security.Principal.WindowsPrincipal]::new(
    [Security.Principal.WindowsIdentity]::GetCurrent()
).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)

# -- 1. What is installed --
$installed = Get-AppxPackage -Name $PackageName -ErrorAction SilentlyContinue

# -- 2. Confirm --
if (-not $Force) {
    Write-Host "About to remove:" -ForegroundColor Yellow
    if ($installed) {
        Write-Host "  - MSIX package: $($installed.PackageFullName)"
        Write-Host "    (data at: $($installed.InstallLocation))"
        Write-Host "    + per-package AppData under C:\Users\$env:USERNAME\AppData\Local\Packages\$($installed.PackageFamilyName)\"
    } else {
        Write-Host "  - (no installed MSIX package found)"
    }

    if ($RemoveDevCert) {
        $userCert    = Get-ChildItem Cert:\CurrentUser\My -ErrorAction SilentlyContinue |
            Where-Object Subject -eq $DevCertSubject
        $trustedCert = Get-ChildItem Cert:\LocalMachine\TrustedPeople -ErrorAction SilentlyContinue |
            Where-Object Subject -eq $DevCertSubject
        if ($userCert)    { Write-Host "  - Dev cert in CurrentUser\My (thumbprint $($userCert.Thumbprint))" }
        if ($trustedCert) { Write-Host "  - Dev cert in LocalMachine\TrustedPeople (requires admin)" }
        if (-not $userCert -and -not $trustedCert) { Write-Host "  - (no dev cert found matching $DevCertSubject)" }
    }

    Write-Host ""
    $response = Read-Host "Proceed? [y/N]"
    if ($response -ne 'y' -and $response -ne 'Y') {
        Write-Host "Cancelled." -ForegroundColor Yellow
        return
    }
}

# -- 3. Remove the installed package --
if ($installed) {
    Write-Host "Removing $PackageName..." -ForegroundColor Cyan
    $installed | Remove-AppxPackage
    Write-Host "  MSIX package removed (AppData + Credential Manager entries scoped to this package are gone with it)." -ForegroundColor Green
} else {
    Write-Host "No installed MSIX package to remove." -ForegroundColor Yellow
}

# -- 4. Optionally remove dev cert --
if ($RemoveDevCert) {
    # CurrentUser\My — never needs admin
    $userCert = Get-ChildItem Cert:\CurrentUser\My -ErrorAction SilentlyContinue |
        Where-Object Subject -eq $DevCertSubject
    if ($userCert) {
        Write-Host "Removing dev cert from CurrentUser\My..." -ForegroundColor Cyan
        $userCert | Remove-Item -Force
        Write-Host "  Removed." -ForegroundColor Green
    }

    # LocalMachine\TrustedPeople — needs admin
    $trustedCert = Get-ChildItem Cert:\LocalMachine\TrustedPeople -ErrorAction SilentlyContinue |
        Where-Object Subject -eq $DevCertSubject
    if ($trustedCert) {
        if (-not $isAdmin) {
            Write-Host "Dev cert in LocalMachine\TrustedPeople requires admin to remove." -ForegroundColor Yellow
            Write-Host "  Re-run this script in an elevated PowerShell with -RemoveDevCert to finish."
        } else {
            Write-Host "Removing dev cert from LocalMachine\TrustedPeople..." -ForegroundColor Cyan
            $trustedCert | Remove-Item -Force
            Write-Host "  Removed." -ForegroundColor Green
        }
    }
}

# -- 5. Sanity check: anything Pablo-shaped left? --
Write-Host ""
Write-Host "Sanity check:" -ForegroundColor Cyan

$remaining = Get-AppxPackage -Name $PackageName -ErrorAction SilentlyContinue
if ($remaining) {
    Write-Host "  [!] Package still installed (this is unexpected): $($remaining.PackageFullName)" -ForegroundColor Red
} else {
    Write-Host "  [ok] No PabloHealthLLC.* package installed."
}

$leftoverPackageData = "C:\Users\$env:USERNAME\AppData\Local\Packages\${PackageName}_*"
if (Test-Path $leftoverPackageData) {
    Write-Host "  [!] Leftover AppData found at $leftoverPackageData" -ForegroundColor Red
    Write-Host "      Remove with: Remove-Item -Recurse -Force '$leftoverPackageData'"
} else {
    Write-Host "  [ok] No leftover per-package AppData."
}

# Roaming AppData -- MSIX apps rarely write here, but check anyway
$roaming = Join-Path $env:APPDATA 'PabloCompanion'
if (Test-Path $roaming) {
    Write-Host "  [!] Found $roaming (unexpected for an MSIX app -- safe to delete)" -ForegroundColor Yellow
} else {
    Write-Host "  [ok] No leftover Roaming AppData."
}

Write-Host ""
Write-Host "Done." -ForegroundColor Green
