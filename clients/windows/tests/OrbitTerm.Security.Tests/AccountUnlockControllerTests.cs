using OrbitTerm.Application.Accounts;
using OrbitTerm.NativeBridge;
using System.Security.Cryptography;
using System.Text;
using Xunit;

namespace OrbitTerm.Security.Tests;

public sealed class AccountUnlockControllerTests
{
    [Fact]
    public async Task LoginStaysLockedUntilReadOnlyVerificationSucceeds()
    {
        OrbitNativeLibraryLoader.Register();
        var controller = new AccountUnlockController(new Store(), new Protocol(), new Verifier(true), keyDeriver: new Deriver());
        await controller.LoginAsync(new AccountLoginRequest("User@Example.Com", "login-password"), CancellationToken.None);
        Assert.Equal(AccountLockState.SignedInLocked, controller.State);
        Assert.False(controller.CanSynchronize);

        var outcome = await controller.UnlockAsync("correct horse", CancellationToken.None);
        Assert.Equal(AccountUnlockResult.Unlocked, outcome);
        Assert.True(controller.CanSynchronize);
        controller.Lock();
        Assert.False(controller.CanSynchronize);
    }

    [Fact]
    public async Task LoginCanonicalizesUsernameBeforeItReachesTheProtocolOrSessionStore()
    {
        OrbitNativeLibraryLoader.Register();
        var protocol = new Protocol();
        var sessionStore = new Store();
        var controller = new AccountUnlockController(sessionStore, protocol, new Verifier(true), keyDeriver: new Deriver());

        await controller.LoginAsync(new AccountLoginRequest(" User@Example.Com ", "login-password"), CancellationToken.None);

        Assert.Equal("user@example.com", protocol.LastLoginRequest?.Username);
        Assert.Equal("user@example.com", sessionStore.Value?.Username);
        Assert.Equal(AccountLockState.SignedInLocked, controller.State);
    }

    [Fact]
    public async Task SuccessfulFirstVerificationPersistsAndReusesLocalVerifier()
    {
        OrbitNativeLibraryLoader.Register();
        var store = new VerifierStore();
        var sessionStore = new Store();
        var remoteVerifier = new Verifier(true);
        var controller = new AccountUnlockController(sessionStore, new Protocol(), remoteVerifier, store, new Deriver());
        await controller.LoginAsync(new AccountLoginRequest("user", "login"), CancellationToken.None);
        Assert.Equal(AccountUnlockResult.Unlocked, await controller.UnlockAsync("correct horse", CancellationToken.None));
        Assert.NotNull(store.Value);
        Assert.Equal(1, remoteVerifier.Calls);

        var secondController = new AccountUnlockController(sessionStore, new Protocol(), new Verifier(false), store, new Deriver());
        await secondController.LoadAsync(CancellationToken.None);
        Assert.Equal(AccountUnlockResult.Unlocked, await secondController.UnlockAsync("correct horse", CancellationToken.None));
        Assert.True(secondController.CanSynchronize);
    }

    [Fact]
    public async Task RegistrationCanonicalizesIdentityThenCreatesAFirstMasterVerifierOnlyForAnEmptyAccount()
    {
        var protocol = new RegistrationProtocol();
        var verifierStore = new VerifierStore();
        var controller = new AccountUnlockController(
            new Store(),
            protocol,
            new Verifier(null),
            verifierStore,
            new Deriver());

        await controller.RegisterAndLoginAsync(
            new AccountRegisterRequest(" New@Example.Com ", "Login-password-123!", " invite-42 "),
            CancellationToken.None);

        Assert.Equal("new@example.com", protocol.RegisterRequest?.Username);
        Assert.Equal("invite-42", protocol.RegisterRequest?.InviteCode);
        Assert.Equal("new@example.com", protocol.LastLoginRequest?.Username);
        Assert.Equal(AccountLockState.SignedInLocked, controller.State);

        var outcome = await controller.InitializeEmptyAccountMasterPasswordAsync(
            "Master-password-123!",
            CancellationToken.None);

        Assert.Equal(AccountUnlockResult.Unlocked, outcome);
        Assert.True(controller.CanSynchronize);
        Assert.NotNull(verifierStore.Value);
    }

    [Fact]
    public async Task MasterPasswordRotationReencryptsV2AndLegacyCiphertextAndUpdatesLocalVerifier()
    {
        OrbitNativeLibraryLoader.Register();
        const string username = "rotation-user";
        const string currentMaster = "Current-master-123!";
        const string nextMaster = "Next-master-456!";
        var scope = Convert.ToHexString(SHA256.HashData(Encoding.UTF8.GetBytes(username))).ToLowerInvariant();
        var currentRoot = OrbitConfigCrypto.DeriveConfigRootKeyV2(currentMaster, scope);
        var activePlaintext = Encoding.UTF8.GetBytes("{\"kind\":\"asset\",\"name\":\"active\"}");
        var deletedPlaintext = Encoding.UTF8.GetBytes("{\"kind\":\"asset\",\"name\":\"deleted\"}");
        var activeCiphertext = OrbitConfigCrypto.EncryptConfigV2(currentRoot, activePlaintext);
        var deletedCiphertext = OrbitConfigCrypto.EncryptConfigLegacy(currentMaster, deletedPlaintext);
        CryptographicOperations.ZeroMemory(currentRoot);

        var protocol = new RotationProtocol([
            new EncryptedConfigRecord(1, Guid.NewGuid().ToString("D"), null, Convert.ToBase64String(activeCiphertext), "clock-a", "active", 1, DateTimeOffset.UtcNow),
            new EncryptedConfigRecord(2, Guid.NewGuid().ToString("D"), null, Convert.ToBase64String(deletedCiphertext), "clock-b", "deleted", 2, DateTimeOffset.UtcNow),
        ]);
        var sessionStore = new Store();
        var verifierStore = new VerifierStore();
        var controller = new AccountUnlockController(
            sessionStore,
            protocol,
            new Verifier(true),
            verifierStore,
            new NativeConfigRootKeyDeriver());
        await controller.LoginAsync(new AccountLoginRequest(username, "login-password"), CancellationToken.None);
        Assert.Equal(AccountUnlockResult.Unlocked, await controller.UnlockAsync(currentMaster, CancellationToken.None));

        await controller.RotateMasterPasswordAsync(
            currentMaster,
            nextMaster,
            "login-password",
            CancellationToken.None);

        Assert.Equal(new ulong[] { 1, 2 }, protocol.RotationRequest!.Items.Select(item => item.Id).ToArray());
        Assert.Equal(new[] { "clock-a", "clock-b" }, protocol.RotationRequest.Items.Select(item => item.ExpectedVectorClock).ToArray());
        var decryptedActive = OrbitConfigCrypto.DecryptConfigLegacy(
            nextMaster,
            Convert.FromBase64String(protocol.RotationRequest.Items[0].EncryptedBlobBase64));
        var decryptedDeleted = OrbitConfigCrypto.DecryptConfigLegacy(
            nextMaster,
            Convert.FromBase64String(protocol.RotationRequest.Items[1].EncryptedBlobBase64));
        Assert.Equal(activePlaintext, decryptedActive);
        Assert.Equal(deletedPlaintext, decryptedDeleted);
        Assert.True(controller.IsCurrentMasterPassword(nextMaster));
        Assert.False(controller.IsCurrentMasterPassword(currentMaster));
        Assert.Equal("rotated-access", sessionStore.Value?.AccessToken);
        var nextRoot = OrbitConfigCrypto.DeriveConfigRootKeyV2(nextMaster, scope);
        Assert.Equal(SHA256.HashData(nextRoot), verifierStore.Value);

        CryptographicOperations.ZeroMemory(activePlaintext);
        CryptographicOperations.ZeroMemory(deletedPlaintext);
        CryptographicOperations.ZeroMemory(activeCiphertext);
        CryptographicOperations.ZeroMemory(deletedCiphertext);
        CryptographicOperations.ZeroMemory(decryptedActive);
        CryptographicOperations.ZeroMemory(decryptedDeleted);
        CryptographicOperations.ZeroMemory(nextRoot);
    }

    private sealed class Store : IAccountSessionStore { public AccountSessionRecord? Value; public ValueTask<AccountSessionRecord?> ReadAsync(CancellationToken c) => ValueTask.FromResult(Value); public ValueTask SaveAsync(AccountSessionRecord s, CancellationToken c) { Value = s; return ValueTask.CompletedTask; } public ValueTask ClearAsync(CancellationToken c) => ValueTask.CompletedTask; }
    private sealed class Protocol : IOrbitAccountProtocol { public AccountLoginRequest? LastLoginRequest { get; private set; } public ValueTask<AccountLoginResponse> LoginAsync(AccountLoginRequest r, CancellationToken c) { LastLoginRequest = r; return ValueTask.FromResult(new AccountLoginResponse(null,"access","refresh","bearer",null,null)); } public ValueTask<AccountLoginResponse> RefreshAsync(AccountRefreshRequest r, CancellationToken c) => throw new NotSupportedException(); }
    private sealed class RegistrationProtocol : IOrbitAccountProtocol, IOrbitAccountRegistrationProtocol
    {
        public AccountRegisterRequest? RegisterRequest { get; private set; }
        public AccountLoginRequest? LastLoginRequest { get; private set; }
        public ValueTask<AccountRegisterResponse> RegisterAsync(AccountRegisterRequest request, CancellationToken cancellationToken)
        {
            RegisterRequest = request;
            return ValueTask.FromResult(new AccountRegisterResponse(1, request.Username, "2026-08-10T00:00:00Z"));
        }
        public ValueTask<AccountLoginResponse> LoginAsync(AccountLoginRequest request, CancellationToken cancellationToken)
        {
            LastLoginRequest = request;
            return ValueTask.FromResult(new AccountLoginResponse(null, "access", "refresh", "bearer", null, null));
        }
        public ValueTask<AccountLoginResponse> RefreshAsync(AccountRefreshRequest request, CancellationToken cancellationToken) => throw new NotSupportedException();
    }
    private sealed class RotationProtocol(IReadOnlyList<EncryptedConfigRecord> snapshot) : IOrbitAccountProtocol, IOrbitAccountSecurityProtocol
    {
        public MasterKeyRotationRequest? RotationRequest { get; private set; }
        public ValueTask<AccountLoginResponse> LoginAsync(AccountLoginRequest request, CancellationToken cancellationToken) => ValueTask.FromResult(new AccountLoginResponse(null, "access", "refresh", "bearer", null, null));
        public ValueTask<AccountLoginResponse> RefreshAsync(AccountRefreshRequest request, CancellationToken cancellationToken) => throw new NotSupportedException();
        public ValueTask<AuthorizedProtocolResult<AccountLoginResponse>> ChangePasswordAsync(AccountSessionRecord session, AccountPasswordChangeRequest request, CancellationToken cancellationToken) => throw new NotSupportedException();
        public ValueTask<AuthorizedProtocolResult<IReadOnlyList<EncryptedConfigRecord>>> PullCompleteConfigSnapshotAsync(AccountSessionRecord session, CancellationToken cancellationToken) => ValueTask.FromResult(new AuthorizedProtocolResult<IReadOnlyList<EncryptedConfigRecord>>(snapshot, session));
        public ValueTask<AuthorizedProtocolResult<AccountLoginResponse>> RotateMasterKeyAsync(AccountSessionRecord session, MasterKeyRotationRequest request, CancellationToken cancellationToken)
        {
            RotationRequest = request;
            return ValueTask.FromResult(new AuthorizedProtocolResult<AccountLoginResponse>(
                new AccountLoginResponse(null, "rotated-access", "rotated-refresh", "bearer", null, null),
                session));
        }
    }
    private sealed class Verifier(bool? result) : IEncryptedConfigUnlockVerifier { public int Calls { get; private set; } public ValueTask<bool?> VerifyAsync(AccountSessionRecord s, string password, byte[] key, CancellationToken c) { Calls++; return ValueTask.FromResult(result); } }
    private sealed class VerifierStore : IAccountUnlockVerifierStore { public byte[]? Value; public ValueTask<byte[]?> ReadAsync(string s, CancellationToken c) => ValueTask.FromResult(Value?.ToArray()); public ValueTask SaveAsync(string s, byte[] v, CancellationToken c) { Value = v.ToArray(); return ValueTask.CompletedTask; } }
    private sealed class Deriver : IConfigRootKeyDeriver { public byte[] Derive(string p, string s) => Enumerable.Repeat((byte)7, 32).ToArray(); }
}
