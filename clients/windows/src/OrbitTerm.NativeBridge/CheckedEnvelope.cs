using System.Text.Json;
using System.Text.Json.Serialization;

namespace OrbitTerm.NativeBridge;

public sealed record CheckedEnvelope(
    [property: JsonPropertyName("schema_version")] int SchemaVersion,
    [property: JsonPropertyName("kind")] string Kind,
    [property: JsonPropertyName("request_id")] string? RequestId,
    [property: JsonPropertyName("data")] JsonElement? Data,
    [property: JsonPropertyName("error")] CheckedErrorPayload? Error)
{
    public bool IsError => Error is not null;
}

public sealed record CheckedErrorPayload(
    [property: JsonPropertyName("code")] string Code,
    [property: JsonPropertyName("message_key")] string MessageKey,
    [property: JsonPropertyName("request_id")] string? RequestId);

public static class CheckedEnvelopeDecoder
{
    internal static readonly JsonSerializerOptions Options = new(JsonSerializerDefaults.Web);

    public static CheckedEnvelope Decode(string json, HostKeyRequestId expectedRequestId)
    {
        var envelope = JsonSerializer.Deserialize<CheckedEnvelope>(json, Options)
            ?? throw new OrbitNativeException("Checked FFI returned an empty envelope.");

        if (envelope.SchemaVersion != 1)
        {
            throw new OrbitNativeException($"Unsupported checked FFI schema version: {envelope.SchemaVersion}.");
        }

        var actualRequestId = envelope.RequestId ?? envelope.Error?.RequestId;
        if (!string.Equals(actualRequestId, expectedRequestId.Value, StringComparison.Ordinal))
        {
            throw new OrbitNativeException("Checked FFI request identifier mismatch.");
        }

        return envelope;
    }

    public static T DecodePayload<T>(CheckedEnvelope envelope, string expectedKind)
    {
        if (envelope.IsError)
        {
            throw new OrbitNativeException($"Checked FFI returned an error envelope: {envelope.Error?.Code}.");
        }

        if (!string.Equals(envelope.Kind, expectedKind, StringComparison.Ordinal))
        {
            throw new OrbitNativeException($"Unexpected checked FFI envelope kind: {envelope.Kind}.");
        }

        if (envelope.Data is not { } data)
        {
            throw new OrbitNativeException("Checked FFI data envelope is missing a payload.");
        }

        return data.Deserialize<T>(Options)
            ?? throw new OrbitNativeException($"Checked FFI payload could not be decoded as {typeof(T).Name}.");
    }
}
