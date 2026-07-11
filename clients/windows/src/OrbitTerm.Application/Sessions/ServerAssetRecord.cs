namespace OrbitTerm.Application.Sessions;

public sealed record ServerAssetRecord(
    Guid Id,
    Guid CredentialId,
    string Name,
    string Host,
    int Port,
    string Username,
    ServerTransport Transport,
    bool AllowPasswordFallback);
