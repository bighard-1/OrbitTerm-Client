param(
    [string]$Root = (Resolve-Path (Join-Path $PSScriptRoot "..")).Path,
    [string]$Dotnet = "dotnet",
    [switch]$SkipFullWinUIBuild
)

$ErrorActionPreference = "Stop"

function Fail([string]$Message) {
    Write-Error $Message
    exit 1
}

function Pass([string]$Message) {
    Write-Host "[PASS] $Message"
}

function Test-IsWindowsHost {
    return [System.Environment]::OSVersion.Platform -eq [System.PlatformID]::Win32NT
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

if (-not (Get-Command $Dotnet -ErrorAction SilentlyContinue)) {
    Fail "dotnet SDK not found"
}

Invoke-Checked { & (Join-Path $Root "scripts/check_windows_static.ps1") -Root $Root } "Windows static checks"

$projects = @(
    "src/OrbitTerm.NativeBridge/OrbitTerm.NativeBridge.csproj",
    "src/OrbitTerm.Terminal/OrbitTerm.Terminal.csproj",
    "src/OrbitTerm.Application/OrbitTerm.Application.csproj",
    "src/OrbitTerm.Presentation/OrbitTerm.Presentation.csproj",
    "src/OrbitTerm.Platform.Windows/OrbitTerm.Platform.Windows.csproj"
)

foreach ($project in $projects) {
    Invoke-Checked { & $Dotnet build (Join-Path $Root $project) -c Debug } "Build $project"
}
Pass "Windows non-UI projects build"

Invoke-Checked { & $Dotnet test (Join-Path $Root "tests/OrbitTerm.Security.Tests/OrbitTerm.Security.Tests.csproj") -c Debug } "Windows security tests"
Pass "Windows security tests pass"

if ($SkipFullWinUIBuild) {
    Write-Host "[INFO] Full WinUI build skipped by caller."
} elseif (Test-IsWindowsHost) {
    Invoke-Checked { & $Dotnet build (Join-Path $Root "OrbitTerm.Windows.sln") -c Debug } "Full WinUI solution build"
    Pass "Full WinUI solution builds on Windows"
} else {
    Write-Host "[INFO] Full WinUI build skipped because Windows App SDK XAML compilation requires Windows."
}

Pass "Windows toolchain checks"
