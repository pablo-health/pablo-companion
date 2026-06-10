#Requires -Version 7.0
<#
Capture a screenshot of a window and save as PNG in the current folder.

Uses PrintWindow with PW_RENDERFULLCONTENT — captures the window's
own pixels directly via the OS, so the target does NOT need to be in
the foreground. Sidesteps the SetForegroundWindow focus-restriction
issue you hit running this from a PowerShell embedded in VS.

PrintWindow + PW_RENDERFULLCONTENT is the documented technique for
hardware-rendered windows (WinUI 3 / DirectComposition / WPF). Without
the flag the result is blank black; with it, you get the live frame.

Usage:
    pwsh windows/scripts/capture-window.ps1
    pwsh windows/scripts/capture-window.ps1 -OutName login-screen
    pwsh windows/scripts/capture-window.ps1 -TitleMatch "*Visual Studio*"

Pair with resize-window.ps1 for a clean fixed dimension:
    pwsh windows/scripts/resize-window.ps1
    pwsh windows/scripts/capture-window.ps1 -OutName day-view
#>

[CmdletBinding()]
param(
    [string]$ProcessName,
    [string]$TitleMatch = '*Pablo*',
    [string]$OutName,
    [string]$OutDir = (Get-Location).Path
)

$ErrorActionPreference = 'Stop'
Add-Type -AssemblyName System.Drawing

# Declare DPI awareness so GetWindowRect returns physical pixel coords
# on this 200% scaling display.
Add-Type -Name U -Namespace Win32 -MemberDefinition @'
[DllImport("user32.dll")]
public static extern bool SetProcessDPIAware();
[DllImport("user32.dll")]
public static extern bool GetWindowRect(IntPtr h, out RECT r);
[DllImport("user32.dll")]
public static extern bool ShowWindow(IntPtr h, int cmd);
[DllImport("user32.dll")]
public static extern bool PrintWindow(IntPtr hwnd, IntPtr hdcBlt, uint nFlags);
[StructLayout(LayoutKind.Sequential)]
public struct RECT { public int Left, Top, Right, Bottom; }
'@
[Win32.U]::SetProcessDPIAware() | Out-Null

# PW_RENDERFULLCONTENT — required for WinUI 3 / DirectComposition windows.
$PW_RENDERFULLCONTENT = 0x00000002

# -- Find the target window --
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
    Get-Process | Where-Object { $_.MainWindowHandle -ne 0 } |
        Select-Object Id, ProcessName, MainWindowTitle |
        Sort-Object ProcessName | Format-Table -AutoSize
    exit 1
}

$hwnd = $candidate.MainWindowHandle
Write-Host "Capturing: PID $($candidate.Id) '$($candidate.ProcessName)' — '$($candidate.MainWindowTitle)'" -ForegroundColor Cyan

# Make sure the window isn't minimized — PrintWindow won't capture a
# minimized window. We don't need to foreground it, just restore.
[Win32.U]::ShowWindow($hwnd, 9) | Out-Null   # SW_RESTORE
Start-Sleep -Milliseconds 150

# -- Read window rect for size only --
$rect = New-Object Win32.U+RECT
[Win32.U]::GetWindowRect($hwnd, [ref]$rect) | Out-Null
$w = $rect.Right - $rect.Left
$h = $rect.Bottom - $rect.Top
if ($w -le 0 -or $h -le 0) {
    Write-Host "Window has zero/negative dimensions (${w}x${h}). Is it minimized?" -ForegroundColor Red
    exit 1
}

# -- Capture via PrintWindow --
$bmp = New-Object System.Drawing.Bitmap $w, $h
$gfx = [System.Drawing.Graphics]::FromImage($bmp)
$hdc = $gfx.GetHdc()
try {
    $ok = [Win32.U]::PrintWindow($hwnd, $hdc, $PW_RENDERFULLCONTENT)
}
finally {
    $gfx.ReleaseHdc($hdc)
    $gfx.Dispose()
}

if (-not $ok) {
    Write-Host "PrintWindow returned false. Falling back to screen capture (the window must be visible on screen)." -ForegroundColor Yellow
    $bmp.Dispose()
    $bmp = New-Object System.Drawing.Bitmap $w, $h
    $gfx = [System.Drawing.Graphics]::FromImage($bmp)
    $gfx.CopyFromScreen($rect.Left, $rect.Top, 0, 0, (New-Object System.Drawing.Size $w, $h))
    $gfx.Dispose()
}

# -- Save --
if (-not $OutName) {
    $OutName = "pablo-$(Get-Date -Format 'yyyyMMdd-HHmmss')"
}
if ($OutName -notmatch '\.png$') { $OutName = "$OutName.png" }
$outPath = Join-Path $OutDir $OutName

$bmp.Save($outPath, [System.Drawing.Imaging.ImageFormat]::Png)
$bmp.Dispose()

$sizeKB = [Math]::Round((Get-Item $outPath).Length / 1KB, 1)
Write-Host "Saved: $outPath" -ForegroundColor Green
Write-Host "Size : ${w}x${h}, ${sizeKB} KB" -ForegroundColor Green
