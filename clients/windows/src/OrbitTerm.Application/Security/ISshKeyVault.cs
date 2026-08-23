namespace OrbitTerm.Application.Security;

public interface ISshKeyVault
{
    ValueTask<IReadOnlyList<SshKeyRecord>> ListAsync(CancellationToken cancellationToken);

    ValueTask<SshKeyVaultEntry?> ReadAsync(Guid keyId, CancellationToken cancellationToken);

    ValueTask SaveAsync(SshKeyVaultEntry entry, CancellationToken cancellationToken);

    ValueTask DeleteAsync(Guid keyId, CancellationToken cancellationToken);
}
