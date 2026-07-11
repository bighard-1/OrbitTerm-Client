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

function Get-WindowsSourceFiles([string]$Path) {
    foreach ($item in Get-ChildItem -LiteralPath $Path) {
        if ($item.PSIsContainer) {
            if ($item.Name -notin "bin", "obj") {
                Get-WindowsSourceFiles $item.FullName
            }
            continue
        }

        if ($item.Extension -in ".cs", ".xaml", ".csproj") {
            $item
        }
    }
}

$src = Join-Path $Root "src"
if (!(Test-Path $src)) {
    Fail "Windows source directory not found: $src"
}

$sourceFiles = @(Get-WindowsSourceFiles $src)

if ($sourceFiles.Count -eq 0) {
    Fail "No Windows source files found."
}

$forbiddenLegacySymbols = @(
    "orbit_test_ssh_connection",
    "orbit_ssh_connect",
    "orbit_sftp_connect",
    "orbit_request_channel",
    "orbit_exec_command",
    "orbit_fetch_system_stats",
    "orbit_fetch_docker_containers",
    "orbit_fetch_docker_stats",
    "orbit_fetch_docker_logs",
    "orbit_docker_action"
)

$legacyAllowList = @(
    "ForbiddenLegacyAbi.cs"
)

foreach ($file in $sourceFiles) {
    if ($legacyAllowList -contains $file.Name) {
        continue
    }

    $text = Get-Content $file.FullName -Raw
    foreach ($symbol in $forbiddenLegacySymbols) {
        if ($text -match "\b$([regex]::Escape($symbol))\b") {
            Fail "Forbidden legacy ABI symbol '$symbol' appears in $($file.FullName)."
        }
    }
}
Pass "Production Windows source avoids forbidden legacy ABI symbols"

$uiRoot = (Join-Path $src "OrbitTerm.App") + [IO.Path]::DirectorySeparatorChar
$uiFiles = $sourceFiles | Where-Object {
    $_.FullName.StartsWith($uiRoot, [StringComparison]::OrdinalIgnoreCase) -and
    $_.Extension -in ".cs", ".xaml"
}

foreach ($file in $uiFiles) {
    $text = Get-Content $file.FullName -Raw
    if ($text.Contains("NativeMethods")) {
        Fail "UI layer must not call NativeMethods directly: $($file.FullName)."
    }
}
Pass "UI layer does not call raw native methods"

$mainWindowCode = Get-Content (Join-Path $src "OrbitTerm.App/MainWindow.xaml.cs") -Raw
$mainWindowXaml = Get-Content (Join-Path $src "OrbitTerm.App/MainWindow.xaml") -Raw
$mainWindowViewModel = Get-Content (Join-Path $src "OrbitTerm.Presentation/MainWindowViewModel.cs") -Raw
$nativeBridge = Get-Content (Join-Path $src "OrbitTerm.NativeBridge/CheckedFfiKind.cs") -Raw
foreach ($requiredText in @(
    "CopySftpPreviewClick",
    "SftpPathTextBoxKeyDown",
    "SftpEntriesDoubleTapped",
    "PrepareSftpPreviewCopy",
    "HasSftpPreview",
    "DownloadSelectedSftpEntryClick",
    "DownloadSftpFile",
    "SftpDownloadCompleted",
    "CreateSftpDirectory",
    "CreateSftpFile",
    "RenameSftpEntry",
    "RemoveSelectedSftpEntryConfirmedAsync",
    "ChangeSelectedSftpPermissionsConfirmedAsync",
    "ChangeSftpPermissions",
    "WriteSftpTextFile",
    "SaveSftpPreviewClick",
    "CanSaveSftpPreview",
    "SftpMutationCompleted",
    "ContentDialogButton.Close"
)) {
    if (-not ($mainWindowCode.Contains($requiredText) -or $mainWindowXaml.Contains($requiredText) -or $mainWindowViewModel.Contains($requiredText) -or $nativeBridge.Contains($requiredText))) {
        Fail "SFTP browse interaction contract is missing: $requiredText"
    }
}
Pass "SFTP browse interaction contract is present"

foreach ($file in $sourceFiles) {
    $text = Get-Content $file.FullName -Raw
    if ($text -match "OK:|ERR:") {
        Fail "Checked Windows code must not parse legacy OK:/ERR: strings: $($file.FullName)."
    }
    if ($text -match "Trust All|accept-anyway|accept anyway|仍然接受|全部信任") {
        Fail "Forbidden Host Key bypass UX appears in $($file.FullName)."
    }
}
Pass "Checked protocol and Host Key bypass UX scans passed"

$requiredProjects = @(
    "OrbitTerm.App",
    "OrbitTerm.Application",
    "OrbitTerm.Presentation",
    "OrbitTerm.Platform.Windows",
    "OrbitTerm.NativeBridge",
    "OrbitTerm.Terminal"
)

foreach ($project in $requiredProjects) {
    $path = Join-Path $src "$project/$project.csproj"
    if (!(Test-Path $path)) {
        Fail "Required project missing: $path"
    }
}
Pass "Required Windows projects are present"

$requiredScripts = @(
    "check_windows_static.ps1",
    "check_windows_toolchain.ps1",
    "build_windows_core.ps1",
    "check_windows_host.ps1",
    "check_windows_release_candidate.ps1",
    "check_windows_update_channel.ps1",
    "check_windows_release_quality.ps1",
    "check_windows_security_evidence.ps1",
    "check_windows_release_readiness.ps1",
    "build_windows_signed_package.ps1",
    "build_windows_portable.ps1",
    "run_windows_personal_test.ps1",
    "install_windows_dependencies.ps1"
)

foreach ($script in $requiredScripts) {
    $path = Join-Path $Root "scripts/$script"
    if (!(Test-Path $path)) {
        Fail "Required Windows validation script missing: $path"
    }
}
Pass "Required Windows validation scripts are present"

$personalTestScript = Join-Path $Root "scripts/run_windows_personal_test.ps1"
$personalTestText = Get-Content $personalTestScript -Raw
foreach ($requiredText in @(
    "Set-StrictMode -Version Latest",
    "Personal Windows app launch requires a Windows host.",
    "SkipStaticGate",
    "check_windows_static.ps1",
    "Windows static gate",
    "& `$Dotnet build",
    "OrbitTerm.App.csproj",
    "OrbitTerm.App.exe",
    "Start-Process"
)) {
    if (-not $personalTestText.Contains($requiredText)) {
        Fail "Personal Windows test launcher is missing required behavior marker: $requiredText"
    }
}
Pass "Personal Windows test launcher contract is present"

$personalTestingGuide = Join-Path $Root "docs/PERSONAL-TESTING.md"
if (!(Test-Path $personalTestingGuide)) {
    Fail "Personal Windows testing guide missing: $personalTestingGuide"
}

$personalTestingText = Get-Content $personalTestingGuide -Raw
foreach ($requiredText in @(
    "run_windows_personal_test.ps1",
    "-NoLaunch",
    "check_windows_toolchain.ps1",
    "personal testing",
    "not a commercial distribution"
)) {
    if (-not $personalTestingText.Contains($requiredText)) {
        Fail "Personal Windows testing guide is missing required guidance marker: $requiredText"
    }
}
Pass "Personal Windows testing guide contract is present"

Invoke-Checked { & (Join-Path $Root "scripts/check_windows_update_channel.ps1") -Root $Root } "Windows update channel checks"
Invoke-Checked { & (Join-Path $Root "scripts/check_windows_release_quality.ps1") -Root $Root } "Windows release quality smoke checks"
Invoke-Checked { & (Join-Path $Root "scripts/check_windows_security_evidence.ps1") -Root $Root } "Windows security evidence checks"
Invoke-Checked { & (Join-Path $Root "scripts/check_windows_release_readiness.ps1") -Root $Root } "Windows release readiness checks"

Pass "Windows static checks"
