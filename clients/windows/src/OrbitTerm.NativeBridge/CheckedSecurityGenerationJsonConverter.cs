using System.Text.Json;
using System.Text.Json.Serialization;

namespace OrbitTerm.NativeBridge;

public sealed class CheckedSecurityGenerationJsonConverter : JsonConverter<CheckedSecurityGeneration>
{
    public override CheckedSecurityGeneration Read(
        ref Utf8JsonReader reader,
        Type typeToConvert,
        JsonSerializerOptions options)
    {
        var value = reader.GetString();
        return value switch
        {
            "host_key_verified" => CheckedSecurityGeneration.HostKeyVerified,
            "legacy_unverified" => CheckedSecurityGeneration.LegacyUnverified,
            _ => throw new JsonException("Unknown checked security generation."),
        };
    }

    public override void Write(
        Utf8JsonWriter writer,
        CheckedSecurityGeneration value,
        JsonSerializerOptions options)
    {
        writer.WriteStringValue(value switch
        {
            CheckedSecurityGeneration.HostKeyVerified => "host_key_verified",
            CheckedSecurityGeneration.LegacyUnverified => "legacy_unverified",
            _ => throw new JsonException("Unknown checked security generation."),
        });
    }
}
