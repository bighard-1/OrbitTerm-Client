param(
    [string]$OutputPath = ''
)

$ErrorActionPreference = 'Stop'
Add-Type -TypeDefinition @"
using System;
using System.Runtime.InteropServices;
public static class OrbitWindowResizeProbe
{
    [StructLayout(LayoutKind.Sequential)] public struct RECT { public int Left, Top, Right, Bottom; }
    [DllImport("user32.dll")] public static extern bool GetWindowRect(IntPtr window, out RECT bounds);
    [DllImport("user32.dll")] public static extern IntPtr SendMessage(IntPtr window, uint message, IntPtr wParam, IntPtr lParam);
    [DllImport("user32.dll", EntryPoint = "GetWindowLongPtrW")] public static extern IntPtr GetWindowLongPtr(IntPtr window, int index);
}
"@

$process = Get-Process OrbitTerm.App -ErrorAction Stop |
    Where-Object { $_.MainWindowHandle -ne [IntPtr]::Zero } |
    Select-Object -First 1
if (-not $process) { throw 'OrbitTerm main window is not running in the interactive desktop session.' }
$bounds = New-Object OrbitWindowResizeProbe+RECT
if (-not [OrbitWindowResizeProbe]::GetWindowRect($process.MainWindowHandle, [ref]$bounds)) {
    throw 'Unable to read the OrbitTerm window bounds.'
}
function Invoke-HitTest([int]$x, [int]$y) {
    $packed = (($y -band 0xFFFF) -shl 16) -bor ($x -band 0xFFFF)
    [OrbitWindowResizeProbe]::SendMessage($process.MainWindowHandle, 0x0084, [IntPtr]::Zero, [IntPtr]$packed).ToInt32()
}
$middleX = [int](($bounds.Left + $bounds.Right) / 2)
$middleY = [int](($bounds.Top + $bounds.Bottom) / 2)
$results = [ordered]@{
    Left = Invoke-HitTest ($bounds.Left + 1) $middleY
    Right = Invoke-HitTest ($bounds.Right - 1) $middleY
    Top = Invoke-HitTest $middleX ($bounds.Top + 1)
    Bottom = Invoke-HitTest $middleX ($bounds.Bottom - 1)
}
$expected = @{ Left = 10; Right = 11; Top = 12; Bottom = 15 }
$report = [System.Collections.Generic.List[string]]::new()
$style = [OrbitWindowResizeProbe]::GetWindowLongPtr($process.MainWindowHandle, -16).ToInt64()
if (($style -band 0x00040000) -eq 0) {
    throw 'Native WS_THICKFRAME is missing; Win10 real edge dragging is not guaranteed.'
}
$report.Add('[PASS] Native Win10 resizable frame is present.')
foreach ($edge in $results.Keys) {
    if ($results[$edge] -ne $expected[$edge]) {
        throw "$edge resize hit-test failed: expected $($expected[$edge]), got $($results[$edge])"
    }
    $line = "[PASS] $edge resize edge -> $($results[$edge])"
    $report.Add($line)
    Write-Host $line
}
if ($OutputPath) {
    $report | Set-Content -LiteralPath $OutputPath -Encoding UTF8
}
