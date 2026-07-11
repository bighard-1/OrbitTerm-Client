param(
    [string]$Root = (Resolve-Path (Join-Path $PSScriptRoot "..")).Path,
    [string]$RepoRoot = (Resolve-Path (Join-Path $PSScriptRoot "..\..\..")).Path,
    [string]$ExpectedRootPrefix = "D:\Macmini2",
    [string]$OutputRoot = "",
    [string]$Dotnet = "dotnet",
    [string]$Cargo = "cargo"
)

$ErrorActionPreference = "Stop"
Set-StrictMode -Version Latest

function Fail([string]$Message) {
    Write-Error $Message
    exit 1
}

function Pass([string]$Message) {
    Write-Host "[PASS] $Message"
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
    if (-not $resolved.Equals($expected, [System.StringComparison]::OrdinalIgnoreCase) -and
        -not $resolved.StartsWith("$expected\", [System.StringComparison]::OrdinalIgnoreCase)) {
        Fail "$Description must stay under $expected. Actual path: $resolved"
    }

    return $resolved
}

function Assert-NewPathUnderExpectedRoot([string]$Path, [string]$Description) {
    $candidate = [System.IO.Path]::GetFullPath($Path).TrimEnd("\", "/")
    $expected = (Resolve-Path $ExpectedRootPrefix).Path.TrimEnd("\", "/")
    if (-not $candidate.Equals($expected, [System.StringComparison]::OrdinalIgnoreCase) -and
        -not $candidate.StartsWith("$expected\", [System.StringComparison]::OrdinalIgnoreCase)) {
        Fail "$Description must stay under $expected. Actual path: $candidate"
    }

    return $candidate
}

if ([System.Environment]::OSVersion.Platform -ne [System.PlatformID]::Win32NT -or
    -not [System.Environment]::Is64BitOperatingSystem) {
    Fail "Portable OrbitTerm build requires 64-bit Windows."
}

if (!(Test-Path $ExpectedRootPrefix)) {
    Fail "Expected Windows validation root does not exist: $ExpectedRootPrefix"
}

$Root = Assert-UnderExpectedRoot $Root "Windows client root"
$RepoRoot = Assert-UnderExpectedRoot $RepoRoot "Repository root"
if ([string]::IsNullOrWhiteSpace($OutputRoot)) {
    $OutputRoot = Join-Path $ExpectedRootPrefix "OrbitTerm-Portable"
}

$OutputRoot = Assert-NewPathUnderExpectedRoot $OutputRoot "Portable output root"

if (Test-Path $OutputRoot) {
    Fail "Portable output root already exists: $OutputRoot"
}

if (!(Get-Command $Dotnet -ErrorAction SilentlyContinue) -or
    !(Get-Command $Cargo -ErrorAction SilentlyContinue)) {
    Fail "Portable build requires both dotnet SDK and cargo."
}

$project = Join-Path $Root "src\OrbitTerm.App\OrbitTerm.App.csproj"
if (!(Test-Path $project)) {
    Fail "Windows app project not found: $project"
}

Invoke-Checked {
    & (Join-Path $Root "scripts\build_windows_core.ps1") -RepoRoot $RepoRoot -Cargo $Cargo
} "Windows orbit-core build"

New-Item -ItemType Directory -Path $OutputRoot | Out-Null
Invoke-Checked {
    & $Dotnet publish $project `
        -c Release `
        -r win-x64 `
        --self-contained true `
        -p:Platform=x64 `
        -p:WindowsPackageType=None `
        -p:WindowsAppSDKSelfContained=true `
        -p:GenerateAppxPackageOnBuild=false `
        -o $OutputRoot
} "Self-contained unpackaged WinUI publish"

$coreDll = Join-Path $RepoRoot "orbit-core\target\x86_64-pc-windows-msvc\release\orbit_core.dll"
$appExecutable = Join-Path $OutputRoot "OrbitTerm.App.exe"
if (!(Test-Path $coreDll) -or !(Test-Path $appExecutable)) {
    Fail "Portable publish is missing its app executable or orbit_core.dll build output."
}

Copy-Item -LiteralPath $coreDll -Destination (Join-Path $OutputRoot "orbit_core.dll") -Force
if (!(Test-Path (Join-Path $OutputRoot "orbit_core.dll"))) {
    Fail "Portable publish did not include orbit_core.dll."
}

Pass "Self-contained portable OrbitTerm output is complete"
