$ErrorActionPreference = "Stop"
Set-StrictMode -Version Latest

$folder = Split-Path -Parent $MyInvocation.MyCommand.Path
$certificate = Join-Path $folder "OrbitTerm-Test-Signing.cer"
$package = Get-ChildItem $folder -Filter "OrbitTerm_*_x64_Test.msix" -File |
    Sort-Object LastWriteTime -Descending |
    Select-Object -First 1
$logPath = Join-Path $folder "Install-OrbitTerm.log"

try {
    if ($null -eq $package) {
        throw "OrbitTerm MSIX package was not found. Extract the complete ZIP before running this script."
    }
    if (-not (Test-Path -LiteralPath $certificate)) {
        throw "OrbitTerm test-signing certificate was not found. Extract the complete ZIP before running this script."
    }

    Unblock-File -LiteralPath $certificate, $package.FullName -ErrorAction SilentlyContinue
    Import-Certificate `
        -FilePath $certificate `
        -CertStoreLocation "Cert:\CurrentUser\TrustedPeople" | Out-Null

    $signature = Get-AuthenticodeSignature -LiteralPath $package.FullName
    if ($signature.Status -ne [System.Management.Automation.SignatureStatus]::Valid) {
        throw "MSIX signature validation failed after trusting the bundled test certificate: $($signature.Status)"
    }

    if ($package.BaseName -notmatch '_([0-9]+\.[0-9]+\.[0-9]+\.[0-9]+)_x64') {
        throw "The MSIX file name does not contain a valid four-component version."
    }
    $incomingVersion = [version]$Matches[1]
    $installed = Get-AppxPackage -Name "OrbitTerm.Client" -ErrorAction SilentlyContinue
    if ($null -ne $installed -and [version]$installed.Version -gt $incomingVersion) {
        throw "A newer OrbitTerm version ($($installed.Version)) is already installed."
    }

    Get-Process "OrbitTerm.App", "OrbitTerm.RdpHost" -ErrorAction SilentlyContinue |
        Stop-Process -Force -ErrorAction SilentlyContinue

    # Windows rejects a development rebuild when identity and version are the
    # same but package content differs (0x80073CFB). Remove only the current
    # user's same-version test registration before installing the new package.
    if ($null -ne $installed -and [version]$installed.Version -eq $incomingVersion) {
        Remove-AppxPackage -Package $installed.PackageFullName -ErrorAction Stop
    }

    Add-AppxPackage `
        -Path $package.FullName `
        -ForceApplicationShutdown `
        -ForceUpdateFromAnyVersion `
        -ErrorAction Stop

    $registered = Get-AppxPackage -Name "OrbitTerm.Client" -ErrorAction Stop
    "SUCCESS $(Get-Date -Format o) version=$($registered.Version) package=$($registered.PackageFullName)" |
        Set-Content -LiteralPath $logPath -Encoding utf8
    Write-Host "OrbitTerm $($registered.Version) installation completed." -ForegroundColor Green
    Start-Process explorer.exe -ArgumentList "shell:AppsFolder\$($registered.PackageFamilyName)!App"
}
catch {
    $_ | Format-List * -Force | Out-String | Set-Content -LiteralPath $logPath -Encoding utf8
    Write-Host "OrbitTerm installation failed. Details were saved to:" -ForegroundColor Red
    Write-Host $logPath -ForegroundColor Yellow
    Start-Process notepad.exe -ArgumentList $logPath -ErrorAction SilentlyContinue
    exit 1
}
