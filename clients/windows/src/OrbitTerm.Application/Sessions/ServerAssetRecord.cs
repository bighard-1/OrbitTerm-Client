namespace OrbitTerm.Application.Sessions;

public enum AssetStorageScope
{
    AccountSynced,
    LocalOnly,
}

public sealed record ServerAssetRecord(
    Guid Id,
    Guid CredentialId,
    string Name,
    string Host,
    int Port,
    string Username,
    ServerTransport Transport,
    bool AllowPasswordFallback,
    string Group = "未分组",
    IReadOnlyList<string>? Tags = null,
    JumpHostRecord? JumpHost = null,
    AssetStorageScope StorageScope = AssetStorageScope.AccountSynced,
    string? OwnerAccountScope = null)
{
    public bool IsLocalOnly => StorageScope == AssetStorageScope.LocalOnly;
}

public sealed record JumpHostRecord(
    Guid CredentialId,
    string Host,
    int Port,
    string Username,
    bool AllowPasswordFallback);
