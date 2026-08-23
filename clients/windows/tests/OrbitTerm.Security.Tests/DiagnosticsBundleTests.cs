using OrbitTerm.Application.Diagnostics;
using OrbitTerm.Application.Security;
using Xunit;

namespace OrbitTerm.Security.Tests;

public sealed class DiagnosticsBundleTests
{
    [Fact]
    public void DiagnosticsBundleRedactsSensitiveSessionMaterial()
    {
        var bundle = DiagnosticsBundleFactory.Create(
            new DiagnosticsRuntimeSnapshot(
                "OrbitTerm",
                "0.3.0.0",
                "stable",
                "OrbitTerm.Client",
                "Windows 11",
                "x64",
                false),
            new DiagnosticsSessionSnapshot(
                true,
                true,
                true,
                "example.com",
                "example.com",
                "alice",
                "ssh-ed25519",
                "SHA256:abc",
                @"C:\Users\alice\.ssh\known_hosts",
                "/var/log/auth.log",
                "cat /var/log/auth.log",
                50,
                12,
                "Monitor idle",
                "No monitor snapshot",
                "SFTP open",
                "Directory listing complete",
                3,
                "Docker idle",
                "2 Docker containers",
                "1 Docker stats",
                2,
                1,
                true),
            new DateTimeOffset(2026, 7, 2, 12, 0, 0, TimeSpan.Zero));

        var json = bundle.ToJson();

        Assert.Contains("\"schema_version\": 1", json);
        Assert.Contains("\"channel\": \"stable\"", json);
        Assert.Contains("\"username\": \"[REDACTED]\"", json);
        Assert.Contains("\"host\": \"[REDACTED]\"", json);
        Assert.Contains("\"normalized_host\": \"[REDACTED]\"", json);
        Assert.Contains("\"known_hosts_path\": \"[REDACTED]\"", json);
        Assert.Contains("\"last_remote_path\": \"[REDACTED]\"", json);
        Assert.Contains("\"last_command\": \"[REDACTED]\"", json);
        Assert.DoesNotContain("alice", json);
        Assert.DoesNotContain("example.com", json);
        Assert.DoesNotContain(@"\.ssh\", json);
        Assert.DoesNotContain("/var/log/auth.log", json);
        Assert.DoesNotContain("cat /var", json);
    }

    [Fact]
    public void DiagnosticsBundleKeepsCountsAndClampsNegativeValues()
    {
        var bundle = DiagnosticsBundleFactory.Create(
            new DiagnosticsRuntimeSnapshot(
                "OrbitTerm",
                "0.3.0.0",
                "stable",
                "OrbitTerm.Client",
                "Windows",
                "x64",
                false),
            new DiagnosticsSessionSnapshot(
                false,
                false,
                false,
                null,
                null,
                null,
                null,
                null,
                null,
                null,
                null,
                -1,
                -5,
                "Monitor idle",
                "No monitor snapshot",
                "SFTP not open",
                "File operations unavailable",
                -2,
                "Docker idle",
                "No Docker containers",
                "No Docker stats",
                -3,
                -4,
                false),
            DateTimeOffset.UnixEpoch);

        Assert.Equal(0, bundle.Session.VisibleTerminalLineCount);
        Assert.Equal(0, bundle.Session.HiddenTerminalLineCount);
        Assert.Equal(0, bundle.Session.SftpEntryCount);
        Assert.Equal(0, bundle.Session.DockerContainerCount);
        Assert.Equal(0, bundle.Session.DockerStatsCount);
        Assert.Equal(string.Empty, bundle.Session.Host);
        Assert.Equal(string.Empty, bundle.Session.Username);
        Assert.Equal(string.Empty, bundle.Session.KnownHostsPath);
    }

    [Fact]
    public void RedactionMarkersRemainStableForDiagnostics()
    {
        Assert.Equal("[REDACTED]", Redaction.Secret("secret"));
        Assert.Equal("[REDACTED]", Redaction.Path("C:/Users/me/.ssh/known_hosts"));
        Assert.Equal("[REDACTED]", Redaction.Command("rm -rf /tmp/example"));
    }
}
