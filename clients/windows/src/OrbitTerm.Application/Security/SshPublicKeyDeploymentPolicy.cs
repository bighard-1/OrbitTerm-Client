using System.Text;
using System.Text.RegularExpressions;

namespace OrbitTerm.Application.Security;

public static partial class SshPublicKeyDeploymentPolicy
{
    public const string SuccessMarker = "ORBITTERM_KEY_DEPLOY_OK:";
    public const string ErrorMarker = "ORBITTERM_KEY_DEPLOY_ERROR";

    public static string NormalizePublicKey(string publicKey)
    {
        ArgumentException.ThrowIfNullOrWhiteSpace(publicKey);
        var normalized = publicKey.Trim();
        if (normalized.Length > 4096 || normalized.Contains('\r') || normalized.Contains('\n') ||
            !PublicKeyPattern().IsMatch(normalized))
        {
            throw new ArgumentException("公钥不是受支持的单行 OpenSSH 公钥。", nameof(publicKey));
        }
        return normalized;
    }

    public static string BuildPosixCommand(string publicKey)
    {
        var escaped = NormalizePublicKey(publicKey).Replace("'", "'\"'\"'", StringComparison.Ordinal);
        return string.Concat(
            "umask 077; d=\"$HOME/.ssh\"; f=\"$d/authorized_keys\"; ",
            "mkdir -p \"$d\" && chmod 700 \"$d\" && touch \"$f\" && chmod 600 \"$f\" && ",
            "k='", escaped, "'; ",
            "if grep -Fqx -- \"$k\" \"$f\"; then printf '", SuccessMarker, "existing\\n'; ",
            "else printf '%s\\n' \"$k\" >> \"$f\" && printf '", SuccessMarker, "added\\n'; fi");
    }

    public static string BuildWindowsCommand(string publicKey)
    {
        var normalized = NormalizePublicKey(publicKey);
        var escaped = normalized.Replace("'", "''", StringComparison.Ordinal);
        var script = string.Concat(
            "$ErrorActionPreference='Stop';try{",
            "$k='", escaped, "';",
            "$cfg=Join-Path $env:ProgramData 'ssh\\sshd_config';",
            "$admin=([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator);",
            "$adminFile=$admin -and (Test-Path -LiteralPath $cfg) -and (Select-String -LiteralPath $cfg -Pattern '^\\s*Match\\s+Group\\s+administrators\\s*$' -Quiet);",
            "if($adminFile){$f=Join-Path $env:ProgramData 'ssh\\administrators_authorized_keys'}else{$f=Join-Path $env:USERPROFILE '.ssh\\authorized_keys'};",
            "$d=Split-Path -Parent $f;New-Item -ItemType Directory -Path $d -Force|Out-Null;New-Item -ItemType File -Path $f -Force|Out-Null;",
            "$exists=@(Get-Content -LiteralPath $f -ErrorAction SilentlyContinue|Where-Object{$_.Trim() -eq $k}).Count -gt 0;",
            "if(-not $exists){Add-Content -LiteralPath $f -Value $k -Encoding ascii};",
            "if($adminFile){icacls $f /inheritance:r|Out-Null;icacls $f /grant:r 'SYSTEM:F' 'Administrators:F'|Out-Null}",
            "else{$u=\"$env:USERDOMAIN\\$env:USERNAME\";icacls $d /inheritance:r|Out-Null;icacls $d /grant:r \"${u}:(OI)(CI)F\" 'SYSTEM:(OI)(CI)F'|Out-Null;icacls $f /inheritance:r|Out-Null;icacls $f /grant:r \"${u}:F\" 'SYSTEM:F'|Out-Null};",
            "Write-Output ('", SuccessMarker, "'+$(if($exists){'existing'}else{'added'}))",
            "}catch{Write-Output '", ErrorMarker, "';exit 1}");
        var encoded = Convert.ToBase64String(Encoding.Unicode.GetBytes(script));
        return string.Concat("powershell.exe -NoLogo -NoProfile -NonInteractive -ExecutionPolicy Bypass -EncodedCommand ", encoded);
    }

    public static bool TryReadSuccess(string stdout, string stderr, out bool alreadyPresent)
    {
        var combined = string.Concat(stdout ?? string.Empty, "\n", stderr ?? string.Empty);
        alreadyPresent = combined.Contains(SuccessMarker + "existing", StringComparison.Ordinal);
        return alreadyPresent || combined.Contains(SuccessMarker + "added", StringComparison.Ordinal);
    }

    [GeneratedRegex("^(ssh-ed25519|ssh-rsa|ecdsa-sha2-nistp(256|384|521)) [A-Za-z0-9+/]+={0,3}( [^\\r\\n]{1,256})?$")]
    private static partial Regex PublicKeyPattern();
}
