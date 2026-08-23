using OrbitTerm.Application.Sessions;

namespace OrbitTerm.Application.Accounts;

public enum PortForwardProfileSyncScope
{
    LocalOnly,
    EndToEndEncrypted,
}

public sealed record PortForwardProfileRecord(
    PortForwardingRule Rule,
    DateTimeOffset CreatedAt,
    DateTimeOffset UpdatedAt,
    PortForwardProfileSyncScope SyncScope,
    string? OwnerAccountScope);

public sealed record PortForwardProfileVaultDocument(
    int Version,
    IReadOnlyList<PortForwardProfileRecord> Profiles,
    IReadOnlyDictionary<Guid, long> Tombstones);

/// <summary>
/// OS-neutral persistence boundary. Windows implements this with DPAPI, Apple
/// with Keychain, Android with Keystore and a future Linux client can use
/// Secret Service/libsecret without changing sync or UI semantics.
/// </summary>
public interface IPortForwardProfileVault
{
    ValueTask<PortForwardProfileVaultDocument> ReadAsync(string accountScope, CancellationToken cancellationToken);
    ValueTask SaveAsync(string accountScope, PortForwardProfileVaultDocument document, CancellationToken cancellationToken);
    ValueTask DeleteAccountAsync(string accountScope, CancellationToken cancellationToken);
}

public sealed class PortForwardProfileLibrary(IPortForwardProfileVault vault)
{
    public const int SchemaVersion = 1;

    public async ValueTask<IReadOnlyList<PortForwardProfileRecord>> ListAsync(
        string accountScope,
        Guid? assetId,
        CancellationToken cancellationToken)
    {
        ValidateScope(accountScope);
        var document = await vault.ReadAsync(accountScope, cancellationToken).ConfigureAwait(false);
        return document.Profiles
            .Where(item => assetId is null || item.Rule.AssetId == assetId)
            .OrderBy(item => item.Rule.Name, StringComparer.CurrentCultureIgnoreCase)
            .ThenBy(item => item.Rule.Id)
            .ToArray();
    }

    public async ValueTask<PortForwardProfileRecord> SaveAsync(
        string accountScope,
        PortForwardProfileRecord profile,
        CancellationToken cancellationToken)
    {
        ValidateScope(accountScope);
        var rule = PortForwardingPolicy.Validate(profile.Rule with { StartAfterVerifiedConnection = false });
        var owner = profile.SyncScope == PortForwardProfileSyncScope.EndToEndEncrypted
            ? accountScope
            : profile.OwnerAccountScope;
        if (profile.SyncScope == PortForwardProfileSyncScope.EndToEndEncrypted &&
            !string.Equals(owner, accountScope, StringComparison.Ordinal))
            throw new InvalidOperationException("端口映射配置不能跨账户保存。");

        var normalized = profile with { Rule = rule, OwnerAccountScope = owner };
        var document = await vault.ReadAsync(accountScope, cancellationToken).ConfigureAwait(false);
        var profiles = document.Profiles.Where(item => item.Rule.Id != rule.Id).ToList();
        if (profiles.Count(item => item.Rule.AssetId == rule.AssetId) >= PortForwardingPolicy.MaximumRulesPerAsset)
            throw new InvalidOperationException($"每项资产最多保存 {PortForwardingPolicy.MaximumRulesPerAsset} 条端口映射配置。");
        profiles.Add(normalized);
        var tombstones = document.Tombstones.ToDictionary(item => item.Key, item => item.Value);
        if (tombstones.GetValueOrDefault(rule.Id) < normalized.UpdatedAt.ToUnixTimeSeconds()) tombstones.Remove(rule.Id);
        await vault.SaveAsync(accountScope, new(SchemaVersion, profiles, tombstones), cancellationToken).ConfigureAwait(false);
        return normalized;
    }

    public async ValueTask DeleteAsync(string accountScope, Guid id, CancellationToken cancellationToken)
    {
        ValidateScope(accountScope);
        if (id == Guid.Empty) throw new ArgumentException("配置标识无效。", nameof(id));
        var document = await vault.ReadAsync(accountScope, cancellationToken).ConfigureAwait(false);
        var removed = document.Profiles.SingleOrDefault(item => item.Rule.Id == id);
        if (removed is null) return;
        var profiles = document.Profiles.Where(item => item.Rule.Id != id).ToArray();
        var tombstones = document.Tombstones.ToDictionary(item => item.Key, item => item.Value);
        if (removed.SyncScope == PortForwardProfileSyncScope.EndToEndEncrypted)
            tombstones[id] = Math.Max(tombstones.GetValueOrDefault(id), DateTimeOffset.UtcNow.ToUnixTimeSeconds());
        await vault.SaveAsync(accountScope, new(SchemaVersion, profiles, tombstones), cancellationToken).ConfigureAwait(false);
    }

    internal async ValueTask ReplaceSynchronizedAsync(
        string accountScope,
        IReadOnlyList<PortForwardProfileRecord> synchronized,
        IReadOnlyDictionary<Guid, long> tombstones,
        CancellationToken cancellationToken)
    {
        var document = await vault.ReadAsync(accountScope, cancellationToken).ConfigureAwait(false);
        var localOnly = document.Profiles.Where(item => item.SyncScope == PortForwardProfileSyncScope.LocalOnly);
        await vault.SaveAsync(accountScope, new(
            SchemaVersion,
            localOnly.Concat(synchronized).ToArray(),
            tombstones), cancellationToken).ConfigureAwait(false);
    }

    internal ValueTask<PortForwardProfileVaultDocument> ReadDocumentAsync(
        string accountScope,
        CancellationToken cancellationToken) => vault.ReadAsync(accountScope, cancellationToken);

    private static void ValidateScope(string accountScope)
    {
        if (string.IsNullOrWhiteSpace(accountScope)) throw new ArgumentException("账户作用域不能为空。", nameof(accountScope));
    }
}
