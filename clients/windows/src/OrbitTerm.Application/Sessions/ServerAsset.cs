namespace OrbitTerm.Application.Sessions;

public sealed record ServerAsset(
    Guid Id,
    Guid CredentialId,
    string Name,
    string Group,
    string Host,
    int Port,
    string Username,
    ServerAuthMethod AuthMethod,
    ServerTransport Transport,
    bool AllowPasswordFallback);

public enum ServerAuthMethod
{
    Password,
    Key,
}

public enum ServerTransport
{
    Ssh,
    Telnet,
}
