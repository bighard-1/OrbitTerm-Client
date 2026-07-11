namespace OrbitTerm.Application.Security;

public sealed record CredentialMaterial(
    string Password,
    string PrivateKey,
    string PrivateKeyPassphrase)
{
    public bool IsEmpty => string.IsNullOrEmpty(Password) && string.IsNullOrEmpty(PrivateKey);
}
