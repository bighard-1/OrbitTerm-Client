param(
    [string]$RepoRoot = "",
    [string]$DesktopOutput = (Join-Path ([Environment]::GetFolderPath("Desktop")) "OrbitTerm-Windows11-Test"),
    [string]$Dotnet = "C:\Program Files\dotnet\dotnet.exe",
    [string]$PackageVersion = "0.3.0.32"
)

$ErrorActionPreference = "Stop"
if ([string]::IsNullOrWhiteSpace($RepoRoot)) {
    $RepoRoot = (Resolve-Path (Join-Path $PSScriptRoot "..\..\..")).Path
}
$appProject = Join-Path $RepoRoot "clients\windows\src\OrbitTerm.App\OrbitTerm.App.csproj"
$rdpProject = Join-Path $RepoRoot "clients\windows\src\OrbitTerm.RdpHost\OrbitTerm.RdpHost.csproj"
$packageRoot = Join-Path $RepoRoot "artifacts\windows-msix-test"
$appPackages = Join-Path $packageRoot "AppPackages"
$certificateSubject = "CN=OrbitTerm Development"

if (-not (Test-Path $Dotnet)) {
    throw "dotnet SDK not found: $Dotnet"
}
if ($PackageVersion -notmatch '^\d+\.\d+\.\d+\.\d+$') {
    throw "PackageVersion must contain four numeric components."
}
$manifestPath = Join-Path $RepoRoot "clients\windows\src\OrbitTerm.App\Package.appxmanifest"
[xml]$manifest = Get-Content -LiteralPath $manifestPath -Raw
$manifestVersion = $manifest.Package.Identity.Version
if ($manifestVersion -ne $PackageVersion) {
    throw "PackageVersion $PackageVersion does not match manifest version $manifestVersion."
}

if (Test-Path $appPackages) {
    Remove-Item -LiteralPath $appPackages -Recurse -Force
}
if (Test-Path $DesktopOutput) {
    Remove-Item -LiteralPath $DesktopOutput -Recurse -Force
}
New-Item -ItemType Directory -Path $appPackages -Force | Out-Null
New-Item -ItemType Directory -Path $DesktopOutput -Force | Out-Null

# WinUI compiles XAML into generated C# plus XBF files.  Reusing obj/bin after
# source synchronization can leave those artifacts out of step even when the
# incremental publish reports success, which then surfaces as a launch-time
# XamlParseException.  Test packages are release candidates, so always build
# them from a clean generated-output baseline.
foreach ($project in @($rdpProject, $appProject)) {
    & $Dotnet clean $project -c Release -r win-x64 -p:Platform=x64
    if ($LASTEXITCODE -ne 0) {
        throw "Clean failed for $project with exit code $LASTEXITCODE"
    }
}

$certificate = Get-ChildItem Cert:\CurrentUser\My |
    Where-Object {
        $_.Subject -eq $certificateSubject -and
        $_.HasPrivateKey -and
        $_.NotAfter -gt (Get-Date).AddDays(30)
    } |
    Sort-Object NotAfter -Descending |
    Select-Object -First 1

if ($null -eq $certificate) {
    $certificateArguments = @{
        Type = "CodeSigningCert"
        Subject = $certificateSubject
        FriendlyName = "OrbitTerm Windows test package signing"
        CertStoreLocation = "Cert:\CurrentUser\My"
        KeyAlgorithm = "RSA"
        KeyLength = 3072
        HashAlgorithm = "SHA256"
        KeyExportPolicy = "Exportable"
        NotAfter = (Get-Date).AddYears(2)
    }
    $certificate = New-SelfSignedCertificate @certificateArguments
}

$passwordBytes = New-Object byte[] 32
$random = [System.Security.Cryptography.RandomNumberGenerator]::Create()
try {
    $random.GetBytes($passwordBytes)
}
finally {
    $random.Dispose()
}
$pfxPassword = [Convert]::ToBase64String($passwordBytes)
$securePfxPassword = ConvertTo-SecureString -String $pfxPassword -AsPlainText -Force
$pfxPath = Join-Path $packageRoot "OrbitTerm-Test-Signing.pfx"
$signingMode = "Pfx"

try {
    Export-PfxCertificate `
        -Cert $certificate `
        -FilePath $pfxPath `
        -Password $securePfxPassword `
        -Force | Out-Null
}
catch {
    # An older development certificate may deliberately have a non-exportable
    # private key.  Do not replace or weaken it merely for packaging: SignTool
    # can use that key directly from the current user's certificate store.
    $signingMode = "CertificateStore"
    Remove-Item -LiteralPath $pfxPath -Force -ErrorAction SilentlyContinue
}

# A source sync may carry an obj/project.assets.json produced on macOS or for a
# different runtime. Packaging must be self-sufficient instead of silently
# depending on whichever restore happened most recently on the build machine.
& $Dotnet restore $rdpProject -r win-x64 -p:Platform=x64
if ($LASTEXITCODE -ne 0) {
    throw "RDP host restore failed with exit code $LASTEXITCODE"
}
& $Dotnet restore $appProject -r win-x64 -p:Platform=x64
if ($LASTEXITCODE -ne 0) {
    throw "MSIX app restore failed with exit code $LASTEXITCODE"
}

$rdpPublishArguments = @(
    "publish", $rdpProject,
    "-c", "Release",
    "-r", "win-x64",
    "--self-contained", "true",
    "--no-restore",
    "-p:Platform=x64"
)
& $Dotnet @rdpPublishArguments
if ($LASTEXITCODE -ne 0) {
    throw "RDP host publish failed with exit code $LASTEXITCODE"
}

$appPublishArguments = @(
    "publish", $appProject,
    "-c", "Release",
    "-r", "win-x64",
    "--self-contained", "true",
    "--no-restore",
    "-p:Platform=x64",
    "-p:GenerateAppxPackageOnBuild=true",
    "-p:AppxPackageSigningEnabled=false",
    "-p:PackageVersion=$PackageVersion",
    "-p:AppxPackageDir=$appPackages\",
    "-p:AppxBundle=Never",
    "-p:UapAppxPackageBuildMode=SideloadOnly"
)
& $Dotnet @appPublishArguments
if ($LASTEXITCODE -ne 0) {
    throw "MSIX publish failed with exit code $LASTEXITCODE"
}

$package = Get-ChildItem $appPackages -Recurse -File |
    Where-Object { $_.Extension -eq ".msix" } |
    Sort-Object LastWriteTime -Descending |
    Select-Object -First 1
if ($null -eq $package -or $package.Length -le 0) {
    throw "MSIX build completed without a valid package."
}

Add-Type -AssemblyName System.IO.Compression.FileSystem
$archive = [System.IO.Compression.ZipFile]::OpenRead($package.FullName)
try {
    $entryNames = $archive.Entries.FullName
    if ($entryNames -notcontains "rdp-host/OrbitTerm.RdpHost.exe") {
        throw "MSIX is missing the isolated RDP host executable."
    }
    if ($entryNames -notcontains "orbit_core.dll") {
        throw "MSIX is missing orbit_core.dll."
    }
}
finally {
    $archive.Dispose()
}

$signTool = Get-ChildItem `
    (Join-Path $env:USERPROFILE ".nuget\packages\microsoft.windows.sdk.buildtools") `
    -Filter "signtool.exe" `
    -Recurse `
    -File `
    -ErrorAction SilentlyContinue |
    Where-Object { $_.FullName -like "*\x64\signtool.exe" } |
    Sort-Object FullName -Descending |
    Select-Object -First 1
if ($null -eq $signTool) {
    throw "Microsoft signtool.exe was not found in the installed Windows SDK build tools."
}

if ($signingMode -eq "Pfx") {
    & $signTool.FullName `
        sign `
        /fd SHA256 `
        /f $pfxPath `
        /p $pfxPassword `
        $package.FullName
}
else {
    & $signTool.FullName `
        sign `
        /fd SHA256 `
        /s My `
        /sha1 $certificate.Thumbprint `
        $package.FullName
}
if ($LASTEXITCODE -ne 0) {
    throw "MSIX signing failed with exit code $LASTEXITCODE"
}

$validationCertificate = Join-Path $packageRoot "OrbitTerm-Test-Signing.cer"
Export-Certificate -Cert $certificate -FilePath $validationCertificate -Force | Out-Null
Import-Certificate `
    -FilePath $validationCertificate `
    -CertStoreLocation "Cert:\CurrentUser\TrustedPeople" | Out-Null

$signature = Get-AuthenticodeSignature $package.FullName
$signatureState = $signature.Status.ToString()
if ($signature.Status -ne [System.Management.Automation.SignatureStatus]::Valid) {
    $previousErrorActionPreference = $ErrorActionPreference
    $ErrorActionPreference = "Continue"
    try {
        $verificationOutput = (& $signTool.FullName verify /pa /v $package.FullName 2>&1) | Out-String
        $verificationExitCode = $LASTEXITCODE
    }
    finally {
        $ErrorActionPreference = $previousErrorActionPreference
    }
    $normalizedThumbprint = $certificate.Thumbprint.ToUpperInvariant()
    if (
        $verificationExitCode -eq 1 -and
        $verificationOutput -match "terminated in" -and
        $verificationOutput -match "certificate which is not trusted by the trust provider" -and
        $verificationOutput.ToUpperInvariant().Contains($normalizedThumbprint)
    ) {
        $signatureState = "Signed; test root not globally trusted"
    }
    else {
        throw "MSIX signature validation failed: $($signature.Status)`n$verificationOutput"
    }
}
Remove-Item -LiteralPath $pfxPath -Force -ErrorAction SilentlyContinue

$packageDestination = Join-Path $DesktopOutput "OrbitTerm_${PackageVersion}_x64_Test.msix"
$certificateDestination = Join-Path $DesktopOutput "OrbitTerm-Test-Signing.cer"
Copy-Item $package.FullName $packageDestination -Force
Copy-Item $validationCertificate $certificateDestination -Force
Remove-Item -LiteralPath $validationCertificate -Force -ErrorAction SilentlyContinue

Copy-Item `
    (Join-Path $PSScriptRoot "install_windows_test_msix.ps1") `
    (Join-Path $DesktopOutput "Install-OrbitTerm.ps1") `
    -Force

@'
OrbitTerm Windows 10/11 x64 test package

Installation:
1. Right-click Install-OrbitTerm.ps1 and choose Run with PowerShell.
2. Do not double-click the MSIX. The script validates and registers it directly,
   so Microsoft App Installer is not required.
3. Administrator permission is not required; the bundled test certificate is
   trusted only for the current Windows user.
4. If script execution is blocked, open PowerShell in this folder and run:
   PowerShell.exe -ExecutionPolicy Bypass -File .\Install-OrbitTerm.ps1
5. On failure, Install-OrbitTerm.log is created and opened automatically.
6. The included certificate is a local test-signing certificate, not a public
   production identity. Install it only on the intended test machine.
7. To remove the test certificate later, open certmgr.msc and remove
   "OrbitTerm Development" from Current User > Trusted People.

The package targets Windows 10/11 x64, build 19041 or later.
'@ | Set-Content -LiteralPath (Join-Path $DesktopOutput "README-INSTALL.txt") -Encoding utf8

$hash = Get-FileHash $packageDestination -Algorithm SHA256
$hash.Hash | Set-Content -LiteralPath (Join-Path $DesktopOutput "SHA256.txt") -Encoding ascii

[pscustomobject]@{
    Package = $packageDestination
    Certificate = $certificateDestination
    Installer = (Join-Path $DesktopOutput "Install-OrbitTerm.ps1")
    PackageBytes = (Get-Item $packageDestination).Length
    Sha256 = $hash.Hash
    Signature = $signatureState
    CertificateThumbprint = $certificate.Thumbprint
    CertificateExpires = $certificate.NotAfter
} | Format-List
