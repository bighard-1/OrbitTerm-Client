using System.Security.Cryptography;
using System.Text;
using OrbitTerm.NativeBridge;

namespace OrbitTerm.Application.Accounts;

public enum AccountUnlockResult
{
    Unlocked,
    InvalidMasterPassword,
    VerificationRequiresEncryptedConfig,
    NetworkUnavailable,
    ServiceFailure,
}

public interface IEncryptedConfigUnlockVerifier
{
    ValueTask<bool?> VerifyAsync(AccountSessionRecord session, string masterPassword, byte[] rootKey, CancellationToken cancellationToken);
}
public interface IConfigRootKeyDeriver { byte[] Derive(string masterPassword, string accountScope); }
public sealed class NativeConfigRootKeyDeriver : IConfigRootKeyDeriver { public byte[] Derive(string password, string scope) => OrbitConfigCrypto.DeriveConfigRootKeyV2(password, scope); }

public interface IAccountUnlockVerifierStore
{
    ValueTask<byte[]?> ReadAsync(string accountScope, CancellationToken cancellationToken);
    ValueTask SaveAsync(string accountScope, byte[] verifier, CancellationToken cancellationToken);
}

public sealed class NullAccountUnlockVerifierStore : IAccountUnlockVerifierStore
{
    public ValueTask<byte[]?> ReadAsync(string accountScope, CancellationToken cancellationToken) => ValueTask.FromResult<byte[]?>(null);
    public ValueTask SaveAsync(string accountScope, byte[] verifier, CancellationToken cancellationToken) => ValueTask.CompletedTask;
}

/// <summary>Owns the only transition that enables encrypted synchronization.</summary>
public sealed class AccountUnlockController
{
    private readonly IAccountSessionStore sessionStore;
    private readonly IOrbitAccountProtocol accountProtocol;
    private readonly IEncryptedConfigUnlockVerifier verifier;
    private readonly IAccountUnlockVerifierStore verifierStore;
    private readonly IConfigRootKeyDeriver keyDeriver;
    private AccountSessionRecord? session;
    private byte[]? rootKey;

    public AccountUnlockController(IAccountSessionStore sessionStore, IOrbitAccountProtocol accountProtocol, IEncryptedConfigUnlockVerifier verifier, IAccountUnlockVerifierStore? verifierStore = null, IConfigRootKeyDeriver? keyDeriver = null)
    {
        this.sessionStore = sessionStore;
        this.accountProtocol = accountProtocol;
        this.verifier = verifier;
        this.verifierStore = verifierStore ?? new NullAccountUnlockVerifierStore();
        this.keyDeriver = keyDeriver ?? new NativeConfigRootKeyDeriver();
    }

    public AccountLockState State { get; private set; } = AccountLockState.SignedOut;
    public bool CanSynchronize => State == AccountLockState.SignedInUnlocked;
    public string Username => session?.Username ?? string.Empty;
    public string AccountScope => session is null ? string.Empty : StorageIdentifier(session.Username);

    public async ValueTask LoadAsync(CancellationToken cancellationToken)
    {
        session = await sessionStore.ReadAsync(cancellationToken).ConfigureAwait(false);
        State = session is null ? AccountLockState.SignedOut : AccountLockState.SignedInLocked;
    }

    public async ValueTask LoginAsync(AccountLoginRequest request, CancellationToken cancellationToken)
    {
        ArgumentNullException.ThrowIfNull(request);
        var canonicalUsername = request.Username.Trim().ToLowerInvariant();
        if (string.IsNullOrWhiteSpace(canonicalUsername) || string.IsNullOrWhiteSpace(request.Password))
            throw new ArgumentException("账户名和密码不能为空。", nameof(request));

        var response = await accountProtocol.LoginAsync(
            request with { Username = canonicalUsername },
            cancellationToken).ConfigureAwait(false);
        if (string.IsNullOrWhiteSpace(response.AccessTokenValue) || string.IsNullOrWhiteSpace(response.RefreshToken))
            throw new InvalidOperationException("登录响应缺少会话令牌。");
        session = new(AccountProtocolContracts.Version, canonicalUsername, response.AccessTokenValue, response.RefreshToken, DateTimeOffset.UtcNow, null, null);
        await sessionStore.SaveAsync(session, cancellationToken).ConfigureAwait(false);
        State = AccountLockState.SignedInLocked;
        ClearRootKey();
    }

    public async ValueTask RegisterAndLoginAsync(AccountRegisterRequest request, CancellationToken cancellationToken)
    {
        ArgumentNullException.ThrowIfNull(request);
        if (accountProtocol is not IOrbitAccountRegistrationProtocol registrationProtocol)
        {
            throw new InvalidOperationException("账户注册服务尚未配置。");
        }

        var canonicalUsername = request.Username.Trim().ToLowerInvariant();
        var inviteCode = request.InviteCode.Trim();
        if (string.IsNullOrWhiteSpace(canonicalUsername) ||
            string.IsNullOrWhiteSpace(request.Password) ||
            string.IsNullOrWhiteSpace(inviteCode))
        {
            throw new ArgumentException("邮箱、密码和邀请码不能为空。", nameof(request));
        }

        await registrationProtocol.RegisterAsync(
            request with { Username = canonicalUsername, InviteCode = inviteCode },
            cancellationToken).ConfigureAwait(false);
        await LoginAsync(new AccountLoginRequest(canonicalUsername, request.Password), cancellationToken)
            .ConfigureAwait(false);
    }

    /// <summary>
    /// Initializes a master password only when this signed-in account has no
    /// local verifier and the read-only remote verifier confirms that no
    /// encrypted configuration exists. Existing ciphertext can never be
    /// replaced by this first-account path.
    /// </summary>
    public async ValueTask<AccountUnlockResult> InitializeEmptyAccountMasterPasswordAsync(
        string masterPassword,
        CancellationToken cancellationToken)
    {
        if (session is null || string.IsNullOrWhiteSpace(masterPassword))
        {
            return AccountUnlockResult.ServiceFailure;
        }

        ClearRootKey();
        var scope = StorageIdentifier(session.Username);
        var localVerifier = await verifierStore.ReadAsync(scope, cancellationToken).ConfigureAwait(false);
        try
        {
            if (localVerifier is { Length: > 0 })
            {
                return AccountUnlockResult.InvalidMasterPassword;
            }

            var candidate = keyDeriver.Derive(masterPassword, scope);
            try
            {
                var remoteVerification = await verifier
                    .VerifyAsync(session, masterPassword, candidate, cancellationToken)
                    .ConfigureAwait(false);
                if (remoteVerification is not null)
                {
                    return remoteVerification == true
                        ? AccountUnlockResult.VerificationRequiresEncryptedConfig
                        : AccountUnlockResult.InvalidMasterPassword;
                }

                var candidateVerifier = SHA256.HashData(candidate);
                try
                {
                    await verifierStore.SaveAsync(scope, candidateVerifier, cancellationToken).ConfigureAwait(false);
                }
                finally
                {
                    CryptographicOperations.ZeroMemory(candidateVerifier);
                }

                rootKey = candidate;
                candidate = [];
                State = AccountLockState.SignedInUnlocked;
                return AccountUnlockResult.Unlocked;
            }
            finally
            {
                if (candidate.Length > 0)
                {
                    CryptographicOperations.ZeroMemory(candidate);
                }
            }
        }
        catch (OperationCanceledException) when (cancellationToken.IsCancellationRequested)
        {
            throw;
        }
        catch (OperationCanceledException)
        {
            State = AccountLockState.SignedInLocked;
            return AccountUnlockResult.NetworkUnavailable;
        }
        catch (HttpRequestException exception) when (exception.StatusCode is null)
        {
            State = AccountLockState.SignedInLocked;
            return AccountUnlockResult.NetworkUnavailable;
        }
        catch
        {
            State = AccountLockState.SignedInLocked;
            return AccountUnlockResult.ServiceFailure;
        }
        finally
        {
            if (localVerifier is not null)
            {
                CryptographicOperations.ZeroMemory(localVerifier);
            }
        }
    }

    public async ValueTask<AccountUnlockResult> UnlockAsync(string masterPassword, CancellationToken cancellationToken)
    {
        if (session is null) return AccountUnlockResult.ServiceFailure;
        ClearRootKey();
        try
        {
            var scope = StorageIdentifier(session.Username);
            var candidate = keyDeriver.Derive(masterPassword, scope);
            var localVerifier = await verifierStore.ReadAsync(scope, cancellationToken).ConfigureAwait(false);
            try
            {
                var candidateVerifier = SHA256.HashData(candidate);
                try
                {
                    var localMatch = localVerifier is { Length: 32 } &&
                        CryptographicOperations.FixedTimeEquals(localVerifier, candidateVerifier);
                    // A local mismatch can legitimately follow an account-wide master
                    // key rotation completed on another device. Fall back to the
                    // read-only remote verifier and repair the local DPAPI verifier only
                    // after ciphertext has proved the candidate key.
                    var verified = localMatch
                        ? true
                        : await verifier.VerifyAsync(session, masterPassword, candidate, cancellationToken).ConfigureAwait(false);
                    if (verified is null) { CryptographicOperations.ZeroMemory(candidate); return AccountUnlockResult.VerificationRequiresEncryptedConfig; }
                    if (verified == false) { CryptographicOperations.ZeroMemory(candidate); return AccountUnlockResult.InvalidMasterPassword; }
                    rootKey = candidate;
                    if (!localMatch)
                        await verifierStore.SaveAsync(scope, candidateVerifier, cancellationToken).ConfigureAwait(false);
                    State = AccountLockState.SignedInUnlocked;
                    return AccountUnlockResult.Unlocked;
                }
                finally
                {
                    CryptographicOperations.ZeroMemory(candidateVerifier);
                }
            }
            finally
            {
                if (localVerifier is not null)
                    CryptographicOperations.ZeroMemory(localVerifier);
            }
        }
        catch (OperationCanceledException) when (cancellationToken.IsCancellationRequested) { throw; }
        catch (OperationCanceledException) { ClearRootKey(); State = AccountLockState.SignedInLocked; return AccountUnlockResult.NetworkUnavailable; }
        catch (HttpRequestException exception) when (exception.StatusCode is null)
        {
            ClearRootKey();
            State = AccountLockState.SignedInLocked;
            return AccountUnlockResult.NetworkUnavailable;
        }
        catch
        {
            ClearRootKey();
            State = AccountLockState.SignedInLocked;
            return AccountUnlockResult.ServiceFailure;
        }
    }

    public void Lock() { ClearRootKey(); if (session is not null) State = AccountLockState.SignedInLocked; }

    public async ValueTask ChangeLoginPasswordAsync(
        string currentPassword,
        string newPassword,
        CancellationToken cancellationToken)
    {
        if (session is null || accountProtocol is not IOrbitAccountSecurityProtocol securityProtocol)
        {
            throw new InvalidOperationException("账户安全服务尚未配置。");
        }

        var result = await securityProtocol.ChangePasswordAsync(
            session,
            new AccountPasswordChangeRequest(currentPassword, newPassword),
            cancellationToken).ConfigureAwait(false);
        var response = result.Value;
        if (string.IsNullOrWhiteSpace(response.AccessTokenValue))
        {
            throw new InvalidOperationException("密码更新响应缺少有效会话令牌。");
        }

        session = result.Session with
        {
            AccessToken = response.AccessTokenValue,
            RefreshToken = string.IsNullOrWhiteSpace(response.RefreshToken)
                ? result.Session.RefreshToken
                : response.RefreshToken,
        };
        await sessionStore.SaveAsync(session, cancellationToken).ConfigureAwait(false);
    }

    public async ValueTask RotateMasterPasswordAsync(
        string currentMasterPassword,
        string newMasterPassword,
        string currentLoginPassword,
        CancellationToken cancellationToken)
    {
        if (session is null || rootKey is null || State != AccountLockState.SignedInUnlocked ||
            accountProtocol is not IOrbitAccountSecurityProtocol securityProtocol)
        {
            throw new InvalidOperationException("账户尚未解锁，不能轮换主密码。");
        }

        if (string.IsNullOrWhiteSpace(currentLoginPassword) ||
            string.IsNullOrWhiteSpace(currentMasterPassword) ||
            string.IsNullOrWhiteSpace(newMasterPassword) ||
            string.Equals(currentMasterPassword, newMasterPassword, StringComparison.Ordinal))
        {
            throw new ArgumentException("主密码轮换输入无效。");
        }

        var scope = StorageIdentifier(session.Username);
        var currentCandidate = keyDeriver.Derive(currentMasterPassword, scope);
        try
        {
            if (!CryptographicOperations.FixedTimeEquals(rootKey, currentCandidate))
            {
                throw new CryptographicException("当前主密码不正确。");
            }
        }
        finally
        {
            CryptographicOperations.ZeroMemory(currentCandidate);
        }

        var snapshotResult = await securityProtocol
            .PullCompleteConfigSnapshotAsync(session, cancellationToken)
            .ConfigureAwait(false);
        var snapshot = snapshotResult.Value;
        if (snapshot.Select(item => item.Id).Distinct().Count() != snapshot.Count)
        {
            throw new InvalidOperationException("云端配置快照不一致，请先同步后重试。");
        }

        var replacements = new List<MasterKeyRotationItemRequest>(snapshot.Count);
        foreach (var item in snapshot)
        {
            byte[]? encrypted = null;
            byte[]? plaintext = null;
            byte[]? reencrypted = null;
            try
            {
                encrypted = Convert.FromBase64String(item.EncryptedBlobBase64);
                plaintext = IsV2ConfigBlob(encrypted)
                    ? OrbitConfigCrypto.DecryptConfigV2(rootKey, encrypted)
                    : OrbitConfigCrypto.DecryptConfigLegacy(currentMasterPassword, encrypted);
                reencrypted = OrbitConfigCrypto.EncryptConfigLegacy(newMasterPassword, plaintext);
                replacements.Add(new MasterKeyRotationItemRequest(
                    item.Id,
                    item.VectorClock,
                    Convert.ToBase64String(reencrypted)));
            }
            finally
            {
                if (encrypted is not null) CryptographicOperations.ZeroMemory(encrypted);
                if (plaintext is not null) CryptographicOperations.ZeroMemory(plaintext);
                if (reencrypted is not null) CryptographicOperations.ZeroMemory(reencrypted);
            }
        }

        var rotation = await securityProtocol.RotateMasterKeyAsync(
            snapshotResult.Session,
            new MasterKeyRotationRequest(currentLoginPassword, replacements),
            cancellationToken).ConfigureAwait(false);
        if (string.IsNullOrWhiteSpace(rotation.Value.AccessTokenValue))
        {
            throw new InvalidOperationException("主密码轮换响应缺少有效会话令牌。");
        }

        var nextRootKey = keyDeriver.Derive(newMasterPassword, scope);
        var nextVerifier = SHA256.HashData(nextRootKey);
        try
        {
            session = rotation.Session with
            {
                AccessToken = rotation.Value.AccessTokenValue,
                RefreshToken = string.IsNullOrWhiteSpace(rotation.Value.RefreshToken)
                    ? rotation.Session.RefreshToken
                    : rotation.Value.RefreshToken,
            };
            await sessionStore.SaveAsync(session, cancellationToken).ConfigureAwait(false);
            await verifierStore.SaveAsync(scope, nextVerifier, cancellationToken).ConfigureAwait(false);
            ClearRootKey();
            rootKey = nextRootKey;
            nextRootKey = [];
        }
        finally
        {
            CryptographicOperations.ZeroMemory(nextVerifier);
            if (nextRootKey.Length > 0) CryptographicOperations.ZeroMemory(nextRootKey);
        }
    }

    public async ValueTask SignOutAsync(CancellationToken cancellationToken)
    {
        ClearRootKey();
        session = null;
        await sessionStore.ClearAsync(cancellationToken).ConfigureAwait(false);
        State = AccountLockState.SignedOut;
    }

    /// <summary>
    /// A manual sync keeps the main password ephemeral: it is used only while
    /// processing legacy ciphertext, then discarded. The already-unlocked root
    /// key is never exposed outside this controller.
    /// </summary>
    public async ValueTask<EncryptedConfigSynchronizationResult> SynchronizeAsync(
        IEncryptedConfigSynchronizer synchronizer,
        string masterPassword,
        CancellationToken cancellationToken,
        bool forceCompleteReconciliation = false)
    {
        ArgumentNullException.ThrowIfNull(synchronizer);
        if (session is null || rootKey is null || State != AccountLockState.SignedInUnlocked)
        {
            throw new InvalidOperationException("账户尚未解锁，不能同步加密配置。");
        }

        var candidate = keyDeriver.Derive(masterPassword, StorageIdentifier(session.Username));
        try
        {
            if (!CryptographicOperations.FixedTimeEquals(rootKey, candidate))
            {
                throw new CryptographicException("主密码不能解锁当前账户。");
            }

            var result = await synchronizer.SynchronizeAsync(
                session,
                StorageIdentifier(session.Username),
                masterPassword,
                rootKey,
                cancellationToken,
                forceCompleteReconciliation).ConfigureAwait(false);
            // A successful authenticated request may rotate the refresh token even
            // when an unknown payload deliberately prevents acknowledgement.
            session = result.Session;
            await sessionStore.SaveAsync(session, cancellationToken).ConfigureAwait(false);

            return result;
        }
        finally
        {
            CryptographicOperations.ZeroMemory(candidate);
        }
    }

    public async ValueTask<EncryptedAssetPublishResult> PublishAssetAsync(
        IEncryptedAssetPublisher publisher,
        Application.Sessions.ServerAssetRecord asset,
        Application.Security.CredentialMaterial credential,
        Application.Security.CredentialMaterial? jumpHostCredential,
        string masterPassword,
        CancellationToken cancellationToken)
    {
        ArgumentNullException.ThrowIfNull(publisher);
        if (session is null || rootKey is null || State != AccountLockState.SignedInUnlocked)
        {
            throw new InvalidOperationException("账户尚未解锁，不能上传加密资产。");
        }

        var result = await publisher.PublishAsync(
            session,
            StorageIdentifier(session.Username),
            asset,
            credential,
            jumpHostCredential,
            masterPassword,
            rootKey,
            cancellationToken).ConfigureAwait(false);
        session = result.Session;
        await sessionStore.SaveAsync(session, cancellationToken).ConfigureAwait(false);
        return result;
    }

    public async ValueTask<EncryptedSnippetPublishResult> PublishSnippetsAsync(
        IEncryptedSnippetPublisher publisher,
        IReadOnlyList<Application.Sessions.SnippetRecord> snippets,
        string masterPassword,
        CancellationToken cancellationToken)
    {
        ArgumentNullException.ThrowIfNull(publisher);
        if (session is null || rootKey is null || State != AccountLockState.SignedInUnlocked)
            throw new InvalidOperationException("账户尚未解锁，不能上传加密快捷指令。");
        var result = await publisher.PublishAsync(session, StorageIdentifier(session.Username), snippets, masterPassword, rootKey, cancellationToken).ConfigureAwait(false);
        session = result.Session;
        await sessionStore.SaveAsync(session, cancellationToken).ConfigureAwait(false);
        return result;
    }

    public bool IsCurrentMasterPassword(string masterPassword)
    {
        if (rootKey is null || State != AccountLockState.SignedInUnlocked || string.IsNullOrEmpty(masterPassword))
        {
            return false;
        }

        var candidate = keyDeriver.Derive(masterPassword, StorageIdentifier(session!.Username));
        try
        {
            return CryptographicOperations.FixedTimeEquals(rootKey, candidate);
        }
        finally
        {
            CryptographicOperations.ZeroMemory(candidate);
        }
    }

    /// <summary>Records local work while signed in; no network request is made here.</summary>
    public ValueTask QueueAssetUpsertAsync(
        IEncryptedAssetPublisher publisher,
        Guid assetId,
        CancellationToken cancellationToken)
    {
        ArgumentNullException.ThrowIfNull(publisher);
        if (session is null) throw new InvalidOperationException("尚未登录，不能记录账户同步变更。");
        return publisher.QueueUpsertAsync(StorageIdentifier(session.Username), assetId, cancellationToken);
    }

    public ValueTask QueueAssetTombstoneAsync(
        IEncryptedAssetPublisher publisher,
        Guid assetId,
        CancellationToken cancellationToken)
    {
        ArgumentNullException.ThrowIfNull(publisher);
        if (session is null) throw new InvalidOperationException("尚未登录，不能记录账户同步变更。");
        return publisher.QueueTombstoneAsync(StorageIdentifier(session.Username), assetId, cancellationToken);
    }

    public ValueTask QueueUnsyncedAssetsAsync(
        IEncryptedAssetPublisher publisher,
        IReadOnlyCollection<Guid> assetIds,
        CancellationToken cancellationToken)
    {
        ArgumentNullException.ThrowIfNull(publisher);
        if (session is null) throw new InvalidOperationException("尚未登录，不能记录账户同步变更。");
        return publisher.QueueUnsyncedAssetsAsync(StorageIdentifier(session.Username), assetIds, cancellationToken);
    }

    public ValueTask<IReadOnlyDictionary<Guid, PendingAssetSyncOperation>> ReadPendingAssetOperationsAsync(
        IEncryptedAssetPublisher publisher,
        CancellationToken cancellationToken)
    {
        ArgumentNullException.ThrowIfNull(publisher);
        if (session is null) throw new InvalidOperationException("尚未登录，不能读取账户同步变更。");
        return publisher.ReadPendingOperationsAsync(StorageIdentifier(session.Username), cancellationToken);
    }

    public async ValueTask<EncryptedAssetPublishResult> TombstoneAssetAsync(
        IEncryptedAssetPublisher publisher,
        Guid assetId,
        CancellationToken cancellationToken)
    {
        ArgumentNullException.ThrowIfNull(publisher);
        if (session is null || rootKey is null || State != AccountLockState.SignedInUnlocked)
        {
            throw new InvalidOperationException("账户尚未解锁，不能同步删除资产。");
        }

        var result = await publisher.TombstoneAsync(
            session,
            StorageIdentifier(session.Username),
            assetId,
            rootKey,
            cancellationToken).ConfigureAwait(false);
        session = result.Session;
        await sessionStore.SaveAsync(session, cancellationToken).ConfigureAwait(false);
        return result;
    }

    private void ClearRootKey() { if (rootKey is not null) CryptographicOperations.ZeroMemory(rootKey); rootKey = null; }
    private static bool IsV2ConfigBlob(ReadOnlySpan<byte> encrypted) =>
        encrypted.Length >= 4 && encrypted[..4].SequenceEqual("OTC2"u8);
    private static string StorageIdentifier(string username) => Convert.ToHexString(SHA256.HashData(Encoding.UTF8.GetBytes(username.Trim().ToLowerInvariant()))).ToLowerInvariant();
}
