using System.Text.Json.Serialization;

namespace OrbitTerm.NativeBridge;

[JsonConverter(typeof(CheckedSecurityGenerationJsonConverter))]
public enum CheckedSecurityGeneration
{
    HostKeyVerified,

    LegacyUnverified,
}
