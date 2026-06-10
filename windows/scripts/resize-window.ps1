#Requires -Version 7.0
<#
Resize a window to an exact pixel size for clean Microsoft Store
screenshots. Defaults are tuned for Pablo Companion: 1920x1080 at
position (100,100), which gives Snipping Tool a clean 1920x1080 PNG
when you crop to the window content.

Usage:
    pwsh windows/scripts/resize-window.ps1
    pwsh windows/scripts/resize-window.ps1 -Width 1366 -Height 768
    pwsh windows/scripts/resize-window.ps1 -ProcessName PabloCompanion
    pwsh windows/scripts/resize-window.ps1 -TitleMatch "*Pablo*"

Tip: launch Pablo first, let it finish opening, then run this script.
#>

[CmdletBinding()]
param(
    [string]$ProcessName,
    [string]$TitleMatch = '*Pablo*',
    [int]$Width = 1920,
    [int]$Height = 1080,
    [int]$X = 100,
    [int]$Y = 100
)

$ErrorActionPreference = 'Stop'

Add-Type -Name W -Namespace Win32 -MemberDefinition @'
[DllImport("user32.dll")]
public static extern bool SetWindowPos(IntPtr h, IntPtr i, int x, int y, int w, int t, uint f);
[DllImport("user32.dll")]
public static extern bool SetForegroundWindow(IntPtr h);
[DllImport("user32.dll")]
public static extern bool ShowWindow(IntPtr h, int cmd);
'@

# -- Find the window --
$candidate = $null
if ($ProcessName) {
    $candidate = Get-Process -Name $ProcessName -ErrorAction SilentlyContinue |
        Where-Object { $_.MainWindowHandle -ne 0 } |
        Select-Object -First 1
}

if (-not $candidate) {
    $candidate = Get-Process |
        Where-Object { $_.MainWindowHandle -ne 0 -and $_.MainWindowTitle -like $TitleMatch } |
        Select-Object -First 1
}

if (-not $candidate) {
    Write-Host "Could not find a window matching ProcessName='$ProcessName' or TitleMatch='$TitleMatch'." -ForegroundColor Yellow
    Write-Host ""
    Write-Host "Visible top-level windows currently on screen:" -ForegroundColor Cyan
    Get-Process | Where-Object { $_.MainWindowHandle -ne 0 } |
        Select-Object Id, ProcessName, MainWindowTitle |
        Sort-Object ProcessName |
        Format-Table -AutoSize
    Write-Host "Re-run with -ProcessName <name> or -TitleMatch '<pattern>'." -ForegroundColor Yellow
    exit 1
}

Write-Host "Target: PID $($candidate.Id) '$($candidate.ProcessName)' — '$($candidate.MainWindowTitle)'" -ForegroundColor Cyan

# -- Restore if minimized, bring to front --
[Win32.W]::ShowWindow($candidate.MainWindowHandle, 9) | Out-Null   # SW_RESTORE
[Win32.W]::SetForegroundWindow($candidate.MainWindowHandle) | Out-Null

# -- Resize --
# Flags: SWP_NOZORDER (0x0004) so we don't change Z-order
$result = [Win32.W]::SetWindowPos($candidate.MainWindowHandle, [IntPtr]::Zero, $X, $Y, $Width, $Height, 0x0004)

if ($result) {
    Write-Host "Resized to ${Width}x${Height} at (${X},${Y})." -ForegroundColor Green
    Write-Host "Now use Win+Shift+S to capture. Crop to the window or use Rectangular Snip and align to the window border." -ForegroundColor Cyan
} else {
    Write-Host "SetWindowPos returned false — window may be DPI-virtualized or owned by another session." -ForegroundColor Red
    exit 1
}
