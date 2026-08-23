namespace OrbitTerm.Application.Accounts;

public sealed class NullAccountSessionStore : IAccountSessionStore
{
    public ValueTask<AccountSessionRecord?> ReadAsync(CancellationToken cancellationToken) =>
        ValueTask.FromResult<AccountSessionRecord?>(null);

    public ValueTask SaveAsync(AccountSessionRecord session, CancellationToken cancellationToken) =>
        throw new NotSupportedException("No account session store has been configured.");

    public ValueTask ClearAsync(CancellationToken cancellationToken) => ValueTask.CompletedTask;
}
