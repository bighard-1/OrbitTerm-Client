$ErrorActionPreference = "Stop"

$repoRoot = (Resolve-Path (Join-Path $PSScriptRoot "..\..\..")).Path
$runner = Join-Path $PSScriptRoot "run_windows_test_msix_task.ps1"
$arguments = "-NoProfile -ExecutionPolicy Bypass -File `"$runner`""
$action = New-ScheduledTaskAction `
    -Execute "PowerShell.exe" `
    -Argument $arguments `
    -WorkingDirectory $repoRoot
$principal = New-ScheduledTaskPrincipal `
    -UserId $env:USERNAME `
    -LogonType Interactive `
    -RunLevel Limited

Register-ScheduledTask `
    -TaskName "OrbitTerm-TestMsixBuild" `
    -Action $action `
    -Principal $principal `
    -Force | Out-Null
Start-ScheduledTask -TaskName "OrbitTerm-TestMsixBuild"
Write-Output "TASK_STARTED"
