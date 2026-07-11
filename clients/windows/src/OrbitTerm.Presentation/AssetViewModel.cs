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
    bool AllowPasswordFallback)
{
    public string Endpoint => string.Concat(Host, ":", Port);

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
            record.AllowPasswordFallback);
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
            AllowPasswordFallback);
    }
}
