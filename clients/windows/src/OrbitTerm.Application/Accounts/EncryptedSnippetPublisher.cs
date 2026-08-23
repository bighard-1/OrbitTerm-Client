using System.Security.Cryptography;
using System.Text.Json;
using OrbitTerm.Application.Sessions;
using OrbitTerm.NativeBridge;

namespace OrbitTerm.Application.Accounts;

public sealed record EncryptedSnippetPublishResult(AccountSessionRecord Session, int PublishedCount);

public interface IEncryptedSnippetPublisher
{
    ValueTask<EncryptedSnippetPublishResult> PublishAsync(
        AccountSessionRecord session,
        string accountScope,
        IReadOnlyList<SnippetRecord> snippets,
        string masterPassword,
        byte[] rootKey,
        CancellationToken cancellationToken);
}

/// <summary>
/// Writes the exact <c>orbit_snippets</c> version-1 envelope consumed by the
/// released Apple clients. Dates use Apple's 2001 reference-date seconds, not
/// .NET's ISO representation, so the payload remains cross-platform readable.
/// </summary>
public sealed class EncryptedSnippetPublisher(
    IOrbitEncryptedSyncProtocol protocol,
    IEncryptedSyncStateStore stateStore) : IEncryptedSnippetPublisher
{
    private const long AppleReferenceEpochUnix = 978_307_200;
    private static readonly JsonSerializerOptions JsonOptions = new(JsonSerializerDefaults.Web);

    public async ValueTask<EncryptedSnippetPublishResult> PublishAsync(
        AccountSessionRecord session,
        string accountScope,
        IReadOnlyList<SnippetRecord> snippets,
        string masterPassword,
        byte[] rootKey,
        CancellationToken cancellationToken)
    {
        ArgumentNullException.ThrowIfNull(session);
        ArgumentNullException.ThrowIfNull(snippets);
        ArgumentException.ThrowIfNullOrWhiteSpace(accountScope);
        ArgumentException.ThrowIfNullOrWhiteSpace(masterPassword);
        if (rootKey is null || rootKey.Length != 32) throw new ArgumentException("同步根密钥长度无效。", nameof(rootKey));

        var state = await stateStore.ReadAsync(accountScope, cancellationToken).ConfigureAwait(false)
            ?? new EncryptedSyncState(Guid.NewGuid(), 0);
        var timestamp = Math.Max(DateTimeOffset.UtcNow.ToUnixTimeSeconds(),
            snippets.Count == 0 ? 0 : snippets.Max(item => item.UpdatedAt.ToUnixTimeSeconds()));
        var envelope = new SnippetEnvelope(
            "orbit_snippets",
            1,
            timestamp,
            snippets.Select(SnippetWire.FromRecord).ToArray());
        var plaintext = JsonSerializer.SerializeToUtf8Bytes(envelope, JsonOptions);
        byte[] encrypted = [];
        try
        {
            // The legacy cipher remains the write format until the deployed Apple
            // capability handshake permits OTC2 writes.
            encrypted = OrbitConfigCrypto.EncryptConfigLegacy(masterPassword, plaintext);
            var vectorClock = BumpVectorClock(state.SnippetMetadata?.VectorClock);
            var uploaded = await protocol.UploadAsync(
                session,
                new EncryptedConfigUpload(
                    state.SnippetMetadata?.RemoteId,
                    null,
                    null,
                    Convert.ToBase64String(encrypted),
                    vectorClock),
                cancellationToken).ConfigureAwait(false);
            await stateStore.SaveAsync(accountScope, state with
            {
                SnippetMetadata = new EncryptedSnippetSyncMetadata(uploaded.Value.Id, uploaded.Value.VectorClock, timestamp),
            }, cancellationToken).ConfigureAwait(false);
            return new EncryptedSnippetPublishResult(uploaded.Session, snippets.Count);
        }
        finally
        {
            CryptographicOperations.ZeroMemory(plaintext);
            CryptographicOperations.ZeroMemory(encrypted);
        }
    }

    private static string BumpVectorClock(string? raw)
    {
        var values = string.IsNullOrWhiteSpace(raw)
            ? new Dictionary<string, int>(StringComparer.Ordinal)
            : JsonSerializer.Deserialize<Dictionary<string, int>>(raw) ?? new(StringComparer.Ordinal);
        values["snippet_client"] = values.GetValueOrDefault("snippet_client") + 1;
        return JsonSerializer.Serialize(values, JsonOptions);
    }

    private sealed record SnippetEnvelope(string Kind, int Version, long UpdatedAtUnix, SnippetWire[] Snippets);

    private sealed record SnippetWire(Guid Id, string Title, string Command, string Category, double CreatedAt, double UpdatedAt, SnippetScopeWire AssetScope)
    {
        public static SnippetWire FromRecord(SnippetRecord record) => new(
            record.Id, record.Title, record.Command, record.Category,
            record.CreatedAt.ToUnixTimeMilliseconds() / 1000d - AppleReferenceEpochUnix,
            record.UpdatedAt.ToUnixTimeMilliseconds() / 1000d - AppleReferenceEpochUnix,
            SnippetScopeWire.FromScope(record.EffectiveAssetScope));
    }

    private sealed record SnippetScopeWire(string Mode, [property: System.Text.Json.Serialization.JsonPropertyName("assetIDs")] Guid[] AssetIds)
    {
        public static SnippetScopeWire FromScope(SnippetAssetScope scope) => new(scope.Mode, scope.AssetIds.ToArray());
    }
}
