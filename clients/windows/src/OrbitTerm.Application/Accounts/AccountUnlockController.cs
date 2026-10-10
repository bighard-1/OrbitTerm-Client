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
    private long authRevision;
    private readonly SemaphoreSlim transitionGate = new(1, 1);

    public AccountUnlockController(IAccountSessionStore sessionStore, IOrbitAccountProtocol accountProtocol, IEncryptedConfigUnlockVerifier verifier, IAccountUnlockVerifierStore? verifierStore = null, IConfigRootKeyDeriver? keyDeriver = null)
    {
        this.sessionStore = sessionStore;
        this.accountProtocol = accountProtocol;
        this.verifier = verifier;
        this.verifierStore = verifierStore ?? new NullAccountUnlockVerifierStore();
        this.keyDeriver = keyDeriver ?? new NativeConfigRootKeyDeriver();
    }

    public AccountLockState State { get; private set; } = AccountLockState.SignedOut;
    public bool CanSynchronize => State == AccountLockState.SignedInUnlocked && !MustChangePassword;
    public bool MustChangePassword => session?.MustChangePassword == true;
    public bool LastLogoutRevocationFailed { get; private set; }
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
        var requestRevision = Interlocked.Read(ref authRevision);
        var canonicalUsername = request.Username.Trim().ToLowerInvariant();
        if (string.IsNullOrWhiteSpace(canonicalUsername) || string.IsNullOrWhiteSpace(request.Password))
            throw new ArgumentException("账户名和密码不能为空。", nameof(request));

        var response = await accountProtocol.LoginAsync(
            request with { Username = canonicalUsername },
            cancellationToken).ConfigureAwait(false);
        if (string.IsNullOrWhiteSpace(response.AccessTokenValue) || string.IsNullOrWhiteSpace(response.RefreshToken))
            throw new InvalidOperationException("登录响应缺少会话令牌。");
        await transitionGate.WaitAsync(cancellationToken).ConfigureAwait(false);
        try
        {
            if (requestRevision != Interlocked.Read(ref authRevision)) return;
            var next = new AccountSessionRecord(AccountProtocolContracts.Version, canonicalUsername, response.AccessTokenValue, response.RefreshToken, DateTimeOffset.UtcNow, null, null, response.MustChangePassword);
            await sessionStore.SaveAsync(next, cancellationToken).ConfigureAwait(false);
            session = next;
            State = AccountLockState.SignedInLocked;
            ClearRootKey();
            Interlocked.Increment(ref authRevision);
        }
        finally { transitionGate.Release(); }
    }

    public async ValueTask RegisterAndLoginAsync(AccountRegisterRequest request, CancellationToken cancellationToken)
    {
        ArgumentNullException.ThrowIfNull(request);
        var requestRevision = Interlocked.Read(ref authRevision);
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
        if (requestRevision != Interlocked.Read(ref authRevision)) return;
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
        if (session is null || MustChangePassword || string.IsNullOrWhiteSpace(masterPassword))
        {
            return AccountUnlockResult.ServiceFailure;
        }

        ClearRootKey();
        var activeSession = session;
        var operationRevision = Interlocked.Read(ref authRevision);
        var scope = StorageIdentifier(activeSession.Username);
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
                    .VerifyAsync(activeSession, masterPassword, candidate, cancellationToken)
                    .ConfigureAwait(false);
                if (remoteVerification is not null)
                {
                    return remoteVerification == true
                        ? AccountUnlockResult.VerificationRequiresEncryptedConfig
                        : AccountUnlockResult.InvalidMasterPassword;
                }

                if (session != activeSession || operationRevision != Interlocked.Read(ref authRevision))
                    return AccountUnlockResult.ServiceFailure;
                var candidateVerifier = SHA256.HashData(candidate);
                try
                {
                    await verifierStore.SaveAsync(scope, candidateVerifier, cancellationToken).ConfigureAwait(false);
                }
                finally
                {
                    CryptographicOperations.ZeroMemory(candidateVerifier);
                }

                if (session != activeSession || operationRevision != Interlocked.Read(ref authRevision))
                    return AccountUnlockResult.ServiceFailure;

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
        catch (AccountProtocolException exception) when (exception.Code == "PASSWORD_CHANGE_REQUIRED")
        {
            if (session is { } active) await MarkPasswordChangeRequiredAsync(active, cancellationToken).ConfigureAwait(false);
            return AccountUnlockResult.ServiceFailure;
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
        if (session is null || MustChangePassword) return AccountUnlockResult.ServiceFailure;
        ClearRootKey();
        var activeSession = session;
        var operationRevision = Interlocked.Read(ref authRevision);
        try
        {
            var scope = StorageIdentifier(activeSession.Username);
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
                        : await verifier.VerifyAsync(activeSession, masterPassword, candidate, cancellationToken).ConfigureAwait(false);
                    if (verified is null) { CryptographicOperations.ZeroMemory(candidate); return AccountUnlockResult.VerificationRequiresEncryptedConfig; }
                    if (verified == false) { CryptographicOperations.ZeroMemory(candidate); return AccountUnlockResult.InvalidMasterPassword; }
                    if (session != activeSession || operationRevision != Interlocked.Read(ref authRevision))
                    {
                        CryptographicOperations.ZeroMemory(candidate);
                        return AccountUnlockResult.ServiceFailure;
                    }
                    rootKey = candidate;
                    if (!localMatch)
                        await verifierStore.SaveAsync(scope, candidateVerifier, cancellationToken).ConfigureAwait(false);
                    if (session != activeSession || operationRevision != Interlocked.Read(ref authRevision))
                    {
                        ClearRootKey();
                        return AccountUnlockResult.ServiceFailure;
                    }
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
        catch (AccountProtocolException exception) when (exception.Code == "PASSWORD_CHANGE_REQUIRED")
        {
            if (session is { } active) await MarkPasswordChangeRequiredAsync(active, cancellationToken).ConfigureAwait(false);
            return AccountUnlockResult.ServiceFailure;
        }
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

    public void Lock() { Interlocked.Increment(ref authRevision); ClearRootKey(); if (session is not null) State = AccountLockState.SignedInLocked; }

    public async ValueTask ChangeLoginPasswordAsync(
        string currentPassword,
        string newPassword,
        CancellationToken cancellationToken)
    {
        if (session is null || accountProtocol is not IOrbitAccountSecurityProtocol securityProtocol)
        {
            throw new InvalidOperationException("账户安全服务尚未配置。");
        }

        var activeSession = session;
        var result = await securityProtocol.ChangePasswordAsync(
            activeSession,
            new AccountPasswordChangeRequest(currentPassword, newPassword),
            cancellationToken).ConfigureAwait(false);
        var response = result.Value;
        if (string.IsNullOrWhiteSpace(response.AccessTokenValue) || string.IsNullOrWhiteSpace(response.RefreshToken))
        {
            throw new InvalidOperationException("密码更新响应缺少有效会话令牌。");
        }

        var updatedSession = result.Session with
        {
            AccessToken = response.AccessTokenValue,
            RefreshToken = response.RefreshToken,
            MustChangePassword = false,
        };
        await PersistReturnedSessionAsync(activeSession, updatedSession, cancellationToken, result.Session).ConfigureAwait(false);
    }

    public async ValueTask RotateMasterPasswordAsync(
        string currentMasterPassword,
        string newMasterPassword,
        string currentLoginPassword,
        CancellationToken cancellationToken)
    {
        if (session is null || rootKey is null || !CanSynchronize ||
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
        var activeSession = session;
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
            .PullCompleteConfigSnapshotAsync(activeSession, cancellationToken)
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
        if (string.IsNullOrWhiteSpace(rotation.Value.AccessTokenValue) || string.IsNullOrWhiteSpace(rotation.Value.RefreshToken))
        {
            throw new InvalidOperationException("主密码轮换响应缺少有效会话令牌。");
        }

        var nextRootKey = keyDeriver.Derive(newMasterPassword, scope);
        var nextVerifier = SHA256.HashData(nextRootKey);
        try
        {
            var updatedSession = rotation.Session with
            {
                AccessToken = rotation.Value.AccessTokenValue,
                RefreshToken = rotation.Value.RefreshToken,
            };
            await PersistReturnedSessionAsync(activeSession, updatedSession, cancellationToken, rotation.Session).ConfigureAwait(false);
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
        AccountSessionRecord? previous;
        long signedOutRevision;
        await transitionGate.WaitAsync(cancellationToken).ConfigureAwait(false);
        try
        {
            Interlocked.Increment(ref authRevision);
            ClearRootKey();
            await sessionStore.ClearAsync(cancellationToken).ConfigureAwait(false);
            previous = session;
            session = null;
            State = AccountLockState.SignedOut;
            LastLogoutRevocationFailed = false;
            signedOutRevision = Interlocked.Read(ref authRevision);
        }
        finally { transitionGate.Release(); }
        if (previous is not null && accountProtocol is IOrbitAccountLogoutProtocol logoutProtocol)
        {
            try { await logoutProtocol.LogoutCurrentAsync(previous, CancellationToken.None).ConfigureAwait(false); }
            catch
            {
                await transitionGate.WaitAsync(CancellationToken.None).ConfigureAwait(false);
                try
                {
                    // A late failure from the old account must not decorate a
                    // subsequent login (or a later sign-out) with a false warning.
                    if (session is null && signedOutRevision == Interlocked.Read(ref authRevision))
                        LastLogoutRevocationFailed = true;
                }
                finally { transitionGate.Release(); }
            }
        }
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
        if (session is null || rootKey is null || !CanSynchronize)
        {
            throw new InvalidOperationException("账户尚未解锁，不能同步加密配置。");
        }

        var activeSession = session;
        var candidate = keyDeriver.Derive(masterPassword, StorageIdentifier(activeSession.Username));
        try
        {
            if (!CryptographicOperations.FixedTimeEquals(rootKey, candidate))
            {
                throw new CryptographicException("主密码不能解锁当前账户。");
            }

            var result = await RunAuthorizedWithGateAsync(activeSession, () => synchronizer.SynchronizeAsync(
                activeSession,
                StorageIdentifier(activeSession.Username),
                masterPassword,
                rootKey,
                cancellationToken,
                forceCompleteReconciliation), cancellationToken).ConfigureAwait(false);
            // A successful authenticated request may rotate the refresh token even
            // when an unknown payload deliberately prevents acknowledgement.
            await PersistReturnedSessionAsync(activeSession, result.Session, cancellationToken).ConfigureAwait(false);

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
        if (session is null || rootKey is null || !CanSynchronize)
        {
            throw new InvalidOperationException("账户尚未解锁，不能上传加密资产。");
        }

        var activeSession = session;
        var result = await RunAuthorizedWithGateAsync(activeSession, () => publisher.PublishAsync(
            activeSession,
            StorageIdentifier(activeSession.Username),
            asset,
            credential,
            jumpHostCredential,
            masterPassword,
            rootKey,
            cancellationToken), cancellationToken).ConfigureAwait(false);
        await PersistReturnedSessionAsync(activeSession, result.Session, cancellationToken).ConfigureAwait(false);
        return result;
    }

    public async ValueTask<EncryptedSnippetPublishResult> PublishSnippetsAsync(
        IEncryptedSnippetPublisher publisher,
        IReadOnlyList<Application.Sessions.SnippetRecord> snippets,
        string masterPassword,
        CancellationToken cancellationToken)
    {
        ArgumentNullException.ThrowIfNull(publisher);
        if (session is null || rootKey is null || !CanSynchronize)
            throw new InvalidOperationException("账户尚未解锁，不能上传加密快捷指令。");
        var activeSession = session;
        var result = await RunAuthorizedWithGateAsync(activeSession, () => publisher.PublishAsync(activeSession, StorageIdentifier(activeSession.Username), snippets, masterPassword, rootKey, cancellationToken), cancellationToken).ConfigureAwait(false);
        await PersistReturnedSessionAsync(activeSession, result.Session, cancellationToken).ConfigureAwait(false);
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
        if (session is null || rootKey is null || !CanSynchronize)
        {
            throw new InvalidOperationException("账户尚未解锁，不能同步删除资产。");
        }

        var activeSession = session;
        var result = await RunAuthorizedWithGateAsync(activeSession, () => publisher.TombstoneAsync(
            activeSession,
            StorageIdentifier(activeSession.Username),
            assetId,
            rootKey,
            cancellationToken), cancellationToken).ConfigureAwait(false);
        await PersistReturnedSessionAsync(activeSession, result.Session, cancellationToken).ConfigureAwait(false);
        return result;
    }

    private async ValueTask PersistReturnedSessionAsync(
        AccountSessionRecord expected,
        AccountSessionRecord replacement,
        CancellationToken cancellationToken,
        AccountSessionRecord? intermediate = null)
    {
        await transitionGate.WaitAsync(cancellationToken).ConfigureAwait(false);
        try
        {
            if (session != expected)
                throw new InvalidOperationException("账户会话已变化；不会恢复旧令牌。请重新登录或重试操作。");
            var stored = await sessionStore.ReadAsync(cancellationToken).ConfigureAwait(false);
            if (stored != replacement)
            {
                if (stored is null ||
                    (stored != expected && stored != intermediate) ||
                    !await sessionStore.TryReplaceAsync(stored, replacement, cancellationToken).ConfigureAwait(false))
                    throw new InvalidOperationException("账户会话已变化；不会恢复旧令牌。请重新登录或重试操作。");
            }
            session = replacement;
            if (replacement.MustChangePassword)
            {
                ClearRootKey();
                State = AccountLockState.SignedInLocked;
            }
        }
        finally { transitionGate.Release(); }
    }

    private async ValueTask<T> RunAuthorizedWithGateAsync<T>(AccountSessionRecord expected, Func<ValueTask<T>> operation, CancellationToken cancellationToken)
    {
        try { return await operation().ConfigureAwait(false); }
        catch (AccountProtocolException exception) when (exception.Code == "PASSWORD_CHANGE_REQUIRED")
        {
            await MarkPasswordChangeRequiredAsync(expected, cancellationToken).ConfigureAwait(false);
            throw;
        }
    }

    private async ValueTask MarkPasswordChangeRequiredAsync(AccountSessionRecord expected, CancellationToken cancellationToken)
    {
        await transitionGate.WaitAsync(cancellationToken).ConfigureAwait(false);
        try
        {
            if (session != expected) return;
            var stored = await sessionStore.ReadAsync(cancellationToken).ConfigureAwait(false);
            if (stored is null || stored.Username != expected.Username || stored.CreatedAt != expected.CreatedAt) return;
            var gated = stored with { MustChangePassword = true };
            if (!await sessionStore.TryReplaceAsync(stored, gated, cancellationToken).ConfigureAwait(false)) return;
            session = gated;
            ClearRootKey();
            State = AccountLockState.SignedInLocked;
        }
        finally { transitionGate.Release(); }
    }

    private void ClearRootKey() { if (rootKey is not null) CryptographicOperations.ZeroMemory(rootKey); rootKey = null; }
    private static bool IsV2ConfigBlob(ReadOnlySpan<byte> encrypted) =>
        encrypted.Length >= 4 && encrypted[..4].SequenceEqual("OTC2"u8);
    private static string StorageIdentifier(string username) => Convert.ToHexString(SHA256.HashData(Encoding.UTF8.GetBytes(username.Trim().ToLowerInvariant()))).ToLowerInvariant();
}
