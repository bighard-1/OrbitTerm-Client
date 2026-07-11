param(
    [string]$RepoRoot = (Resolve-Path (Join-Path $PSScriptRoot "..\..\..")).Path,
    [string]$Cargo = "cargo"
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

if (-not (Test-IsWindowsHost)) {
    Fail "Windows orbit-core build must run on Windows with the MSVC Rust target."
}

if (-not (Get-Command $Cargo -ErrorAction SilentlyContinue)) {
    Fail "cargo not found"
}

$core = Join-Path $RepoRoot "orbit-core"
Invoke-Checked { & $Cargo build --manifest-path (Join-Path $core "Cargo.toml") --locked --target x86_64-pc-windows-msvc } "orbit-core Windows debug build"
Invoke-Checked { & $Cargo build --manifest-path (Join-Path $core "Cargo.toml") --locked --release --target x86_64-pc-windows-msvc } "orbit-core Windows release build"

$dll = Join-Path $core "target\x86_64-pc-windows-msvc\release\orbit_core.dll"
if (!(Test-Path $dll)) {
    Fail "Expected orbit_core.dll was not produced: $dll"
}

Pass "orbit-core Windows x64 MSVC build"
