param(
    [string]$Root = (Resolve-Path (Join-Path $PSScriptRoot "..")).Path,
    [string]$RepoRoot = (Resolve-Path (Join-Path $PSScriptRoot "..\..\..")).Path,
    [string]$ExpectedRootPrefix = "D:\Macmini2",
    [string]$Dotnet = "dotnet",
    [string]$Cargo = "cargo",
    [string]$Configuration = "Release",
    [string]$SigningCertificateThumbprint = "",
    [string]$OutputRoot = "",
    [switch]$PlanOnly
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

function Assert-UnderExpectedRoot([string]$Path, [string]$Description) {
    if ([string]::IsNullOrWhiteSpace($Path)) {
        Fail "$Description is required."
    }

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

function Read-Xml([string]$Path) {
    if (!(Test-Path $Path)) {
        Fail "Required XML file missing: $Path"
    }

    [xml]$xml = Get-Content $Path -Raw
    return $xml
}

function Get-PackagePublisher([string]$Root) {
    $manifest = Read-Xml (Join-Path $Root "src\OrbitTerm.App\Package.appxmanifest")
    $namespaceManager = New-Object System.Xml.XmlNamespaceManager($manifest.NameTable)
    $namespaceManager.AddNamespace("m", "http://schemas.microsoft.com/appx/manifest/foundation/windows10")
    $identity = $manifest.SelectSingleNode("/m:Package/m:Identity", $namespaceManager)
    if ($null -eq $identity -or $null -eq $identity.Attributes["Publisher"]) {
        Fail "Package manifest publisher is required."
    }

    return $identity.Attributes["Publisher"].Value
}

function Get-SigningCertificate([string]$Thumbprint, [string]$ExpectedPublisher) {
    if ([string]::IsNullOrWhiteSpace($Thumbprint)) {
        if ($PlanOnly) {
            Info "Plan-only mode: no package will be built without a signing certificate thumbprint."
            return $null
        }

        Fail "SigningCertificateThumbprint is required to build a signed distributable package."
    }

    $normalizedThumbprint = $Thumbprint.Replace(" ", "").ToUpperInvariant()
    if ($normalizedThumbprint -notmatch "^[0-9A-F]{40,128}$") {
        Fail "SigningCertificateThumbprint must be a hexadecimal certificate thumbprint."
    }

    $stores = @("Cert:\CurrentUser\My", "Cert:\LocalMachine\My")
    foreach ($store in $stores) {
        $cert = Get-ChildItem $store -ErrorAction SilentlyContinue |
            Where-Object { $_.Thumbprint.ToUpperInvariant() -eq $normalizedThumbprint } |
            Select-Object -First 1
        if ($null -eq $cert) {
            continue
        }

        if (-not $cert.HasPrivateKey) {
            Fail "Signing certificate must include a private key."
        }

        if ($cert.NotAfter -le (Get-Date)) {
            Fail "Signing certificate is expired."
        }

        if ($cert.Subject -ne $ExpectedPublisher) {
            Fail "Signing certificate subject must match manifest publisher '$ExpectedPublisher'. Actual: '$($cert.Subject)'."
        }

        return $cert
    }

    Fail "Signing certificate was not found in CurrentUser or LocalMachine personal certificate stores."
}

if (-not (Test-IsWindowsHost)) {
    Fail "Signed package build must run on Windows x64."
}

if (-not [System.Environment]::Is64BitOperatingSystem) {
    Fail "Signed package build requires a 64-bit Windows OS."
}

if ($Configuration -ne "Release") {
    Fail "Signed package build must use Release configuration."
}

if (!(Test-Path $ExpectedRootPrefix)) {
    Fail "Expected Windows validation root does not exist: $ExpectedRootPrefix"
}

$Root = Assert-UnderExpectedRoot $Root "Windows client root"
$RepoRoot = Assert-UnderExpectedRoot $RepoRoot "Repository root"

if ([string]::IsNullOrWhiteSpace($OutputRoot)) {
    $OutputRoot = Join-Path $ExpectedRootPrefix "OrbitTerm-Release"
}

if (!(Test-Path $OutputRoot)) {
    New-Item -ItemType Directory -Force $OutputRoot | Out-Null
}

$OutputRoot = Assert-UnderExpectedRoot $OutputRoot "Signed package output root"
Pass "Signed package paths are restricted to $ExpectedRootPrefix"

if (-not (Get-Command $Dotnet -ErrorAction SilentlyContinue)) {
    Fail "dotnet SDK not found"
}

if (-not (Get-Command $Cargo -ErrorAction SilentlyContinue)) {
    Fail "cargo not found"
}

$publisher = Get-PackagePublisher $Root
$certificate = Get-SigningCertificate $SigningCertificateThumbprint $publisher

if ($PlanOnly) {
    Pass "Signed package build plan is valid"
    if ($null -eq $certificate) {
        Pass "Plan-only mode refused unsigned package output"
    }

    exit 0
}

Info "Running signed release candidate gate"
Invoke-Checked {
    & (Join-Path $Root "scripts\check_windows_release_candidate.ps1") `
        -Root $Root `
        -RepoRoot $RepoRoot `
        -ExpectedRootPrefix $ExpectedRootPrefix `
        -Dotnet $Dotnet `
        -Cargo $Cargo `
        -Configuration Release `
        -SigningCertificateThumbprint $SigningCertificateThumbprint
} "Signed release candidate gate"

$project = Join-Path $Root "src\OrbitTerm.App\OrbitTerm.App.csproj"
$packageDir = Join-Path $OutputRoot "AppPackages"
New-Item -ItemType Directory -Force $packageDir | Out-Null

Info "Building signed MSIX package"
Invoke-Checked {
    & $Dotnet publish $project `
        -c Release `
        -p:Platform=x64 `
        -p:GenerateAppxPackageOnBuild=true `
        -p:AppxPackageSigningEnabled=true `
        -p:PackageCertificateThumbprint=$SigningCertificateThumbprint `
        -p:AppxPackageDir="$packageDir\" `
        -p:AppxBundle=Never `
        -p:UapAppxPackageBuildMode=StoreUpload
} "Signed MSIX package build"

$packages = Get-ChildItem $packageDir -Recurse -File |
    Where-Object { $_.Extension -in ".msix", ".appx", ".msixbundle", ".appxbundle" }

if ($packages.Count -eq 0) {
    Fail "Signed package build completed without producing an MSIX/AppX package."
}

foreach ($package in $packages) {
    if ($package.Length -le 0) {
        Fail "Signed package is empty: $($package.FullName)"
    }
}

Pass "Signed MSIX package build produced package output"
