using System.Text.Json;
using System.Text.Json.Serialization;
using OrbitTerm.Application.Security;

namespace OrbitTerm.Application.Diagnostics;

public sealed record DiagnosticsRuntimeSnapshot(
    string Product,
    string Version,
    string Channel,
    string PackageIdentity,
    string OperatingSystem,
    string Architecture,
    bool ExternalDistributionEnabled);

public sealed record DiagnosticsSessionSnapshot(
    bool HasVerifiedSession,
    bool HasTerminal,
    bool HasSftp,
    string? Host,
    string? NormalizedHost,
    string? Username,
    string? HostKeyAlgorithm,
    string? HostKeyFingerprintSha256,
    string? KnownHostsPath,
    string? LastRemotePath,
    string? LastCommand,
    int VisibleTerminalLineCount,
    int HiddenTerminalLineCount,
    string MonitorStatus,
    string MonitorSummary,
    string SftpStatus,
    string SftpOperationStatus,
    int SftpEntryCount,
    string DockerStatus,
    string DockerSummary,
    string DockerStatsSummary,
    int DockerContainerCount,
    int DockerStatsCount,
    bool HasDockerLogPreview);

public sealed record DiagnosticsBundle(
    int SchemaVersion,
    DateTimeOffset CreatedAt,
    DiagnosticsRuntimeSnapshot Runtime,
    DiagnosticsSessionSnapshot Session)
{
    private static readonly JsonSerializerOptions JsonOptions = new()
    {
        PropertyNamingPolicy = JsonNamingPolicy.SnakeCaseLower,
        DefaultIgnoreCondition = JsonIgnoreCondition.WhenWritingNull,
        WriteIndented = true,
    };

    public string ToJson() => JsonSerializer.Serialize(this, JsonOptions);
}

public static class DiagnosticsBundleFactory
{
    public static DiagnosticsBundle Create(
        DiagnosticsRuntimeSnapshot runtime,
        DiagnosticsSessionSnapshot session,
        DateTimeOffset createdAt)
    {
        ArgumentNullException.ThrowIfNull(runtime);
        ArgumentNullException.ThrowIfNull(session);

        return new DiagnosticsBundle(
            1,
            createdAt,
            SanitizeRuntime(runtime),
            SanitizeSession(session));
    }

    private static DiagnosticsRuntimeSnapshot SanitizeRuntime(DiagnosticsRuntimeSnapshot runtime)
    {
        return runtime with
        {
            Product = Bound(runtime.Product),
            Version = Bound(runtime.Version),
            Channel = Bound(runtime.Channel),
            PackageIdentity = Bound(runtime.PackageIdentity),
            OperatingSystem = Bound(runtime.OperatingSystem),
            Architecture = Bound(runtime.Architecture),
        };
    }

    private static DiagnosticsSessionSnapshot SanitizeSession(DiagnosticsSessionSnapshot session)
    {
        return session with
        {
            // Hosts can identify customer infrastructure just as directly as a
            // username or remote path. Diagnostics only need connection state.
            Host = Redaction.Secret(session.Host),
            NormalizedHost = Redaction.Secret(session.NormalizedHost),
            Username = Redaction.Secret(session.Username),
            HostKeyAlgorithm = Bound(session.HostKeyAlgorithm),
            HostKeyFingerprintSha256 = Bound(session.HostKeyFingerprintSha256),
            KnownHostsPath = Redaction.Path(session.KnownHostsPath),
            LastRemotePath = Redaction.Path(session.LastRemotePath),
            LastCommand = Redaction.Command(session.LastCommand),
            VisibleTerminalLineCount = Math.Max(0, session.VisibleTerminalLineCount),
            HiddenTerminalLineCount = Math.Max(0, session.HiddenTerminalLineCount),
            MonitorStatus = Bound(session.MonitorStatus),
            MonitorSummary = Bound(session.MonitorSummary),
            SftpStatus = Bound(session.SftpStatus),
            SftpOperationStatus = Bound(session.SftpOperationStatus),
            SftpEntryCount = Math.Max(0, session.SftpEntryCount),
            DockerStatus = Bound(session.DockerStatus),
            DockerSummary = Bound(session.DockerSummary),
            DockerStatsSummary = Bound(session.DockerStatsSummary),
            DockerContainerCount = Math.Max(0, session.DockerContainerCount),
            DockerStatsCount = Math.Max(0, session.DockerStatsCount),
        };
    }

    private static string Bound(string? value)
    {
        if (string.IsNullOrWhiteSpace(value))
        {
            return string.Empty;
        }

        var trimmed = value.Trim();
        return trimmed.Length <= 160 ? trimmed : trimmed[..160];
    }
}
