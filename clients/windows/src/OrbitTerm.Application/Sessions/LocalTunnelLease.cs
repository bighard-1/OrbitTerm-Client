namespace OrbitTerm.Application.Sessions;

public sealed record LocalTunnelLease(
    Guid WorkspaceId,
    Guid AssetId,
    ulong BaseSessionId,
    ulong TunnelId,
    string BindHost,
    int BindPort,
    string DestinationHost,
    int DestinationPort);
