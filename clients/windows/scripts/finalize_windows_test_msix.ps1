param(
    [string]$RepoRoot = "",
    [Parameter(Mandatory = $true)]
    [string]$CertificateThumbprint,
    [string]$DesktopOutput = (Join-Path ([Environment]::GetFolderPath("Desktop")) "OrbitTerm-Windows11-Test")
)

$ErrorActionPreference = "Stop"
if ([string]::IsNullOrWhiteSpace($RepoRoot)) {
    $RepoRoot = (Resolve-Path (Join-Path $PSScriptRoot "..\..\..")).Path
}
$packageRoot = Join-Path $RepoRoot "artifacts\windows-msix-test"
$appPackages = Join-Path $packageRoot "AppPackages"
$package = Get-ChildItem $appPackages -Recurse -File |
    Where-Object { $_.Extension -eq ".msix" } |
    Sort-Object LastWriteTime -Descending |
    Select-Object -First 1
if ($null -eq $package -or $package.Length -le 0) {
    throw "A valid MSIX package was not found."
}
if ($package.BaseName -notmatch '_([0-9]+\.[0-9]+\.[0-9]+\.[0-9]+)_x64') {
    throw "The MSIX file name does not contain a four-component package version."
}
$packageVersion = $Matches[1]

$certificate = Get-Item "Cert:\CurrentUser\My\$CertificateThumbprint" -ErrorAction Stop
if ($certificate.Subject -ne "CN=OrbitTerm Development") {
    throw "The selected certificate does not match the package publisher."
}

if (Test-Path $DesktopOutput) {
    Remove-Item -LiteralPath $DesktopOutput -Recurse -Force
}
New-Item -ItemType Directory -Path $DesktopOutput -Force | Out-Null

$packageDestination = Join-Path $DesktopOutput "OrbitTerm_${packageVersion}_x64_Test.msix"
$certificateDestination = Join-Path $DesktopOutput "OrbitTerm-Test-Signing.cer"
Copy-Item $package.FullName $packageDestination -Force
Export-Certificate -Cert $certificate -FilePath $certificateDestination -Force | Out-Null
Import-Certificate `
    -FilePath $certificateDestination `
    -CertStoreLocation "Cert:\CurrentUser\TrustedPeople" | Out-Null

Add-Type -AssemblyName System.IO.Compression.FileSystem
$archive = [System.IO.Compression.ZipFile]::OpenRead($packageDestination)
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

$signature = Get-AuthenticodeSignature $packageDestination
$signatureState = $signature.Status.ToString()
if ($signature.Status -ne [System.Management.Automation.SignatureStatus]::Valid) {
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
        throw "Microsoft signtool.exe was not found for package verification."
    }

    $previousErrorActionPreference = $ErrorActionPreference
    $ErrorActionPreference = "Continue"
    try {
        $verificationOutput = (& $signTool.FullName verify /pa /v $packageDestination 2>&1) | Out-String
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

Copy-Item `
    (Join-Path $PSScriptRoot "install_windows_test_msix.ps1") `
    (Join-Path $DesktopOutput "Install-OrbitTerm.ps1") `
    -Force

@'
OrbitTerm Windows 10/11 x64 test package

Installation:
1. Extract the ZIP package before installation.
2. Right-click Install-OrbitTerm.ps1 and choose Run with PowerShell.
3. Do not double-click the MSIX. The script validates and registers it directly,
   so Microsoft App Installer is not required.
4. Administrator permission is not required; the bundled test certificate is
   trusted only for the current Windows user.
5. If script execution is blocked, open PowerShell in this folder and run:
   PowerShell.exe -ExecutionPolicy Bypass -File .\Install-OrbitTerm.ps1
6. On failure, Install-OrbitTerm.log is created and opened automatically.
7. The included certificate is a local test-signing certificate, not a public
   production identity. Install it only on the intended test machine.
8. To remove the test certificate later, open certmgr.msc and remove
   "OrbitTerm Development" from Current User > Trusted People.

The package targets Windows 10/11 x64, build 19041 or later.
'@ | Set-Content -LiteralPath (Join-Path $DesktopOutput "README-INSTALL.txt") -Encoding utf8

$hash = Get-FileHash $packageDestination -Algorithm SHA256
$hash.Hash | Set-Content -LiteralPath (Join-Path $DesktopOutput "SHA256.txt") -Encoding ascii

$zipPath = Join-Path ([Environment]::GetFolderPath("Desktop")) "OrbitTerm-Windows11-Test-$packageVersion-x64.zip"
Remove-Item -LiteralPath $zipPath -Force -ErrorAction SilentlyContinue
Compress-Archive -Path (Join-Path $DesktopOutput "*") -DestinationPath $zipPath -CompressionLevel Optimal

Remove-Item -LiteralPath (Join-Path $packageRoot "OrbitTerm-Test-Signing.pfx") -Force -ErrorAction SilentlyContinue

[pscustomobject]@{
    Package = $packageDestination
    Archive = $zipPath
    PackageBytes = (Get-Item $packageDestination).Length
    ArchiveBytes = (Get-Item $zipPath).Length
    Sha256 = $hash.Hash
    Signature = $signatureState
    CertificateThumbprint = $certificate.Thumbprint
    CertificateExpires = $certificate.NotAfter
    RdpHostIncluded = $true
    OrbitCoreIncluded = $true
} | Format-List
