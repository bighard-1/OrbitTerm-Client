using System.Text;
using System.Text.Json.Serialization;

namespace OrbitTerm.NativeBridge;

public sealed record ExecResultPayload(
    [property: JsonPropertyName("base_session_id")] string BaseSessionId,
    [property: JsonPropertyName("security_generation")] CheckedSecurityGeneration SecurityGeneration,
    [property: JsonPropertyName("exit_status")] uint ExitStatus,
    [property: JsonPropertyName("stdout")] string Stdout,
    [property: JsonPropertyName("stderr")] string Stderr,
    [property: JsonPropertyName("timed_out")] bool TimedOut,
    [property: JsonPropertyName("stdout_truncated")] bool StdoutTruncated,
    [property: JsonPropertyName("stderr_truncated")] bool StderrTruncated)
{
    public ulong ParsedBaseSessionId =>
        ulong.TryParse(BaseSessionId, out var parsed) && parsed > 0
            ? parsed
            : throw new OrbitNativeException("Exec result contains an invalid base_session_id.");

    public void Validate()
    {
        if (SecurityGeneration != CheckedSecurityGeneration.HostKeyVerified ||
            ExitStatus != 0 || TimedOut || StdoutTruncated || StderrTruncated ||
            Encoding.UTF8.GetByteCount(Stdout) > 1024 * 1024 ||
            Encoding.UTF8.GetByteCount(Stderr) > 256 * 1024)
        {
            throw new OrbitNativeException("Exec result violates the checked execution contract.");
        }
    }
}
