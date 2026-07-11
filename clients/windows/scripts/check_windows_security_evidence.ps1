param(
    [string]$Root = (Resolve-Path (Join-Path $PSScriptRoot "..")).Path
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

function Assert-File([string]$RelativePath, [string]$Description) {
    $path = Join-Path $Root $RelativePath
    if (!(Test-Path $path)) {
        Fail "$Description missing: $RelativePath"
    }

    return $path
}

$bundle = Read-Json (Join-Path $Root "release\security-evidence.json")
if ([string]$bundle.schema_version -ne "1") {
    Fail "security-evidence schema_version must be 1."
}

if ($bundle.product -ne "OrbitTerm") {
    Fail "security-evidence product must be OrbitTerm."
}

if ($bundle.package_identity -ne "OrbitTerm.Client") {
    Fail "security-evidence package_identity must be OrbitTerm.Client."
}

if ($bundle.version -notmatch "^\d+\.\d+\.\d+\.\d+$") {
    Fail "security-evidence version must be a four-part numeric version."
}

$manifest = [xml](Get-Content (Assert-File "src\OrbitTerm.App\Package.appxmanifest" "Package manifest") -Raw)
$namespaceManager = New-Object System.Xml.XmlNamespaceManager($manifest.NameTable)
$namespaceManager.AddNamespace("m", "http://schemas.microsoft.com/appx/manifest/foundation/windows10")
$identity = $manifest.SelectSingleNode("/m:Package/m:Identity", $namespaceManager)
if ($null -eq $identity) {
    Fail "Package manifest identity is missing."
}

if ($identity.Name -ne $bundle.package_identity -or $identity.Version -ne $bundle.version) {
    Fail "security-evidence package identity/version must match Package.appxmanifest."
}

foreach ($document in $bundle.evidence_documents) {
    $path = Assert-File $document "Evidence document"
    $text = Get-Content $path -Raw
    if ([string]::IsNullOrWhiteSpace($text)) {
        Fail "Evidence document is empty: $document"
    }

    if ($document -like "docs/PHASE-3*-EVIDENCE.md" -and $text -match "(?m)^- Pending\.$") {
        Fail "Phase 3 evidence document is still pending: $document"
    }
}

foreach ($artifact in $bundle.release_artifacts) {
    [void](Assert-File $artifact "Release artifact")
}

foreach ($script in $bundle.validation_scripts) {
    [void](Assert-File $script "Validation script")
}

$requiredGates = @(
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
    if ($bundle.required_release_gates -notcontains $gate) {
        Fail "Required release gate missing from security evidence: $gate"
    }
}

Pass "Windows security evidence bundle is complete"
