using System.Security.Cryptography;
using System.Text.Json;
using OrbitTerm.Application.Sessions;

namespace OrbitTerm.Application.Accounts;

public sealed record EncryptedPortForwardProfileSyncMetadata(
    ulong? RemoteId,
    string VectorClock,
    long EnvelopeTime,
    string PayloadFingerprint);

internal sealed record PortForwardProfileMergeResult(
    int Applied,
    int Deleted,
    int Conflicted,
    EncryptedPortForwardProfileSyncMetadata Metadata);

internal sealed class EncryptedPortForwardProfileSynchronization(PortForwardProfileLibrary library)
{
    public async ValueTask<PortForwardProfileMergeResult> ApplyAsync(
        PortForwardProfileSyncEnvelope remote,
        string accountScope,
        CancellationToken cancellationToken)
    {
        var documentProfiles = (await library.ListAsync(accountScope, null, cancellationToken).ConfigureAwait(false)).ToArray();
        var localOnlyIds = documentProfiles.Where(item => item.SyncScope == PortForwardProfileSyncScope.LocalOnly)
            .Select(item => item.Rule.Id).ToHashSet();
        var synchronized = documentProfiles.Where(item => item.SyncScope == PortForwardProfileSyncScope.EndToEndEncrypted)
            .ToDictionary(item => item.Rule.Id);
        var currentDocument = await library.ReadDocumentAsync(accountScope, cancellationToken).ConfigureAwait(false);
        var tombstones = currentDocument.Tombstones.ToDictionary(item => item.Key, item => item.Value);
        foreach (var item in remote.Tombstones)
            tombstones[item.Id] = Math.Max(tombstones.GetValueOrDefault(item.Id), item.DeletedAtUnix);

        var applied = 0; var deleted = 0; var conflicted = 0;
        foreach (var wire in remote.Profiles.OrderBy(item => item.UpdatedAtUnix).ThenBy(item => item.Id))
        {
            if (localOnlyIds.Contains(wire.Id)) { conflicted++; continue; }
            if (tombstones.GetValueOrDefault(wire.Id) >= wire.UpdatedAtUnix)
            {
                if (synchronized.Remove(wire.Id)) deleted++;
                continue;
            }
            if (synchronized.TryGetValue(wire.Id, out var local) && local.UpdatedAt.ToUnixTimeSeconds() > wire.UpdatedAtUnix)
                continue;
            synchronized[wire.Id] = ToRecord(wire, accountScope);
            applied++;
        }
        foreach (var item in tombstones)
        {
            if (synchronized.TryGetValue(item.Key, out var local) && local.UpdatedAt.ToUnixTimeSeconds() <= item.Value)
            { synchronized.Remove(item.Key); deleted++; }
        }
        await library.ReplaceSynchronizedAsync(accountScope, synchronized.Values.ToArray(), tombstones, cancellationToken).ConfigureAwait(false);
        return new(applied, deleted, conflicted, new(
            remote.RemoteId == 0 ? null : remote.RemoteId,
            remote.VectorClock,
            remote.UpdatedAtUnix,
            Fingerprint(remote.Profiles, remote.Tombstones)));
    }

    public async ValueTask<(PortForwardProfileSyncEnvelope Envelope, string Fingerprint)> BuildLocalEnvelopeAsync(
        string accountScope,
        EncryptedPortForwardProfileSyncMetadata? metadata,
        CancellationToken cancellationToken)
    {
        var profiles = (await library.ListAsync(accountScope, null, cancellationToken).ConfigureAwait(false))
            .Where(item => item.SyncScope == PortForwardProfileSyncScope.EndToEndEncrypted &&
                string.Equals(item.OwnerAccountScope, accountScope, StringComparison.Ordinal))
            .Select(ToWire).OrderBy(item => item.Id).ToArray();
        var document = await library.ReadDocumentAsync(accountScope, cancellationToken).ConfigureAwait(false);
        var tombstones = document.Tombstones.OrderBy(item => item.Key)
            .Select(item => new PortForwardProfileTombstoneWire(item.Key, item.Value)).ToArray();
        var now = DateTimeOffset.UtcNow.ToUnixTimeSeconds();
        var updated = Math.Max(now, Math.Max(
            profiles.Length == 0 ? 0 : profiles.Max(item => item.UpdatedAtUnix),
            tombstones.Length == 0 ? 0 : tombstones.Max(item => item.DeletedAtUnix)));
        var envelope = new PortForwardProfileSyncEnvelope(
            PortForwardProfileSyncContract.Marker, PortForwardProfileSyncContract.Version,
            updated, profiles, tombstones, metadata?.RemoteId ?? 0, metadata?.VectorClock ?? "{}");
        return (envelope, Fingerprint(profiles, tombstones));
    }

    private static PortForwardProfileRecord ToRecord(PortForwardProfileWire wire, string scope) => new(
        new PortForwardingRule(wire.Id, wire.AssetId, wire.Name, wire.Mode switch
        {
            "local" => PortForwardingMode.Local,
            "remote" => PortForwardingMode.Remote,
            _ => PortForwardingMode.DynamicSocks5,
        }, wire.BindHost, wire.BindPort, wire.DestinationHost, wire.DestinationPort),
        DateTimeOffset.FromUnixTimeSeconds(wire.CreatedAtUnix),
        DateTimeOffset.FromUnixTimeSeconds(wire.UpdatedAtUnix),
        PortForwardProfileSyncScope.EndToEndEncrypted,
        scope);

    private static PortForwardProfileWire ToWire(PortForwardProfileRecord item) => new(
        item.Rule.Id, item.Rule.AssetId, item.Rule.Name, item.Rule.Mode switch
        { PortForwardingMode.Local => "local", PortForwardingMode.Remote => "remote", _ => "dynamicSocks5" },
        item.Rule.BindHost, item.Rule.BindPort, item.Rule.DestinationHost, item.Rule.DestinationPort,
        item.CreatedAt.ToUnixTimeSeconds(), item.UpdatedAt.ToUnixTimeSeconds());

    private static string Fingerprint(IReadOnlyList<PortForwardProfileWire> profiles, IReadOnlyList<PortForwardProfileTombstoneWire> tombstones)
    {
        var bytes = JsonSerializer.SerializeToUtf8Bytes(new
        { profiles = profiles.OrderBy(item => item.Id), tombstones = tombstones.OrderBy(item => item.Id) });
        try { return Convert.ToHexString(SHA256.HashData(bytes)); }
        finally { CryptographicOperations.ZeroMemory(bytes); }
    }
}
