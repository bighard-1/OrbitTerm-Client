$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

$capture = Join-Path $PSScriptRoot 'capture_interactive_desktop.ps1'
$action = New-ScheduledTaskAction `
    -Execute 'PowerShell.exe' `
    -Argument "-NoProfile -WindowStyle Hidden -ExecutionPolicy Bypass -File `"$capture`""
$principal = New-ScheduledTaskPrincipal `
    -UserId $env:USERNAME `
    -LogonType Interactive `
    -RunLevel Limited

Register-ScheduledTask `
    -TaskName 'OrbitTerm-CaptureInteractiveDesktop' `
    -Action $action `
    -Principal $principal `
    -Force | Out-Null
Start-ScheduledTask -TaskName 'OrbitTerm-CaptureInteractiveDesktop'
Write-Output 'ORBITTERM_DESKTOP_CAPTURE_REQUESTED'
