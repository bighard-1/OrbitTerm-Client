$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

$app = Get-StartApps | Where-Object { $_.Name -eq 'OrbitTerm' } | Select-Object -First 1
if ($null -eq $app -or [string]::IsNullOrWhiteSpace($app.AppID)) {
    throw 'The installed OrbitTerm application entry was not found.'
}

Get-Process 'OrbitTerm.App' -ErrorAction SilentlyContinue | Stop-Process -Force
Start-Sleep -Milliseconds 350
Start-Process -FilePath 'explorer.exe' -ArgumentList "shell:AppsFolder\$($app.AppID)"

# Explorer activation is asynchronous.  Bring the resulting WinUI window to
# the foreground from the same interactive desktop so a successful launch is
# immediately visible instead of remaining behind an open PowerShell/RDP
# window.  AppActivate is best-effort and does not affect startup correctness.
$deadline = [DateTimeOffset]::UtcNow.AddSeconds(12)
do {
    Start-Sleep -Milliseconds 250
    $process = Get-Process 'OrbitTerm.App' -ErrorAction SilentlyContinue |
        Sort-Object StartTime -Descending |
        Select-Object -First 1
} while ($null -eq $process -and [DateTimeOffset]::UtcNow -lt $deadline)

if ($null -ne $process) {
    try {
        $shell = New-Object -ComObject WScript.Shell
        $null = $shell.AppActivate($process.Id)
        # WinUI windows with a custom title bar are not always reliably raised
        # by WScript on Windows 10. Resolve the owned top-level HWND and raise
        # that exact window as a second, deterministic activation attempt.
        Add-Type @'
using System;
using System.Runtime.InteropServices;
public static class OrbitWindowActivation
{
    public delegate bool EnumWindowsProc(IntPtr hwnd, IntPtr parameter);
    [DllImport("user32.dll")] public static extern bool EnumWindows(EnumWindowsProc callback, IntPtr parameter);
    [DllImport("user32.dll")] public static extern uint GetWindowThreadProcessId(IntPtr hwnd, out uint processId);
    [DllImport("user32.dll")] public static extern bool IsWindowVisible(IntPtr hwnd);
    [DllImport("user32.dll")] public static extern bool ShowWindowAsync(IntPtr hwnd, int command);
    [DllImport("user32.dll")] public static extern bool SetForegroundWindow(IntPtr hwnd);
}
'@
        $script:orbitWindowHandle = [IntPtr]::Zero
        [OrbitWindowActivation]::EnumWindows({
            param([IntPtr]$candidate, [IntPtr]$parameter)
            [uint32]$ownerProcessId = 0
            [OrbitWindowActivation]::GetWindowThreadProcessId($candidate, [ref]$ownerProcessId) | Out-Null
            if ($ownerProcessId -eq $process.Id -and [OrbitWindowActivation]::IsWindowVisible($candidate)) {
                $script:orbitWindowHandle = $candidate
                return $false
            }
            return $true
        }, [IntPtr]::Zero) | Out-Null
        if ($script:orbitWindowHandle -ne [IntPtr]::Zero) {
            [OrbitWindowActivation]::ShowWindowAsync($script:orbitWindowHandle, 9) | Out-Null
            [OrbitWindowActivation]::SetForegroundWindow($script:orbitWindowHandle) | Out-Null
        }
    }
    catch {
        # Foreground activation can be denied by Windows focus-stealing rules;
        # the application remains successfully launched in that case.
    }
}
