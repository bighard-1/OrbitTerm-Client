$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

$launcher = Join-Path $PSScriptRoot 'launch_installed_orbitterm.ps1'
$action = New-ScheduledTaskAction `
    -Execute 'PowerShell.exe' `
    -Argument "-NoProfile -ExecutionPolicy Bypass -File `"$launcher`""
$principal = New-ScheduledTaskPrincipal `
    -UserId $env:USERNAME `
    -LogonType Interactive `
    -RunLevel Limited
Register-ScheduledTask `
    -TaskName 'OrbitTerm-LaunchInstalled' `
    -Action $action `
    -Principal $principal `
    -Force | Out-Null
Start-ScheduledTask -TaskName 'OrbitTerm-LaunchInstalled'
Write-Output 'ORBITTERM_LAUNCH_REQUESTED'
