using OrbitTerm.Application.Sessions;
using OrbitTerm.NativeBridge;
using Xunit;

namespace OrbitTerm.Security.Tests;

public sealed class SftpMutationResultTests
{
    [Fact]
    public void ErrorEnvelopePreservesStableRedactedDetailCode()
    {
        var lease = new SftpSessionLease(
            Guid.NewGuid(), Guid.NewGuid(), 10, 11, "host.example", 22,
            "ssh-ed25519", "SHA256:test", "/home/tester");
        var envelope = new CheckedEnvelope(
            1,
            "error",
            "request-1",
            null,
            new CheckedErrorPayload(
                "sftp_permission_denied",
                "error.sftp.permission_denied",
                "request-1",
                "permission_denied"));

        var failure = Assert.IsType<SftpMutationResult.Failed>(
            SftpMutationResult.FromEnvelope(
                lease,
                SftpMutationOperations.WriteText,
                "/home/tester/note.txt",
                null,
                envelope));

        Assert.Equal("permission_denied", failure.DetailCode);
    }
}
