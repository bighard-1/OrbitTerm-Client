namespace OrbitTerm.Application.Security;

public enum SshKeyOrigin
{
    Imported,
    Generated,
    Synchronized,
}

public enum SshKeySyncScope
{
    LocalOnly,
    EndToEndEncrypted,
}

public sealed record SshKeyRecord(
    Guid Id,
    string Name,
    string Format,
    string MaterialFingerprint,
    DateTimeOffset CreatedAt,
    DateTimeOffset UpdatedAt,
    SshKeyOrigin Origin,
    IReadOnlyList<Guid> AssignedAssetIds,
    SshKeySyncScope SyncScope = SshKeySyncScope.LocalOnly,
    string? OwnerAccountScope = null);

public sealed class SshKeySecret(string privateKey, string passphrase)
{
    public string PrivateKey { get; } = privateKey;

    public string Passphrase { get; } = passphrase;

    public override string ToString() => "[REDACTED SSH KEY SECRET]";
}

public sealed record SshKeyVaultEntry(SshKeyRecord Record, SshKeySecret Secret);
