using OrbitTerm.NativeBridge;
using Xunit;

namespace OrbitTerm.Security.Tests;

public sealed class CheckedEnvelopeDecoderTests
{
    [Fact]
    public void DecodeRejectsRequestIdMismatch()
    {
        var requestId = new HostKeyRequestId("expected");
        var json = """
        {
          "schema_version": 1,
          "kind": "connected",
          "request_id": "actual",
          "data": {}
        }
        """;

        Assert.Throws<OrbitNativeException>(() => CheckedEnvelopeDecoder.Decode(json, requestId));
    }

    [Fact]
    public void DecodeRejectsUnsupportedSchema()
    {
        var requestId = new HostKeyRequestId("request-1");
        var json = """
        {
          "schema_version": 2,
          "kind": "connected",
          "request_id": "request-1",
          "data": {}
        }
        """;

        Assert.Throws<OrbitNativeException>(() => CheckedEnvelopeDecoder.Decode(json, requestId));
    }

    [Fact]
    public void DecodeAcceptsErrorEnvelopeWithMatchingRequestId()
    {
        var requestId = new HostKeyRequestId("request-1");
        var json = """
        {
          "schema_version": 1,
          "kind": "error",
          "error": {
            "code": "host_key_changed",
            "message_key": "error.host_key.changed",
            "request_id": "request-1"
          }
        }
        """;

        var envelope = CheckedEnvelopeDecoder.Decode(json, requestId);

        Assert.True(envelope.IsError);
        Assert.Equal("host_key_changed", envelope.Error?.Code);
    }
}
