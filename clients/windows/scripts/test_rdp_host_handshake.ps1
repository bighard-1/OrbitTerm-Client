param(
    [string]$Executable = "",
    [ValidateRange(0, 30)]
    [int]$KeepAliveSeconds = 0
)

$ErrorActionPreference = "Stop"
if ([string]::IsNullOrWhiteSpace($Executable)) {
    $package = Get-AppxPackage -Name "OrbitTerm.Client" |
        Sort-Object Version -Descending |
        Select-Object -First 1
    if ($null -eq $package) {
        throw "OrbitTerm.Client is not installed."
    }
    $Executable = Join-Path $package.InstallLocation "rdp-host\OrbitTerm.RdpHost.exe"
}
if (-not (Test-Path $Executable)) {
    throw "RDP host executable was not found: $Executable"
}

$pipeName = "OrbitTermRdp_$([Guid]::NewGuid().ToString('N'))"
$pipeOptions = [System.IO.Pipes.PipeOptions]::Asynchronous -bor
    [System.IO.Pipes.PipeOptions]::CurrentUserOnly
$pipe = New-Object System.IO.Pipes.NamedPipeServerStream -ArgumentList @(
    $pipeName,
    [System.IO.Pipes.PipeDirection]::Out,
    1,
    [System.IO.Pipes.PipeTransmissionMode]::Byte,
    $pipeOptions
)
$process = $null
try {
    $process = Start-Process `
        -FilePath $Executable `
        -ArgumentList "--pipe", $pipeName `
        -WorkingDirectory (Split-Path -Parent $Executable) `
        -PassThru
    $pendingConnection = $pipe.BeginWaitForConnection($null, $null)
    if (-not $pendingConnection.AsyncWaitHandle.WaitOne(5000)) {
        if ($process.HasExited) {
            throw "RDP host exited before connecting to its authenticated pipe."
        }
        throw "RDP host did not connect to its authenticated pipe within five seconds."
    }
    $pipe.EndWaitForConnection($pendingConnection)

    $payload = @{
        DisplayName = "OrbitTerm RDP handshake test"
        Host = "127.0.0.1"
        Port = 1
        Username = "test"
        Password = ""
        ClipboardEnabled = $false
        DriveRedirectionEnabled = $false
        PrinterRedirectionEnabled = $false
        DarkTheme = $true
    } | ConvertTo-Json -Compress
    $bytes = [Text.Encoding]::UTF8.GetBytes($payload)
    $pipe.Write($bytes, 0, $bytes.Length)
    $pipe.Flush()
    $pipe.Dispose()
    # Reaching this point proves that the isolated host accepted the exact
    # one-time pipe name and consumed the launch envelope. Do not require its
    # UI to remain alive here: this script is also run through OpenSSH, where
    # Windows intentionally denies an interactive ActiveX desktop to the
    # child process after the handshake.
    Write-Output "RDP_HOST_HANDSHAKE_OK"
    if ($KeepAliveSeconds -gt 0) {
        Start-Sleep -Seconds $KeepAliveSeconds
        if ($process.HasExited) {
            throw "RDP host UI exited during the interactive startup check."
        }
        Write-Output "RDP_HOST_UI_ALIVE"
    }
}
finally {
    $pipe.Dispose()
    if ($null -ne $process) {
        try {
            if (-not $process.HasExited) {
                Stop-Process -Id $process.Id -Force
            }
        }
        catch { }
        $process.Dispose()
    }
}
