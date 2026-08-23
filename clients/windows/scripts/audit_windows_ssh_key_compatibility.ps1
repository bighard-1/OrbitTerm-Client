param(
    [string]$RepositoryRoot = "C:\OrbitTerm-Client"
)

$ErrorActionPreference = 'Stop'
$coreDll = Join-Path $RepositoryRoot 'orbit-core\target\x86_64-pc-windows-msvc\release\orbit_core.dll'
$sshKeygen = @(
    "$env:WINDIR\System32\OpenSSH\ssh-keygen.exe",
    "$env:ProgramFiles\OpenSSH\ssh-keygen.exe"
) | Where-Object { Test-Path $_ } | Select-Object -First 1
if (-not (Test-Path $coreDll)) { throw "orbit_core.dll not found: $coreDll" }
if (-not $sshKeygen) { throw 'Windows OpenSSH Client is required for the key compatibility audit.' }

$escapedDll = $coreDll.Replace('\', '\\')
Add-Type -TypeDefinition @"
using System;
using System.Runtime.InteropServices;
public static class OrbitKeyCompatibilityProbe
{
    [DllImport("$escapedDll", CallingConvention = CallingConvention.Cdecl, CharSet = CharSet.Ansi)]
    private static extern IntPtr orbit_validate_ssh_private_key_v1(string key, string passphrase);
    [DllImport("$escapedDll", CallingConvention = CallingConvention.Cdecl)]
    private static extern void orbit_free_string(IntPtr value);
    public static string Validate(string key, string passphrase)
    {
        var value = orbit_validate_ssh_private_key_v1(key, passphrase ?? "");
        if (value == IntPtr.Zero) throw new InvalidOperationException("native validator returned null");
        try { return Marshal.PtrToStringAnsi(value); }
        finally { orbit_free_string(value); }
    }
}
"@

$temporaryDirectory = Join-Path $env:TEMP ("OrbitTerm-KeyAudit-" + [Guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $temporaryDirectory -Force | Out-Null
try {
    $cases = @(
        @{ Name = 'Ed25519 OpenSSH'; Type = 'ed25519'; Bits = $null; Passphrase = ''; Expected = 'OK:ssh-ed25519' },
        @{ Name = 'RSA 3072 OpenSSH'; Type = 'rsa'; Bits = 3072; Passphrase = ''; Expected = 'OK:ssh-rsa' },
        @{ Name = 'ECDSA P-256 OpenSSH'; Type = 'ecdsa'; Bits = 256; Passphrase = ''; Expected = 'OK:ecdsa-sha2-nistp256' },
        @{ Name = 'RSA 3072 PEM'; Type = 'rsa'; Bits = 3072; Passphrase = ''; Format = 'PEM'; Expected = 'OK:ssh-rsa' },
        @{ Name = 'ECDSA P-256 PEM'; Type = 'ecdsa'; Bits = 256; Passphrase = ''; Format = 'PEM'; Expected = 'OK:ecdsa-sha2-nistp256' },
        @{ Name = 'Encrypted Ed25519 OpenSSH'; Type = 'ed25519'; Bits = $null; Passphrase = 'audit-passphrase'; Expected = 'OK:ssh-ed25519' },
        @{ Name = 'Legacy DSA OpenSSH'; Type = 'dsa'; Bits = 1024; Passphrase = ''; Expected = 'ERR:key_algorithm_unsupported' }
    )
    foreach ($case in $cases) {
        $keyPath = Join-Path $temporaryDirectory ([Guid]::NewGuid().ToString('N'))
        $passphraseArgument = if ([string]::IsNullOrEmpty($case.Passphrase)) { '""' } else { $case.Passphrase }
        $arguments = @('-q', '-t', $case.Type, '-N', $passphraseArgument, '-f', $keyPath)
        if ($case.Bits) { $arguments = @('-q', '-t', $case.Type, '-b', [string]$case.Bits, '-N', $passphraseArgument, '-f', $keyPath) }
        if ($case.Format) { $arguments += @('-m', $case.Format) }
        & $sshKeygen @arguments
        if ($LASTEXITCODE -ne 0) { throw "ssh-keygen failed for $($case.Name)" }
        $privateKey = Get-Content -LiteralPath $keyPath -Raw
        $actual = [OrbitKeyCompatibilityProbe]::Validate($privateKey, $case.Passphrase)
        if ($actual -ne $case.Expected) {
            throw "$($case.Name): expected $($case.Expected), got $actual"
        }
        Write-Host "[PASS] $($case.Name) -> $actual"
        $privateKey = $null
    }
}
finally {
    if (Test-Path $temporaryDirectory) {
        Get-ChildItem $temporaryDirectory -File -ErrorAction SilentlyContinue | ForEach-Object {
            if ($_.Length -gt 0 -and $_.Length -le 1MB) {
                [IO.File]::WriteAllBytes($_.FullName, (New-Object byte[] $_.Length))
            }
        }
        Remove-Item $temporaryDirectory -Recurse -Force -ErrorAction SilentlyContinue
    }
}
