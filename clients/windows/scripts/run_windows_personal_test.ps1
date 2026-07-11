param(
    [string]$Root = (Resolve-Path (Join-Path $PSScriptRoot "..")).Path,
    [ValidateSet("Debug", "Release")]
    [string]$Configuration = "Debug",
    [ValidateSet("x64")]
    [string]$Platform = "x64",
    [string]$Dotnet = "dotnet",
    [switch]$NoLaunch,
    [switch]$SkipStaticGate
)

$ErrorActionPreference = "Stop"
Set-StrictMode -Version Latest

function Fail([string]$Message) {
    Write-Error $Message
    exit 1
}

function Info([string]$Message) {
    Write-Host "[INFO] $Message"
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

if (-not (Test-IsWindowsHost)) {
    Fail "Personal Windows app launch requires a Windows host."
}

if (-not (Get-Command $Dotnet -ErrorAction SilentlyContinue)) {
    Fail "dotnet SDK not found"
}

if ($SkipStaticGate) {
    Info "Windows static gate skipped by caller."
}
else {
    $staticGate = Join-Path $Root "scripts\check_windows_static.ps1"
    if (!(Test-Path $staticGate)) {
        Fail "Windows static gate not found: $staticGate"
    }

    Invoke-Checked { & $staticGate -Root $Root } "Windows static gate"
}

$appProject = Join-Path $Root "src\OrbitTerm.App\OrbitTerm.App.csproj"
if (!(Test-Path $appProject)) {
    Fail "Windows app project not found: $appProject"
}

Invoke-Checked {
    & $Dotnet build $appProject -c $Configuration -p:Platform=$Platform
} "Build OrbitTerm Windows app"

$outputRoot = Join-Path $Root "src\OrbitTerm.App\bin\$Platform\$Configuration"
if (!(Test-Path $outputRoot)) {
    Fail "Windows app output directory not found: $outputRoot"
}

$appExecutable = Get-ChildItem $outputRoot -Recurse -File -Filter "OrbitTerm.App.exe" |
    Sort-Object LastWriteTime -Descending |
    Select-Object -First 1

if ($null -eq $appExecutable) {
    Fail "OrbitTerm.App.exe was not found under $outputRoot after build."
}

Info "Windows app executable: $($appExecutable.FullName)"

if ($NoLaunch) {
    Info "Launch skipped by caller."
    exit 0
}

Start-Process -FilePath $appExecutable.FullName -WorkingDirectory $appExecutable.DirectoryName
Info "OrbitTerm Windows app launched."
