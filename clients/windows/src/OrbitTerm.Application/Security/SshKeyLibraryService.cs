using OrbitTerm.Application.Sessions;
using OrbitTerm.NativeBridge;

namespace OrbitTerm.Application.Security;

public sealed class SshKeyLibraryService(
    ISshKeyVault keyVault,
    ICredentialVault credentialVault,
    TimeProvider? timeProvider = null,
    bool enforceCoreKeyValidation = false)
{
    private readonly TimeProvider clock = timeProvider ?? TimeProvider.System;

    public ValueTask<IReadOnlyList<SshKeyRecord>> ListAsync(CancellationToken cancellationToken) =>
        keyVault.ListAsync(cancellationToken);

    public async ValueTask<IReadOnlyList<SshKeyRecord>> ListAccessibleAsync(
        string? accountScope,
        bool accountUnlocked,
        CancellationToken cancellationToken)
    {
        var records = await keyVault.ListAsync(cancellationToken).ConfigureAwait(false);
        return records.Where(item =>
                item.SyncScope == SshKeySyncScope.LocalOnly ||
                (accountUnlocked && string.Equals(item.OwnerAccountScope, accountScope, StringComparison.Ordinal)))
            .ToArray();
    }

    /// <summary>
    /// Reads key material only for an explicit foreground security operation
    /// such as public-key derivation. Callers must never render or persist the
    /// returned private key outside a protected credential boundary.
    /// </summary>
    public async ValueTask<SshKeySecret> ReadSecretAsync(Guid keyId, CancellationToken cancellationToken) =>
        (await RequiredEntryAsync(keyId, cancellationToken).ConfigureAwait(false)).Secret;

    public async ValueTask<SshKeyRecord> ImportAsync(
        string name,
        string privateKey,
        string passphrase,
        CancellationToken cancellationToken,
        SshKeyOrigin origin = SshKeyOrigin.Imported,
        SshKeySyncScope syncScope = SshKeySyncScope.LocalOnly,
        string? ownerAccountScope = null)
    {
        var normalizedName = SshKeyMaterialPolicy.NormalizeName(name);
        var normalizedKey = SshKeyMaterialPolicy.NormalizePrivateKey(privateKey);
        var normalizedPassphrase = SshKeyMaterialPolicy.NormalizePassphrase(passphrase);
        if (enforceCoreKeyValidation)
        {
            _ = SshPrivateKeyInspector.Inspect(normalizedKey, normalizedPassphrase);
        }
        var fingerprint = SshKeyMaterialPolicy.MaterialFingerprint(normalizedKey);
        var existing = await keyVault.ListAsync(cancellationToken).ConfigureAwait(false);
        if (existing.Any(item => string.Equals(
                item.MaterialFingerprint,
                fingerprint,
                StringComparison.Ordinal)))
        {
            throw new InvalidOperationException("该私钥已存在于密钥库中。可直接将已有密钥分配给资产。");
        }

        var now = clock.GetUtcNow();
        if (syncScope == SshKeySyncScope.EndToEndEncrypted && string.IsNullOrWhiteSpace(ownerAccountScope))
        {
            throw new InvalidOperationException("端到端同步密钥必须绑定已解锁的账户。导入为仅本机密钥后再启用同步。 ");
        }
        var record = new SshKeyRecord(
            Guid.NewGuid(),
            normalizedName,
            SshKeyMaterialPolicy.DetectContainer(normalizedKey),
            fingerprint,
            now,
            now,
            origin,
            [],
            syncScope,
            syncScope == SshKeySyncScope.EndToEndEncrypted ? ownerAccountScope : null);
        await keyVault.SaveAsync(
            new SshKeyVaultEntry(record, new SshKeySecret(normalizedKey, normalizedPassphrase)),
            cancellationToken).ConfigureAwait(false);
        return record;
    }

    public async ValueTask<SshKeyRecord> RenameAsync(
        Guid keyId,
        string name,
        CancellationToken cancellationToken)
    {
        var entry = await RequiredEntryAsync(keyId, cancellationToken).ConfigureAwait(false);
        var updated = entry.Record with
        {
            Name = SshKeyMaterialPolicy.NormalizeName(name),
            UpdatedAt = clock.GetUtcNow(),
        };
        await keyVault.SaveAsync(entry with { Record = updated }, cancellationToken).ConfigureAwait(false);
        return updated;
    }

    public async ValueTask<SshKeyRecord> SetSyncScopeAsync(
        Guid keyId,
        SshKeySyncScope syncScope,
        string? accountScope,
        CancellationToken cancellationToken)
    {
        var entry = await RequiredEntryAsync(keyId, cancellationToken).ConfigureAwait(false);
        if (entry.Record.SyncScope == syncScope)
        {
            return entry.Record;
        }

        var updated = entry.Record with
        {
            SyncScope = syncScope,
            OwnerAccountScope = syncScope == SshKeySyncScope.EndToEndEncrypted
                ? string.IsNullOrWhiteSpace(accountScope)
                    ? throw new InvalidOperationException("请先登录并解锁账户，再启用密钥同步。")
                    : accountScope
                : null,
            UpdatedAt = clock.GetUtcNow(),
        };
        await keyVault.SaveAsync(entry with { Record = updated }, cancellationToken).ConfigureAwait(false);
        return updated;
    }

    public async ValueTask<IReadOnlyList<SshKeyVaultEntry>> ReadSynchronizedEntriesAsync(
        string accountScope,
        CancellationToken cancellationToken)
    {
        ArgumentException.ThrowIfNullOrWhiteSpace(accountScope);
        var records = await keyVault.ListAsync(cancellationToken).ConfigureAwait(false);
        var entries = new List<SshKeyVaultEntry>();
        foreach (var record in records.Where(item =>
                     item.SyncScope == SshKeySyncScope.EndToEndEncrypted &&
                     string.Equals(item.OwnerAccountScope, accountScope, StringComparison.Ordinal)))
        {
            var entry = await keyVault.ReadAsync(record.Id, cancellationToken).ConfigureAwait(false);
            if (entry is not null)
            {
                entries.Add(entry);
            }
        }

        return entries;
    }

    /// <summary>
    /// Rehydrates asset credentials after an encrypted key-library envelope and
    /// its asset records have arrived on a new device.  Assignment metadata is
    /// useful only when the corresponding DPAPI credential entry also contains
    /// the key. Existing different keys are never overwritten silently.
    /// </summary>
    public async ValueTask<SshKeyAssignmentReconciliationResult> ReconcileSynchronizedAssignmentsAsync(
        IReadOnlyCollection<ServerAssetRecord> assets,
        string accountScope,
        CancellationToken cancellationToken)
    {
        ArgumentNullException.ThrowIfNull(assets);
        ArgumentException.ThrowIfNullOrWhiteSpace(accountScope);
        var eligibleAssets = assets
            .Where(asset =>
                asset.Transport == ServerTransport.Ssh &&
                asset.StorageScope == AssetStorageScope.AccountSynced &&
                string.Equals(asset.OwnerAccountScope, accountScope, StringComparison.Ordinal))
            .ToDictionary(asset => asset.Id);
        var entries = await ReadSynchronizedEntriesAsync(accountScope, cancellationToken).ConfigureAwait(false);
        var assignments = entries
            .SelectMany(entry => entry.Record.AssignedAssetIds.Select(assetId => (assetId, entry)))
            .Where(item => eligibleAssets.ContainsKey(item.assetId))
            .GroupBy(item => item.assetId)
            .ToArray();
        var restored = 0;
        var unchanged = 0;
        var conflicted = 0;

        foreach (var assignment in assignments)
        {
            cancellationToken.ThrowIfCancellationRequested();
            var candidates = assignment.Select(item => item.entry).ToArray();
            if (candidates.Length != 1)
            {
                conflicted++;
                continue;
            }

            var asset = eligibleAssets[assignment.Key];
            var entry = candidates[0];
            var current = await credentialVault.ReadAsync(asset.CredentialId, cancellationToken).ConfigureAwait(false);
            if (!string.IsNullOrWhiteSpace(current.PrivateKey))
            {
                var currentFingerprint = SshKeyMaterialPolicy.MaterialFingerprint(current.PrivateKey);
                if (!string.Equals(currentFingerprint, entry.Record.MaterialFingerprint, StringComparison.Ordinal))
                {
                    conflicted++;
                    continue;
                }
            }

            var replacement = current with
            {
                PrivateKey = entry.Secret.PrivateKey,
                PrivateKeyPassphrase = entry.Secret.Passphrase,
            };
            if (replacement == current)
            {
                unchanged++;
                continue;
            }

            await credentialVault.SaveAsync(asset.CredentialId, replacement, cancellationToken).ConfigureAwait(false);
            restored++;
        }

        return new SshKeyAssignmentReconciliationResult(restored, unchanged, conflicted);
    }

    /// <summary>
    /// Applies an already authenticated, end-to-end decrypted entry. The vault
    /// still normalizes and protects the material with the current Windows
    /// user's DPAPI before this method returns.
    /// </summary>
    public ValueTask SaveSynchronizedEntryAsync(
        SshKeyVaultEntry entry,
        string accountScope,
        CancellationToken cancellationToken)
    {
        ArgumentNullException.ThrowIfNull(entry);
        ArgumentException.ThrowIfNullOrWhiteSpace(accountScope);
        var normalizedKey = SshKeyMaterialPolicy.NormalizePrivateKey(entry.Secret.PrivateKey);
        var normalizedPassphrase = SshKeyMaterialPolicy.NormalizePassphrase(entry.Secret.Passphrase);
        if (enforceCoreKeyValidation)
        {
            _ = SshPrivateKeyInspector.Inspect(normalizedKey, normalizedPassphrase);
        }
        var normalizedFingerprint = SshKeyMaterialPolicy.MaterialFingerprint(normalizedKey);
        if (!string.Equals(normalizedFingerprint, entry.Record.MaterialFingerprint, StringComparison.Ordinal))
        {
            throw new InvalidOperationException("同步密钥指纹与私钥内容不匹配。");
        }

        return keyVault.SaveAsync(entry with
        {
            Record = entry.Record with
            {
                Format = SshKeyMaterialPolicy.DetectContainer(normalizedKey),
                Origin = SshKeyOrigin.Synchronized,
                SyncScope = SshKeySyncScope.EndToEndEncrypted,
                OwnerAccountScope = accountScope,
            },
            Secret = new SshKeySecret(normalizedKey, normalizedPassphrase),
        }, cancellationToken);
    }

    public ValueTask DeleteSynchronizedEntryAsync(Guid keyId, CancellationToken cancellationToken) =>
        keyVault.DeleteAsync(keyId, cancellationToken);

    public async ValueTask<SshKeyRecord> AssignToAssetAsync(
        Guid keyId,
        ServerAssetRecord asset,
        CancellationToken cancellationToken)
    {
        ArgumentNullException.ThrowIfNull(asset);
        if (asset.Id == Guid.Empty || asset.CredentialId == Guid.Empty)
        {
            throw new ArgumentException("资产标识或凭据标识无效。", nameof(asset));
        }

        var entry = await RequiredEntryAsync(keyId, cancellationToken).ConfigureAwait(false);
        var credential = await credentialVault.ReadAsync(asset.CredentialId, cancellationToken).ConfigureAwait(false);
        var allKeys = await keyVault.ListAsync(cancellationToken).ConfigureAwait(false);
        var otherAssignments = allKeys
            .Where(item => item.Id != keyId && item.AssignedAssetIds.Contains(asset.Id))
            .ToArray();
        var updatedOthers = new List<SshKeyVaultEntry>(otherAssignments.Length);
        foreach (var other in otherAssignments)
        {
            var otherEntry = await keyVault.ReadAsync(other.Id, cancellationToken).ConfigureAwait(false);
            if (otherEntry is null)
            {
                continue;
            }

            updatedOthers.Add(otherEntry with
            {
                Record = otherEntry.Record with
                {
                    AssignedAssetIds = otherEntry.Record.AssignedAssetIds.Where(id => id != asset.Id).ToArray(),
                    UpdatedAt = clock.GetUtcNow(),
                },
            });
        }

        var updated = entry.Record;
        if (!entry.Record.AssignedAssetIds.Contains(asset.Id))
        {
            var assigned = entry.Record.AssignedAssetIds
                .Append(asset.Id)
                .Distinct()
                .Order()
                .ToArray();
            updated = entry.Record with { AssignedAssetIds = assigned, UpdatedAt = clock.GetUtcNow() };
        }

        await credentialVault.SaveAsync(
            asset.CredentialId,
            credential with
            {
                PrivateKey = entry.Secret.PrivateKey,
                PrivateKeyPassphrase = entry.Secret.Passphrase,
            },
            cancellationToken).ConfigureAwait(false);
        try
        {
            foreach (var other in updatedOthers)
                await keyVault.SaveAsync(other, cancellationToken).ConfigureAwait(false);
            await keyVault.SaveAsync(entry with { Record = updated }, cancellationToken).ConfigureAwait(false);
        }
        catch
        {
            // Keep the library index and credential assignment from diverging
            // if persistence fails after the credential has been replaced.
            await credentialVault.SaveAsync(asset.CredentialId, credential, CancellationToken.None).ConfigureAwait(false);
            foreach (var original in otherAssignments)
            {
                var originalEntry = await keyVault.ReadAsync(original.Id, CancellationToken.None).ConfigureAwait(false);
                if (originalEntry is not null)
                    await keyVault.SaveAsync(originalEntry with { Record = original }, CancellationToken.None).ConfigureAwait(false);
            }
            throw;
        }
        return updated;
    }

    public async ValueTask<SshKeyRecord> RemoveFromAssetAsync(
        Guid keyId,
        ServerAssetRecord asset,
        CancellationToken cancellationToken)
    {
        ArgumentNullException.ThrowIfNull(asset);
        var entry = await RequiredEntryAsync(keyId, cancellationToken).ConfigureAwait(false);
        var credential = await credentialVault.ReadAsync(asset.CredentialId, cancellationToken).ConfigureAwait(false);
        var credentialWasChanged = false;
        if (!string.IsNullOrWhiteSpace(credential.PrivateKey) &&
            string.Equals(
                SshKeyMaterialPolicy.MaterialFingerprint(credential.PrivateKey),
                entry.Record.MaterialFingerprint,
                StringComparison.Ordinal))
        {
            await credentialVault.SaveAsync(
                asset.CredentialId,
                credential with { PrivateKey = string.Empty, PrivateKeyPassphrase = string.Empty },
                cancellationToken).ConfigureAwait(false);
            credentialWasChanged = true;
        }

        var assigned = entry.Record.AssignedAssetIds.Where(id => id != asset.Id).ToArray();
        var updated = entry.Record with { AssignedAssetIds = assigned, UpdatedAt = clock.GetUtcNow() };
        try
        {
            await keyVault.SaveAsync(entry with { Record = updated }, cancellationToken).ConfigureAwait(false);
        }
        catch
        {
            if (credentialWasChanged)
                await credentialVault.SaveAsync(asset.CredentialId, credential, CancellationToken.None).ConfigureAwait(false);
            throw;
        }
        return updated;
    }

    public async ValueTask DeleteAsync(Guid keyId, CancellationToken cancellationToken)
    {
        var entry = await RequiredEntryAsync(keyId, cancellationToken).ConfigureAwait(false);
        if (entry.Record.AssignedAssetIds.Count > 0)
        {
            throw new InvalidOperationException("该密钥仍分配给资产。请先从全部资产移除，再删除密钥。");
        }

        await keyVault.DeleteAsync(keyId, cancellationToken).ConfigureAwait(false);
    }

    private async ValueTask<SshKeyVaultEntry> RequiredEntryAsync(
        Guid keyId,
        CancellationToken cancellationToken)
    {
        if (keyId == Guid.Empty)
        {
            throw new ArgumentException("密钥标识不能为空。", nameof(keyId));
        }

        return await keyVault.ReadAsync(keyId, cancellationToken).ConfigureAwait(false)
            ?? throw new KeyNotFoundException("密钥不存在或已被删除。");
    }
}

public readonly record struct SshKeyAssignmentReconciliationResult(
    int Restored,
    int Unchanged,
    int Conflicted);
