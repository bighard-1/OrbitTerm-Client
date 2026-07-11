param(
    [string]$Root = (Resolve-Path (Join-Path $PSScriptRoot "..")).Path,
    [string]$RepoRoot = (Resolve-Path (Join-Path $PSScriptRoot "..\..\..")).Path,
    [string]$ExpectedRootPrefix = "D:\Macmini2",
    [string]$Dotnet = "dotnet",
    [string]$Cargo = "cargo",
    [string]$Configuration = "Release",
    [string]$SigningCertificateThumbprint = "",
    [switch]$AllowUnsignedInternalCandidate
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

function Read-Xml([string]$Path) {
    if (!(Test-Path $Path)) {
        Fail "Required XML file missing: $Path"
    }

    [xml]$xml = Get-Content $Path -Raw
    return $xml
}

function Get-PropertyValue([xml]$Project, [string]$Name) {
    foreach ($group in $Project.Project.PropertyGroup) {
        $node = $group.$Name
        if ($null -eq $node) {
            continue
        }

        $value = [string]$node
        if (-not [string]::IsNullOrWhiteSpace($value)) {
            return $value.Trim()
        }
    }

    return ""
}

function Assert-ProjectProperty([xml]$Project, [string]$Name, [string]$Expected) {
    $actual = Get-PropertyValue $Project $Name
    if ($actual -ne $Expected) {
        Fail "OrbitTerm.App property $Name must be '$Expected'. Actual: '$actual'."
    }
}

function Assert-ManifestAttribute([xml]$Manifest, [string]$XPath, [string]$Name, [string]$Expected) {
    $node = $Manifest.SelectSingleNode($XPath, $script:ManifestNamespaceManager)
    if ($null -eq $node) {
        Fail "Package manifest node missing: $XPath"
    }

    $attribute = $node.Attributes[$Name]
    if ($null -eq $attribute -or $attribute.Value -ne $Expected) {
        $actual = if ($null -eq $attribute) { "" } else { $attribute.Value }
        Fail "Package manifest attribute $Name at $XPath must be '$Expected'. Actual: '$actual'."
    }
}

function Assert-ManifestText([xml]$Manifest, [string]$XPath, [string]$Expected) {
    $node = $Manifest.SelectSingleNode($XPath, $script:ManifestNamespaceManager)
    if ($null -eq $node -or $node.InnerText.Trim() -ne $Expected) {
        $actual = if ($null -eq $node) { "" } else { $node.InnerText.Trim() }
        Fail "Package manifest text at $XPath must be '$Expected'. Actual: '$actual'."
    }
}

function Assert-PackageManifest([string]$Root) {
    $manifestPath = Join-Path $Root "src\OrbitTerm.App\Package.appxmanifest"
    $manifest = Read-Xml $manifestPath

    $script:ManifestNamespaceManager = New-Object System.Xml.XmlNamespaceManager($manifest.NameTable)
    $script:ManifestNamespaceManager.AddNamespace("m", "http://schemas.microsoft.com/appx/manifest/foundation/windows10")
    $script:ManifestNamespaceManager.AddNamespace("uap", "http://schemas.microsoft.com/appx/manifest/uap/windows10")
    $script:ManifestNamespaceManager.AddNamespace("rescap", "http://schemas.microsoft.com/appx/manifest/foundation/windows10/restrictedcapabilities")

    Assert-ManifestAttribute $manifest "/m:Package/m:Identity" "Name" "OrbitTerm.Client"
    Assert-ManifestAttribute $manifest "/m:Package/m:Identity" "Publisher" "CN=OrbitTerm Development"
    Assert-ManifestAttribute $manifest "/m:Package/m:Identity" "Version" "0.3.0.0"
    Assert-ManifestText $manifest "/m:Package/m:Properties/m:DisplayName" "OrbitTerm"
    Assert-ManifestText $manifest "/m:Package/m:Properties/m:PublisherDisplayName" "OrbitTerm"
    Assert-ManifestText $manifest "/m:Package/m:Properties/m:Logo" "Assets\StoreLogo.png"
    Assert-ManifestAttribute $manifest "/m:Package/m:Dependencies/m:TargetDeviceFamily" "Name" "Windows.Desktop"
    Assert-ManifestAttribute $manifest "/m:Package/m:Dependencies/m:TargetDeviceFamily" "MinVersion" "10.0.19041.0"
    Assert-ManifestAttribute $manifest "/m:Package/m:Applications/m:Application" "Id" "App"
    Assert-ManifestAttribute $manifest "/m:Package/m:Applications/m:Application/uap:VisualElements" "DisplayName" "OrbitTerm"

    $capabilities = @{}
    foreach ($capability in $manifest.SelectNodes("/m:Package/m:Capabilities/*", $script:ManifestNamespaceManager)) {
        $capabilities[$capability.GetAttribute("Name")] = $true
    }

    foreach ($required in @("internetClient", "runFullTrust")) {
        if (-not $capabilities.ContainsKey($required)) {
            Fail "Package manifest capability missing: $required"
        }
    }

    foreach ($capabilityName in $capabilities.Keys) {
        if ($capabilityName -notin @("internetClient", "runFullTrust")) {
            Fail "Unexpected package manifest capability: $capabilityName"
        }
    }

    $assetExpectations = @{
        "StoreLogo.png" = @(50, 50);
        "Square44x44Logo.png" = @(44, 44);
        "Square71x71Logo.png" = @(71, 71);
        "Square150x150Logo.png" = @(150, 150);
        "Square310x310Logo.png" = @(310, 310);
        "Wide310x150Logo.png" = @(310, 150);
        "SplashScreen.png" = @(620, 300);
    }

    Add-Type -AssemblyName System.Drawing
    foreach ($asset in $assetExpectations.GetEnumerator()) {
        $path = Join-Path $Root "src\OrbitTerm.App\Assets\$($asset.Key)"
        if (!(Test-Path $path)) {
            Fail "Required package asset missing: $path"
        }

        $image = [System.Drawing.Image]::FromFile($path)
        try {
            if ($image.Width -ne $asset.Value[0] -or $image.Height -ne $asset.Value[1]) {
                Fail "Package asset $($asset.Key) must be $($asset.Value[0])x$($asset.Value[1]). Actual: $($image.Width)x$($image.Height)."
            }
        }
        finally {
            $image.Dispose()
        }
    }

    Pass "MSIX package manifest and visual assets are pinned"
}

function Remove-GeneratedReleaseDirectories([string]$Root) {
    $generatedDirectories = Get-ChildItem $Root -Recurse -Directory |
        Where-Object {
            $_.Name -eq "publish" -and
            $_.FullName -match "[\\/](bin|obj)[\\/]"
        }

    foreach ($directory in $generatedDirectories) {
        Remove-Item -Recurse -Force $directory.FullName
    }

    if ($generatedDirectories.Count -gt 0) {
        Pass "Generated publish directories were cleaned after Release validation"
    }
}

function Assert-SigningPolicy {
    if ([string]::IsNullOrWhiteSpace($SigningCertificateThumbprint)) {
        if ($AllowUnsignedInternalCandidate) {
            Info "Unsigned internal candidate mode enabled; output is not approved for external distribution."
            return
        }

        Fail "SigningCertificateThumbprint is required for a distributable release candidate. Use -AllowUnsignedInternalCandidate only for internal validation."
    }

    $thumbprint = $SigningCertificateThumbprint.Replace(" ", "").ToUpperInvariant()
    $stores = @("Cert:\CurrentUser\My", "Cert:\LocalMachine\My")
    $cert = $null
    foreach ($store in $stores) {
        $cert = Get-ChildItem $store -ErrorAction SilentlyContinue |
            Where-Object { $_.Thumbprint.ToUpperInvariant() -eq $thumbprint } |
            Select-Object -First 1
        if ($null -ne $cert) {
            break
        }
    }

    if ($null -eq $cert) {
        Fail "Signing certificate was not found in CurrentUser or LocalMachine personal certificate stores."
    }

    if (-not $cert.HasPrivateKey) {
        Fail "Signing certificate must include a private key."
    }

    if ($cert.NotAfter -le (Get-Date)) {
        Fail "Signing certificate is expired."
    }

    Pass "Signing certificate is present, unexpired, and has a private key"
}

if (-not (Test-IsWindowsHost)) {
    Fail "Windows release candidate validation must run on Windows x64."
}

if (-not [System.Environment]::Is64BitOperatingSystem) {
    Fail "Windows release candidate validation requires a 64-bit Windows OS."
}

if ($Configuration -ne "Release") {
    Fail "Release candidate validation must use Release configuration."
}

if (!(Test-Path $ExpectedRootPrefix)) {
    Fail "Expected Windows validation root does not exist: $ExpectedRootPrefix"
}

$Root = Assert-UnderExpectedRoot $Root "Windows client root"
$RepoRoot = Assert-UnderExpectedRoot $RepoRoot "Repository root"
Pass "Release candidate paths are restricted to $ExpectedRootPrefix"

if (-not (Get-Command $Dotnet -ErrorAction SilentlyContinue)) {
    Fail "dotnet SDK not found"
}

if (-not (Get-Command $Cargo -ErrorAction SilentlyContinue)) {
    Fail "cargo not found"
}

$appProjectPath = Join-Path $Root "src\OrbitTerm.App\OrbitTerm.App.csproj"
$appProject = Read-Xml $appProjectPath
Assert-ProjectProperty $appProject "OutputType" "WinExe"
Assert-ProjectProperty $appProject "UseWinUI" "true"
Assert-ProjectProperty $appProject "EnableMsixTooling" "true"
Assert-ProjectProperty $appProject "Platforms" "x64"
Assert-ProjectProperty $appProject "AppxManifest" "Package.appxmanifest"
Assert-ProjectProperty $appProject "AppxPackageSigningEnabled" "false"
Assert-ProjectProperty $appProject "GenerateAppInstallerFile" "false"
Assert-ProjectProperty $appProject "AppxBundle" "Never"
Assert-ProjectProperty $appProject "TargetPlatformMinVersion" "10.0.19041.0"
$targetFramework = Get-PropertyValue $appProject "TargetFramework"
if ($targetFramework -notmatch "^net9\.0-windows") {
    Fail "OrbitTerm.App TargetFramework must stay on net9.0-windows. Actual: '$targetFramework'."
}
Pass "WinUI release project properties are pinned"

Assert-PackageManifest $Root

Assert-SigningPolicy

Info "Running Windows host validation in Release configuration"
Invoke-Checked {
    & (Join-Path $Root "scripts\check_windows_host.ps1") `
        -Root $Root `
        -RepoRoot $RepoRoot `
        -ExpectedRootPrefix $ExpectedRootPrefix `
        -Dotnet $Dotnet `
        -Cargo $Cargo `
        -Configuration Release
} "Windows host Release validation"
Pass "Windows host Release validation completed"

$dll = Join-Path $RepoRoot "orbit-core\target\x86_64-pc-windows-msvc\release\orbit_core.dll"
if (!(Test-Path $dll)) {
    Fail "Release native bridge DLL missing after validation: $dll"
}
Pass "Release native bridge DLL exists"

Remove-GeneratedReleaseDirectories $Root

$forbiddenDirs = Get-ChildItem $Root -Recurse -Directory |
    Where-Object { $_.FullName -match "[\\/](TestResults|coverage|publish)[\\/]?" }
if ($forbiddenDirs.Count -gt 0) {
    $paths = ($forbiddenDirs | ForEach-Object { $_.FullName }) -join "; "
    Fail "Release validation left distributable-like or test result directories in the source tree: $paths"
}
Pass "Release validation did not leave TestResults, coverage, or publish directories in source tree"

Pass "Windows release candidate gate"
