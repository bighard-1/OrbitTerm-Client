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

function Read-Xml([string]$Path) {
    if (!(Test-Path $Path)) {
        Fail "Required XML file missing: $Path"
    }

    [xml]$xml = Get-Content $Path -Raw
    return $xml
}

function Assert-Equal([string]$Name, [string]$Actual, [string]$Expected) {
    if ($Actual -ne $Expected) {
        Fail "$Name must be '$Expected'. Actual: '$Actual'."
    }
}

function Assert-Version([string]$Name, [string]$Value) {
    if ($Value -notmatch "^\d+\.\d+\.\d+\.\d+$") {
        Fail "$Name must use four-part numeric version format. Actual: '$Value'."
    }
}

$channelPath = Join-Path $Root "release\update-channel.json"
$manifestPath = Join-Path $Root "src\OrbitTerm.App\Package.appxmanifest"
$channel = Read-Json $channelPath
$manifest = Read-Xml $manifestPath

$namespaceManager = New-Object System.Xml.XmlNamespaceManager($manifest.NameTable)
$namespaceManager.AddNamespace("m", "http://schemas.microsoft.com/appx/manifest/foundation/windows10")
$identity = $manifest.SelectSingleNode("/m:Package/m:Identity", $namespaceManager)
if ($null -eq $identity) {
    Fail "Package manifest identity is missing."
}

$target = $manifest.SelectSingleNode("/m:Package/m:Dependencies/m:TargetDeviceFamily", $namespaceManager)
if ($null -eq $target) {
    Fail "Package manifest target device family is missing."
}

Assert-Equal "schema_version" ([string]$channel.schema_version) "1"
Assert-Equal "product" $channel.product "OrbitTerm"
Assert-Equal "channel" $channel.channel "stable"
Assert-Equal "package_identity" $channel.package_identity $identity.Name
Assert-Equal "publisher" $channel.publisher $identity.Publisher
Assert-Equal "version" $channel.version $identity.Version
Assert-Equal "minimum_windows_version" $channel.minimum_windows_version $target.MinVersion
Assert-Equal "update_transport" $channel.update_transport "appinstaller"
Assert-Version "version" $channel.version
Assert-Version "minimum_windows_version" $channel.minimum_windows_version

if ($channel.requires_signed_package -ne $true) {
    Fail "Update channel must require signed packages."
}

if ($channel.requires_https_update_uri -ne $true) {
    Fail "Update channel must require HTTPS update URIs."
}

if ($channel.external_distribution_enabled -eq $true) {
    if ([string]::IsNullOrWhiteSpace($channel.appinstaller_uri) -or [string]::IsNullOrWhiteSpace($channel.package_uri)) {
        Fail "Enabled external distribution requires appinstaller_uri and package_uri."
    }

    foreach ($uri in @($channel.appinstaller_uri, $channel.package_uri)) {
        if ($uri -notmatch "^https://") {
            Fail "External update URI must use HTTPS: $uri"
        }
    }

    if ($channel.rollout.percentage -lt 1 -or $channel.rollout.percentage -gt 100) {
        Fail "Enabled external distribution rollout percentage must be 1..100."
    }
} else {
    if (-not [string]::IsNullOrWhiteSpace($channel.appinstaller_uri)) {
        Fail "Disabled external distribution must not define appinstaller_uri."
    }

    if (-not [string]::IsNullOrWhiteSpace($channel.package_uri)) {
        Fail "Disabled external distribution must not define package_uri."
    }

    if ($channel.rollout.mode -ne "manual") {
        Fail "Disabled external distribution rollout mode must be manual."
    }

    if ($channel.rollout.percentage -ne 0) {
        Fail "Disabled external distribution rollout percentage must be 0."
    }
}

Pass "Windows update channel metadata is pinned"
