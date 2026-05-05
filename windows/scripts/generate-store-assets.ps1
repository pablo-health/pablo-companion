#Requires -Version 7.0
<#
Generates MSIX Store visual assets from a 1024x1024 PNG master.
Run from repo root: pwsh windows/scripts/generate-store-assets.ps1
#>

[CmdletBinding()]
param(
    [string]$Source = (Join-Path $PSScriptRoot '..\..\mac\PabloCompanion\Assets.xcassets\AppIcon.appiconset\AppIcon512x512@2x.png'),
    [string]$OutDir = (Join-Path $PSScriptRoot '..\PabloCompanion\Images'),
    [string]$WideBackground = '#FDF6EC'
)

$ErrorActionPreference = 'Stop'
Add-Type -AssemblyName System.Drawing

$Source = (Resolve-Path $Source).Path
$OutDir = [System.IO.Path]::GetFullPath($OutDir)
[System.IO.Directory]::CreateDirectory($OutDir) | Out-Null

Write-Host "Source : $Source"
Write-Host "Output : $OutDir"

$master = [System.Drawing.Image]::FromFile($Source)
if ($master.Width -lt 1024 -or $master.Height -lt 1024) {
    throw "Source must be at least 1024x1024 (got $($master.Width)x$($master.Height))"
}

function Save-Square([int]$Size, [string]$Path) {
    $bmp = New-Object System.Drawing.Bitmap $Size, $Size
    $g = [System.Drawing.Graphics]::FromImage($bmp)
    $g.InterpolationMode = [System.Drawing.Drawing2D.InterpolationMode]::HighQualityBicubic
    $g.SmoothingMode = [System.Drawing.Drawing2D.SmoothingMode]::HighQuality
    $g.PixelOffsetMode = [System.Drawing.Drawing2D.PixelOffsetMode]::HighQuality
    $g.DrawImage($master, 0, 0, $Size, $Size)
    $bmp.Save($Path, [System.Drawing.Imaging.ImageFormat]::Png)
    $g.Dispose(); $bmp.Dispose()
    Write-Host "  $([System.IO.Path]::GetFileName($Path))  ${Size}x${Size}"
}

function Save-Wide([int]$Width, [int]$Height, [string]$Path) {
    $bmp = New-Object System.Drawing.Bitmap $Width, $Height
    $g = [System.Drawing.Graphics]::FromImage($bmp)
    $bg = [System.Drawing.ColorTranslator]::FromHtml($WideBackground)
    $g.Clear($bg)
    $g.InterpolationMode = [System.Drawing.Drawing2D.InterpolationMode]::HighQualityBicubic
    $g.SmoothingMode = [System.Drawing.Drawing2D.SmoothingMode]::HighQuality
    $g.PixelOffsetMode = [System.Drawing.Drawing2D.PixelOffsetMode]::HighQuality
    # Centered square that fits within the height
    $iconSize = [Math]::Min($Height, $Width)
    $x = [int](($Width - $iconSize) / 2)
    $y = [int](($Height - $iconSize) / 2)
    $g.DrawImage($master, $x, $y, $iconSize, $iconSize)
    $bmp.Save($Path, [System.Drawing.Imaging.ImageFormat]::Png)
    $g.Dispose(); $bmp.Dispose()
    Write-Host "  $([System.IO.Path]::GetFileName($Path))  ${Width}x${Height}"
}

$squares = @(
    @{ Name = 'Square44x44Logo';   Base = 44 },
    @{ Name = 'Square71x71Logo';   Base = 71 },
    @{ Name = 'Square150x150Logo'; Base = 150 },
    @{ Name = 'Square310x310Logo'; Base = 310 },
    @{ Name = 'StoreLogo';         Base = 50 },
    @{ Name = 'LockScreenLogo';    Base = 24 },
    @{ Name = 'BadgeLogo';         Base = 24 }
)
$scales = 100, 125, 150, 200, 400

foreach ($s in $squares) {
    foreach ($scale in $scales) {
        # StoreLogo, LockScreenLogo, BadgeLogo only ship at scale-100 in most templates
        if ($s.Name -in 'StoreLogo','LockScreenLogo','BadgeLogo' -and $scale -ne 100) { continue }
        $size = [int]([math]::Round($s.Base * $scale / 100.0))
        $file = Join-Path $OutDir ("{0}.scale-{1}.png" -f $s.Name, $scale)
        Save-Square -Size $size -Path $file
    }
}

# Wide tile (310x150)
foreach ($scale in 100,125,150,200,400) {
    $w = [int]([math]::Round(310 * $scale / 100.0))
    $h = [int]([math]::Round(150 * $scale / 100.0))
    $file = Join-Path $OutDir ("Wide310x150Logo.scale-{0}.png" -f $scale)
    Save-Wide -Width $w -Height $h -Path $file
}

# Splash screen (620x300)
foreach ($scale in 100,125,150,200,400) {
    $w = [int]([math]::Round(620 * $scale / 100.0))
    $h = [int]([math]::Round(300 * $scale / 100.0))
    $file = Join-Path $OutDir ("SplashScreen.scale-{0}.png" -f $scale)
    Save-Wide -Width $w -Height $h -Path $file
}

# Target-size variants for Square44x44Logo (taskbar / start jump list / file explorer)
foreach ($size in 16, 24, 32, 48, 256) {
    $file = Join-Path $OutDir ("Square44x44Logo.targetsize-{0}.png" -f $size)
    Save-Square -Size $size -Path $file
    # Also the unplated variant (transparent background) — same image; the master already has alpha
    $fileUnplated = Join-Path $OutDir ("Square44x44Logo.targetsize-{0}_altform-unplated.png" -f $size)
    Save-Square -Size $size -Path $fileUnplated
}

$master.Dispose()

$count = (Get-ChildItem $OutDir -Filter *.png).Count
Write-Host "`nGenerated $count PNG(s) in $OutDir"
