param(
    [string]$Winget = "winget"
)

$ErrorActionPreference = "Stop"

function Fail([string]$Message) {
    Write-Error $Message
    exit 1
}

function Pass([string]$Message) {
    Write-Host "[PASS] $Message"
}

function Invoke-CheckedProcess([string]$FilePath, [string[]]$Arguments, [string]$Description) {
    $process = Start-Process -FilePath $FilePath -ArgumentList $Arguments -Wait -PassThru -NoNewWindow
    if ($process.ExitCode -ne 0) {
        Fail "$Description failed with exit code $($process.ExitCode)"
    }
}

function Get-VsWherePath {
    $programFilesX86 = [Environment]::GetFolderPath("ProgramFilesX86")
    return Join-Path $programFilesX86 "Microsoft Visual Studio\Installer\vswhere.exe"
}

if (-not (Get-Command $Winget -ErrorAction SilentlyContinue)) {
    Fail "winget not found"
}

if (-not (Get-Command cargo -ErrorAction SilentlyContinue)) {
    Invoke-CheckedProcess $Winget @(
        "install",
        "--id",
        "Rustlang.Rust.MSVC",
        "-e",
        "--accept-package-agreements",
        "--accept-source-agreements"
    ) "Rust MSVC installation"
}
Pass "Rust MSVC is available"

$vswhere = Get-VsWherePath
$hasVcTools = $false
if (Test-Path $vswhere) {
    $vcPath = & $vswhere -latest -products * -requires Microsoft.VisualStudio.Component.VC.Tools.x86.x64 -property installationPath
    $hasVcTools = -not [string]::IsNullOrWhiteSpace($vcPath)
}

if (-not $hasVcTools) {
    Invoke-CheckedProcess $Winget @(
        "install",
        "--id",
        "Microsoft.VisualStudio.2022.BuildTools",
        "-e",
        "--silent",
        "--accept-package-agreements",
        "--accept-source-agreements",
        "--override",
        "--quiet --wait --norestart --add Microsoft.VisualStudio.Workload.VCTools --includeRecommended"
    ) "Visual Studio C++ Build Tools installation"
}
Pass "Visual Studio C++ Build Tools are available"

Pass "Windows dependencies"
