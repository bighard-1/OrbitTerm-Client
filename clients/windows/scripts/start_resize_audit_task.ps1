$ErrorActionPreference = 'Stop'
$audit = Join-Path $PSScriptRoot 'audit_windows_resize_hit_test.ps1'
$output = 'C:\OrbitTerm-Client\artifacts\windows-resize-audit.txt'
New-Item -ItemType Directory -Path (Split-Path $output -Parent) -Force | Out-Null
Remove-Item $output -Force -ErrorAction SilentlyContinue
$action = New-ScheduledTaskAction `
    -Execute 'PowerShell.exe' `
    -Argument "-NoProfile -ExecutionPolicy Bypass -File `"$audit`" -OutputPath `"$output`""
$principal = New-ScheduledTaskPrincipal `
    -UserId $env:USERNAME `
    -LogonType Interactive `
    -RunLevel Limited
Register-ScheduledTask `
    -TaskName 'OrbitTerm-ResizeAudit' `
    -Action $action `
    -Principal $principal `
    -Force | Out-Null
Start-ScheduledTask -TaskName 'OrbitTerm-ResizeAudit'
Write-Output $output
