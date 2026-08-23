namespace OrbitTerm.Presentation;

public sealed record BulkAssetImportItem(
    string Name,
    string Group,
    string Host,
    int Port,
    string Username,
    string Password,
    string PrivateKey,
    string PrivateKeyPassphrase,
    IReadOnlyList<string> Tags);
