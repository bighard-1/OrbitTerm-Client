using OrbitTerm.Application.Sessions;

namespace OrbitTerm.Presentation;

public sealed record AssetViewModel(
    Guid Id,
    Guid CredentialId,
    string Name,
    string Host,
    int Port,
    string Username,
    ServerTransport Transport,
    bool AllowPasswordFallback,
    string Group,
    IReadOnlyList<string> Tags,
    JumpHostRecord? JumpHost = null,
    AssetStorageScope StorageScope = AssetStorageScope.AccountSynced,
    string? OwnerAccountScope = null)
{
    public AssetViewModel(
        Guid id,
        Guid credentialId,
        string name,
        string host,
        int port,
        string username,
        ServerTransport transport,
        bool allowPasswordFallback)
        : this(id, credentialId, name, host, port, username, transport, allowPasswordFallback, "未分组", [])
    {
    }

    public string Endpoint => string.Concat(Host, ":", Port);

    public string TagsDisplay => Tags.Count == 0 ? "未设置标签" : string.Join(" · ", Tags);

    public string StorageScopeDisplay => StorageScope == AssetStorageScope.LocalOnly
        ? "仅此设备"
        : string.IsNullOrWhiteSpace(OwnerAccountScope) ? "随账户同步 · 待认领" : "随账户同步";

    public string TransportLabel => Transport switch
    {
        ServerTransport.Ssh => "SSH",
        ServerTransport.Telnet => "TELNET",
        ServerTransport.RemoteDesktop => "RDP",
        _ => Transport.ToString().ToUpperInvariant(),
    };

    public static AssetViewModel FromRecord(ServerAssetRecord record)
    {
        return new AssetViewModel(
            record.Id,
            record.CredentialId,
            record.Name,
            record.Host,
            record.Port,
            record.Username,
            record.Transport,
            record.AllowPasswordFallback,
            record.Group,
            record.Tags ?? [],
            record.JumpHost,
            record.StorageScope,
            record.OwnerAccountScope);
    }

    public ServerAssetRecord ToRecord()
    {
        return new ServerAssetRecord(
            Id,
            CredentialId,
            Name,
            Host,
            Port,
            Username,
            Transport,
            AllowPasswordFallback,
            Group,
            Tags,
            JumpHost,
            StorageScope,
            OwnerAccountScope);
    }
}
