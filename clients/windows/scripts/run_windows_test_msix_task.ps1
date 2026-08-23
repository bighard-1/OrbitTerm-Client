$ErrorActionPreference = "Stop"

$repoRoot = (Resolve-Path (Join-Path $PSScriptRoot "..\..\..")).Path
$logPath = Join-Path $repoRoot "artifacts\windows-msix-test\package-task.log"
$resultPath = Join-Path $repoRoot "artifacts\windows-msix-test\package-task.result"
$buildScript = Join-Path $PSScriptRoot "build_windows_test_msix.ps1"

New-Item -ItemType Directory -Path (Split-Path -Parent $logPath) -Force | Out-Null
Remove-Item -LiteralPath $logPath, $resultPath -Force -ErrorAction SilentlyContinue

try {
    & $buildScript *>&1 | Out-File -LiteralPath $logPath -Encoding utf8
    if (-not $?) {
        throw "Windows test MSIX build returned an unsuccessful status."
    }

    "SUCCESS" | Set-Content -LiteralPath $resultPath -Encoding ascii
}
catch {
    $_ | Out-String | Add-Content -LiteralPath $logPath -Encoding utf8
    "FAILED" | Set-Content -LiteralPath $resultPath -Encoding ascii
    throw
}
