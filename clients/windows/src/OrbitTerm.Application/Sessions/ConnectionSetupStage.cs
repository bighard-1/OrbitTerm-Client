namespace OrbitTerm.Application.Sessions;

// Fixed, non-sensitive stages only. Never include endpoints or credential data.
public enum ConnectionSetupStage
{
    CredentialReadStarted,
    CredentialReadCompleted,
    JumpCredentialReadStarted,
    JumpCredentialReadCompleted,
    NativeConnectStarted,
    NativeConnectCompleted,
}
