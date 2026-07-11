param(
    [string]$Root = (Resolve-Path (Join-Path $PSScriptRoot "..")).Path,
    [string]$RepoRoot = (Resolve-Path (Join-Path $PSScriptRoot "..\..\..")).Path,
    [string]$ExpectedRootPrefix = "D:\Macmini2",
    [string]$Dotnet = "dotnet",
    [string]$Cargo = "cargo",
    [string]$Configuration = "Debug"
)

$ErrorActionPreference = "Stop"

function Fail([string]$Message) {
    Write-Error $Message
    exit 1
}

function Pass([string]$Message) {
    Write-Host "[PASS] $Message"
}

function Info([string]$Message) {
    Write-Host "[INFO] $Message"
}

function Invoke-Checked([scriptblock]$Command, [string]$Description) {
    $global:LASTEXITCODE = 0
    & $Command
    if (-not $?) {
        Fail "$Description failed"
    }

    if ($LASTEXITCODE -ne 0) {
        Fail "$Description failed with exit code $LASTEXITCODE"
    }
}

function Assert-UnderExpectedRoot([string]$Path, [string]$Description) {
    $resolved = (Resolve-Path $Path).Path.TrimEnd("\", "/")
    $expected = (Resolve-Path $ExpectedRootPrefix).Path.TrimEnd("\", "/")
    $expectedWithSeparator = "$expected\"

    if (
        -not $resolved.Equals($expected, [System.StringComparison]::OrdinalIgnoreCase) -and
        -not $resolved.StartsWith($expectedWithSeparator, [System.StringComparison]::OrdinalIgnoreCase)
    ) {
        Fail "$Description must stay under $expected. Actual path: $resolved"
    }

    return $resolved
}

function Test-IsWindowsHost {
    return [System.Environment]::OSVersion.Platform -eq [System.PlatformID]::Win32NT
}

if (-not (Test-IsWindowsHost)) {
    Fail "Windows host validation must run on Windows x64."
}

if (-not [System.Environment]::Is64BitOperatingSystem) {
    Fail "Windows host validation requires a 64-bit Windows OS."
}

if (!(Test-Path $ExpectedRootPrefix)) {
    Fail "Expected Windows validation root does not exist: $ExpectedRootPrefix"
}

$Root = Assert-UnderExpectedRoot $Root "Windows client root"
$RepoRoot = Assert-UnderExpectedRoot $RepoRoot "Repository root"
Pass "Validation paths are restricted to $ExpectedRootPrefix"

if (-not (Get-Command $Dotnet -ErrorAction SilentlyContinue)) {
    Fail "dotnet SDK not found"
}

if (-not (Get-Command $Cargo -ErrorAction SilentlyContinue)) {
    Fail "cargo not found"
}

Info "Running Windows toolchain checks"
Invoke-Checked { & (Join-Path $Root "scripts/check_windows_toolchain.ps1") -Root $Root -Dotnet $Dotnet -SkipFullWinUIBuild } "Windows toolchain checks"
Pass "Windows toolchain checks completed"

Info "Building orbit-core for Windows x64 MSVC"
Invoke-Checked { & (Join-Path $Root "scripts/build_windows_core.ps1") -RepoRoot $RepoRoot -Cargo $Cargo } "orbit-core Windows x64 MSVC build"

$dll = Join-Path $RepoRoot "orbit-core\target\x86_64-pc-windows-msvc\release\orbit_core.dll"
if (!(Test-Path $dll)) {
    Fail "Expected orbit_core.dll was not produced: $dll"
}

Add-Type -TypeDefinition @"
using System;
using System.Runtime.InteropServices;

public static class OrbitTermNativeLoadSmoke
{
    [DllImport("kernel32", SetLastError = true, CharSet = CharSet.Unicode)]
    public static extern IntPtr LoadLibraryW(string fileName);

    [DllImport("kernel32", SetLastError = true, CharSet = CharSet.Ansi)]
    public static extern IntPtr GetProcAddress(IntPtr module, string name);

    [DllImport("kernel32", SetLastError = true)]
    public static extern bool FreeLibrary(IntPtr module);
}
"@

$handle = [OrbitTermNativeLoadSmoke]::LoadLibraryW($dll)
if ($handle -eq [System.IntPtr]::Zero) {
    $errorCode = [System.Runtime.InteropServices.Marshal]::GetLastWin32Error()
    Fail "LoadLibraryW failed for $dll with Win32 error $errorCode"
}

try {
    $exports = @(
        "orbit_ssh_connect_checked_v1",
        "orbit_terminal_open_checked_v1",
        "orbit_terminal_write",
        "orbit_terminal_resize",
        "orbit_terminal_close",
        "orbit_terminal_set_callback",
        "orbit_free_string"
    )

    foreach ($export in $exports) {
        $symbol = [OrbitTermNativeLoadSmoke]::GetProcAddress($handle, $export)
        if ($symbol -eq [System.IntPtr]::Zero) {
            Fail "Required native export missing from orbit_core.dll: $export"
        }
    }
}
finally {
    if ($handle -ne [System.IntPtr]::Zero) {
        [void][OrbitTermNativeLoadSmoke]::FreeLibrary($handle)
    }
}

Pass "orbit_core.dll loads and exposes required checked terminal exports"

$solution = Join-Path $Root "OrbitTerm.Windows.sln"
Info "Restoring and building full WinUI solution"
Invoke-Checked { & $Dotnet restore $solution } "Full WinUI solution restore"
Invoke-Checked { & $Dotnet build $solution -c $Configuration -p:Platform=x64 } "Full WinUI solution build"
Pass "Full WinUI solution builds on Windows x64"

Pass "Windows host validation"
