namespace OrbitTerm.Application.Accounts;

/// <summary>
/// Cross-platform contract identifiers shared with the existing Apple client.
/// Implementations must not silently change these paths or payload names.
/// </summary>
public static class AccountProtocolContracts
{
    public const int Version = 1;
    public const string LoginPath = "/api/v1/auth/login";
    public const string RegisterPath = "/api/v1/auth/register";
    public const string RefreshPath = "/api/v1/auth/refresh";
    public const string ChangePasswordPath = "/api/v1/auth/password";
    public const string RotateMasterKeyPath = "/api/v1/config/master-key/rotate";
    public const string ConfigPullAllPath = "/api/v1/config/pull";
    public const string ConfigTrashPath = "/api/v1/config/trash";
    public const string ConfigPullPath = "/api/v1/config/sync/pull";
    public const string ConfigAcknowledgementPath = "/api/v1/config/sync/ack";
}

public sealed record AccountLoginRequest(string Username, string Password);

public sealed record AccountRegisterRequest(
    string Username,
    string Password,
    string InviteCode);

public sealed record AccountRegisterResponse(
    ulong Id,
    string Username,
    string CreatedAt);

public sealed record AccountRefreshRequest(string RefreshToken);

public sealed record AccountPasswordChangeRequest(
    string CurrentPassword,
    string NewPassword);

public sealed record MasterKeyRotationItemRequest(
    ulong Id,
    string ExpectedVectorClock,
    string EncryptedBlobBase64);

public sealed record MasterKeyRotationRequest(
    string CurrentLoginPassword,
    IReadOnlyList<MasterKeyRotationItemRequest> Items);

/// <summary>Matches the Apple client's token, access_token fallback and refresh_token fields.</summary>
public sealed record AccountLoginResponse(
    string? Token,
    string? AccessToken,
    string? RefreshToken,
    string Type,
    int? ExpiresInSeconds,
    int? RefreshExpiresInSeconds)
{
    public string AccessTokenValue => AccessToken ?? Token ?? string.Empty;
}

/// <summary>
/// The platform session store is the only component permitted to persist these
/// tokens. Callers should retain access tokens in memory for the shortest
/// practical duration.
/// </summary>
public sealed record AccountSessionRecord(
    int ProtocolVersion,
    string Username,
    string AccessToken,
    string RefreshToken,
    DateTimeOffset CreatedAt,
    DateTimeOffset? AccessTokenExpiresAt,
    DateTimeOffset? RefreshTokenExpiresAt);

public interface IAccountSessionStore
{
    ValueTask<AccountSessionRecord?> ReadAsync(CancellationToken cancellationToken);

    ValueTask SaveAsync(AccountSessionRecord session, CancellationToken cancellationToken);

    ValueTask ClearAsync(CancellationToken cancellationToken);
}

public enum AccountLockState
{
    SignedOut,
    SignedInLocked,
    SignedInUnlocked,
}

public interface IOrbitAccountProtocol
{
    ValueTask<AccountLoginResponse> LoginAsync(AccountLoginRequest request, CancellationToken cancellationToken);

    ValueTask<AccountLoginResponse> RefreshAsync(AccountRefreshRequest request, CancellationToken cancellationToken);
}

public interface IOrbitAccountRegistrationProtocol
{
    ValueTask<AccountRegisterResponse> RegisterAsync(
        AccountRegisterRequest request,
        CancellationToken cancellationToken);
}

public interface IOrbitAccountSecurityProtocol
{
    ValueTask<AuthorizedProtocolResult<AccountLoginResponse>> ChangePasswordAsync(
        AccountSessionRecord session,
        AccountPasswordChangeRequest request,
        CancellationToken cancellationToken);

    ValueTask<AuthorizedProtocolResult<IReadOnlyList<EncryptedConfigRecord>>> PullCompleteConfigSnapshotAsync(
        AccountSessionRecord session,
        CancellationToken cancellationToken);

    ValueTask<AuthorizedProtocolResult<AccountLoginResponse>> RotateMasterKeyAsync(
        AccountSessionRecord session,
        MasterKeyRotationRequest request,
        CancellationToken cancellationToken);
}

/// <summary>
/// Encrypted payload boundary: plaintext asset data and credential material are
/// deliberately absent from this contract.
/// </summary>
public sealed record EncryptedConfigUpload(
    ulong? Id,
    string? AssetId,
    string? IdentityFingerprint,
    string EncryptedBlobBase64,
    string VectorClock);

public sealed record EncryptedConfigRecord(
    ulong Id,
    string? AssetId,
    string? IdentityFingerprint,
    string EncryptedBlobBase64,
    string VectorClock,
    string? State,
    ulong? ServerRevision,
    DateTimeOffset UpdatedAt);

public sealed record EncryptedConfigChanges(
    IReadOnlyList<EncryptedConfigRecord> Items,
    ulong NextCursor,
    bool HasMore,
    bool ResetRequired);

public sealed record SyncAcknowledgement(
    Guid DeviceId,
    ulong Revision,
    string Platform,
    string ClientVersion);

/// <summary>Matches the Apple client's soft-delete request; the remote record remains a tombstone.</summary>
public sealed record AssetDeletionRequest(
    Guid DeviceId,
    Guid OperationId,
    string VectorClock,
    string? Confirmation = null);

public sealed record AuthorizedProtocolResult<T>(T Value, AccountSessionRecord Session);

public interface IOrbitEncryptedSyncProtocol
{
    ValueTask<AuthorizedProtocolResult<EncryptedConfigRecord>> UploadAsync(
        AccountSessionRecord session,
        EncryptedConfigUpload upload,
        CancellationToken cancellationToken);

    ValueTask<AuthorizedProtocolResult<EncryptedConfigChanges>> PullChangesAsync(
        AccountSessionRecord session,
        ulong cursor,
        int limit,
        CancellationToken cancellationToken);

    ValueTask<AuthorizedProtocolResult<bool>> AcknowledgeAsync(
        AccountSessionRecord session,
        SyncAcknowledgement acknowledgement,
        CancellationToken cancellationToken);

    ValueTask<AuthorizedProtocolResult<EncryptedConfigRecord>> DeleteAssetAsync(
        AccountSessionRecord session,
        Guid assetId,
        AssetDeletionRequest deletion,
        CancellationToken cancellationToken);
}
