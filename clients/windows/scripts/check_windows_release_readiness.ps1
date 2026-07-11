param(
    [string]$Root = (Resolve-Path (Join-Path $PSScriptRoot "..")).Path,
    [switch]$RequireExternalDistribution
)

$ErrorActionPreference = "Stop"

function Fail([string]$Message) {
    Write-Error $Message
    exit 1
}

function Pass([string]$Message) {
    Write-Host "[PASS] $Message"
}

function Read-Json([string]$Path) {
    if (!(Test-Path $Path)) {
        Fail "Required JSON file missing: $Path"
    }

    return Get-Content $Path -Raw | ConvertFrom-Json
}

function Assert-Version([string]$Name, [string]$Value) {
    if ($Value -notmatch "^\d+\.\d+\.\d+\.\d+$") {
        Fail "$Name must use a four-part numeric version. Actual: '$Value'."
    }
}

function Assert-RequiredValue([string]$Name, [object]$Actual, [object]$Expected) {
    if ($Actual -ne $Expected) {
        Fail "$Name must be '$Expected'. Actual: '$Actual'."
    }
}

function Test-HasGate([object[]]$Gates, [string]$Gate) {
    return $Gates -contains $Gate
}

$readiness = Read-Json (Join-Path $Root "release\release-readiness.json")
$channel = Read-Json (Join-Path $Root "release\update-channel.json")
$evidence = Read-Json (Join-Path $Root "release\security-evidence.json")

$manifestPath = Join-Path $Root "src\OrbitTerm.App\Package.appxmanifest"
if (!(Test-Path $manifestPath)) {
    Fail "Package manifest missing: $manifestPath"
}

$manifest = [xml](Get-Content $manifestPath -Raw)
$namespaceManager = New-Object System.Xml.XmlNamespaceManager($manifest.NameTable)
$namespaceManager.AddNamespace("m", "http://schemas.microsoft.com/appx/manifest/foundation/windows10")
$identity = $manifest.SelectSingleNode("/m:Package/m:Identity", $namespaceManager)
if ($null -eq $identity) {
    Fail "Package manifest identity is missing."
}

Assert-RequiredValue "release-readiness schema_version" ([string]$readiness.schema_version) "1"
Assert-RequiredValue "release-readiness product" $readiness.product "OrbitTerm"
Assert-RequiredValue "release-readiness package_identity" $readiness.package_identity $identity.Name
Assert-RequiredValue "release-readiness version" $readiness.version $identity.Version
Assert-Version "release-readiness version" $readiness.version

Assert-RequiredValue "release-readiness package_identity/update-channel package_identity" $readiness.package_identity $channel.package_identity
Assert-RequiredValue "release-readiness version/update-channel version" $readiness.version $channel.version
Assert-RequiredValue "release-readiness package_identity/security-evidence package_identity" $readiness.package_identity $evidence.package_identity
Assert-RequiredValue "release-readiness version/security-evidence version" $readiness.version $evidence.version

if ($readiness.internal_release_candidate_ready -ne $true) {
    Fail "Internal release candidate readiness must be explicitly true."
}

if ($channel.requires_signed_package -ne $true) {
    Fail "Update channel must require signed packages."
}

if ($channel.requires_https_update_uri -ne $true) {
    Fail "Update channel must require HTTPS update URIs."
}

$requiredGates = @(
    "windows-toolchain",
    "windows-host-plan-validation",
    "checked-ffi-only",
    "host-key-verified-sessions",
    "windows-secure-credential-storage",
    "release-candidate-gate",
    "msix-package-identity",
    "signed-package-contract",
    "update-channel-contract",
    "redacted-diagnostics",
    "release-quality-smoke",
    "security-evidence-bundle",
    "full-winui-host-build"
)

foreach ($gate in $requiredGates) {
    if (-not (Test-HasGate $readiness.required_gates $gate)) {
        Fail "Release readiness required gate missing: $gate"
    }
}

if ($RequireExternalDistribution) {
    if ($readiness.readiness_profile -ne "external-commercial-release") {
        Fail "External distribution requires readiness_profile external-commercial-release."
    }

    if ($readiness.external_distribution_enabled -ne $true -or $channel.external_distribution_enabled -ne $true) {
        Fail "External distribution requires both readiness and update channel to be enabled."
    }

    if ($readiness.external_distribution_blockers.Count -ne 0) {
        Fail "External distribution blockers must be empty before commercial release."
    }

    foreach ($field in @("appinstaller_uri", "package_uri")) {
        $value = [string]$channel.$field
        if (-not $value.StartsWith("https://", [System.StringComparison]::OrdinalIgnoreCase)) {
            Fail "External distribution requires HTTPS $field."
        }
    }
}
else {
    Assert-RequiredValue "release-readiness profile" $readiness.readiness_profile "internal-release-candidate"
    Assert-RequiredValue "release-readiness external_distribution_enabled" $readiness.external_distribution_enabled $false
    Assert-RequiredValue "update-channel external_distribution_enabled" $channel.external_distribution_enabled $false

    if ($readiness.external_distribution_blockers.Count -lt 3) {
        Fail "Internal release readiness must list concrete external distribution blockers."
    }

    if (-not [string]::IsNullOrWhiteSpace([string]$channel.appinstaller_uri) -or -not [string]::IsNullOrWhiteSpace([string]$channel.package_uri)) {
        Fail "Internal release candidate profile must not define production update URIs."
    }

    if ($channel.rollout.mode -ne "manual" -or $channel.rollout.percentage -ne 0) {
        Fail "Internal release candidate rollout must remain manual at 0 percent."
    }
}

Pass "Windows release readiness gate"
