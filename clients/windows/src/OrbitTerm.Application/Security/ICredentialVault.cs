namespace OrbitTerm.Application.Security;

public interface ICredentialVault
{
    ValueTask<CredentialMaterial> ReadAsync(Guid credentialId, CancellationToken cancellationToken);

    ValueTask SaveAsync(Guid credentialId, CredentialMaterial credential, CancellationToken cancellationToken);

    ValueTask DeleteAsync(Guid credentialId, CancellationToken cancellationToken);
}
