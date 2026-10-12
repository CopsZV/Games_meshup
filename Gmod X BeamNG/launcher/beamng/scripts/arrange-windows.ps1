# Places the BeamNG and Minecraft windows so both are visible with the same client size.
#
#   scripts\arrange-windows.ps1                 # side by side on the primary screen, 944x531 each
#   scripts\arrange-windows.ps1 -Width 1280     # client width per window (height follows 16:9)
#   scripts\arrange-windows.ps1 -Stack          # Minecraft exactly over BeamNG (overlay tests)
param(
    [int]$Width = 944,
    [switch]$Stack
)
$ErrorActionPreference = 'Stop'
Add-Type @'
using System;
using System.Runtime.InteropServices;
public static class ArrWin {
    [StructLayout(LayoutKind.Sequential)] public struct RECT { public int Left, Top, Right, Bottom; }
    [DllImport("user32.dll")] public static extern bool SetProcessDPIAware();
    [DllImport("user32.dll")] public static extern bool GetWindowRect(IntPtr h, out RECT r);
    [DllImport("user32.dll")] public static extern bool GetClientRect(IntPtr h, out RECT r);
    [DllImport("user32.dll")] public static extern bool SetWindowPos(IntPtr h, IntPtr after, int x, int y, int w, int cy, uint flags);
    [DllImport("user32.dll")] public static extern bool ShowWindow(IntPtr h, int cmd);
}
'@
[ArrWin]::SetProcessDPIAware() | Out-Null
$height = [int][Math]::Round($Width * 9 / 16)

function Get-Win([string]$name) {
    $p = Get-Process -Name $name -ErrorAction SilentlyContinue | Where-Object { $_.MainWindowHandle -ne 0 } | Select-Object -First 1
    if (-not $p) { throw "no window for $name" }
    return $p.MainWindowHandle
}

# Outer size that gives the wanted client size (window borders/title bar differ per window).
function Set-Client([IntPtr]$h, [int]$x, [int]$y, [int]$cw, [int]$ch) {
    [ArrWin]::ShowWindow($h, 9) | Out-Null   # SW_RESTORE (un-maximise)
    $w = New-Object ArrWin+RECT; $c = New-Object ArrWin+RECT
    [ArrWin]::GetWindowRect($h, [ref]$w) | Out-Null
    [ArrWin]::GetClientRect($h, [ref]$c) | Out-Null
    $bw = ($w.Right - $w.Left) - ($c.Right - $c.Left)
    $bh = ($w.Bottom - $w.Top) - ($c.Bottom - $c.Top)
    [ArrWin]::SetWindowPos($h, [IntPtr]::Zero, $x, $y, $cw + $bw, $ch + $bh, 0x0040) | Out-Null   # SWP_SHOWWINDOW
    Start-Sleep -Milliseconds 200
    [ArrWin]::GetClientRect($h, [ref]$c) | Out-Null
    return "$($c.Right - $c.Left)x$($c.Bottom - $c.Top)"
}

$bng = Get-Win 'BeamNG.drive.x64'
$mc = Get-Win 'java'
if ($Stack) {
    $b = Set-Client $bng 100 60 $Width $height
    $m = Set-Client $mc 100 60 $Width $height
} else {
    $b = Set-Client $bng 0 0 $Width $height
    $m = Set-Client $mc ($Width + 24) 0 $Width $height
}
Write-Output "BeamNG client $b, Minecraft client $m"
