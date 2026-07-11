using OrbitTerm.NativeBridge;
using Xunit;

namespace OrbitTerm.Security.Tests;

public sealed class TerminalControlResultTests
{
    [Fact]
    public void SuccessResponseMapsToSucceeded()
    {
        var result = TerminalControlResult.Decode(string.Concat("OK", ":", "wrote"));

        var succeeded = Assert.IsType<TerminalControlResult.Succeeded>(result);
        Assert.Equal("wrote", succeeded.Detail);
    }

    [Fact]
    public void ErrorResponseMapsToFailedWithoutThrowing()
    {
        var result = TerminalControlResult.Decode(string.Concat("ERR", ":", "terminal channel not found"));

        var failed = Assert.IsType<TerminalControlResult.Failed>(result);
        Assert.Equal("terminal channel not found", failed.Message);
    }

    [Fact]
    public void UnknownResponseIsRejected()
    {
        Assert.Throws<OrbitNativeException>(() => TerminalControlResult.Decode("unexpected"));
    }
}
