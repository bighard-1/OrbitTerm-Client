namespace OrbitTerm.Application.Sessions;

public abstract record RemoteProcessActionResult
{
    public sealed record Completed(
        VerifiedSessionLease Lease,
        uint ProcessId,
        RemoteProcessAction Action) : RemoteProcessActionResult;

    public sealed record NotFound(uint ProcessId) : RemoteProcessActionResult;

    public sealed record IdentityChanged(uint ProcessId) : RemoteProcessActionResult;

    public sealed record Protected(uint ProcessId) : RemoteProcessActionResult;

    public sealed record PermissionDenied(uint ProcessId) : RemoteProcessActionResult;

    public sealed record Busy : RemoteProcessActionResult;

    public sealed record Failed(string Code, string MessageKey) : RemoteProcessActionResult;
}
