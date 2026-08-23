namespace OrbitTerm.NativeBridge;

public sealed record CheckedConnectionRequest(
    string Host,
    int Port,
    string Username,
    string Password,
    string PrivateKey,
    string PrivateKeyPassphrase,
    bool AllowPasswordFallback,
    string KnownHostsPath,
    CheckedJumpHostRequest? JumpHost = null);

public sealed record CheckedJumpHostRequest(
    string Host,
    int Port,
    string Username,
    string Password,
    string PrivateKey,
    string PrivateKeyPassphrase,
    bool AllowPasswordFallback);
