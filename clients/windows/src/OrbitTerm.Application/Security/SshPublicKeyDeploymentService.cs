using OrbitTerm.Application.Sessions;

namespace OrbitTerm.Application.Security;

public sealed class SshPublicKeyDeploymentService(
    SessionOrchestrator orchestrator,
    ICredentialVault credentialVault,
    SshKeyLibraryService keyLibrary)
{
    public async ValueTask<SshPublicKeyDeploymentResult> DeployAsync(
        Guid keyId,
        ServerAssetRecord asset,
        string publicKey,
        CancellationToken cancellationToken)
    {
        ArgumentNullException.ThrowIfNull(asset);
        if (asset.Transport != ServerTransport.Ssh)
            return new SshPublicKeyDeploymentResult.Failed("unsupported_transport", "仅 SSH 资产支持公钥部署。", false);

        var normalizedPublicKey = SshPublicKeyDeploymentPolicy.NormalizePublicKey(publicKey);
        var savedCredential = await credentialVault.ReadAsync(asset.CredentialId, cancellationToken).ConfigureAwait(false);
        if (savedCredential.IsEmpty)
            return new SshPublicKeyDeploymentResult.Failed("credential_unavailable", "资产缺少可用的现有凭据，无法登录服务器部署公钥。", false);

        var bootstrapCredential = !string.IsNullOrEmpty(savedCredential.Password)
            ? new CredentialMaterial(savedCredential.Password, string.Empty, string.Empty)
            : savedCredential;
        var serverAsset = ToServerAsset(asset, allowPasswordFallback: !string.IsNullOrEmpty(bootstrapCredential.Password) || asset.AllowPasswordFallback);
        var deploymentWorkspace = Guid.NewGuid();
        var deploymentConnected = false;
        var mayHaveInstalled = false;
        try
        {
            var connect = await orchestrator.ConnectWithCredentialAsync(
                deploymentWorkspace, serverAsset, bootstrapCredential, cancellationToken).ConfigureAwait(false);
            switch (connect)
            {
                case ConnectResult.RequiresHostKeyTrust challenge:
                    return new SshPublicKeyDeploymentResult.RequiresHostKeyTrust(challenge.Challenge);
                case ConnectResult.Blocked:
                    return new SshPublicKeyDeploymentResult.Failed("host_key_blocked", "服务器主机密钥与已保存记录不一致，部署已安全阻止。", false);
                case ConnectResult.Failed failed:
                    return new SshPublicKeyDeploymentResult.Failed(failed.Code, "无法使用资产现有凭据建立安全连接。", false);
                case ConnectResult.Connected:
                    deploymentConnected = true;
                    break;
            }

            var posix = await orchestrator.RunBatchCommandAsync(
                deploymentWorkspace, asset.Id,
                SshPublicKeyDeploymentPolicy.BuildPosixCommand(normalizedPublicKey),
                cancellationToken).ConfigureAwait(false);
            var installed = TryReadDeployment(posix, out var alreadyPresent);
            if (!installed)
            {
                var windows = await orchestrator.RunBatchCommandAsync(
                    deploymentWorkspace, asset.Id,
                    SshPublicKeyDeploymentPolicy.BuildWindowsCommand(normalizedPublicKey),
                    cancellationToken).ConfigureAwait(false);
                installed = TryReadDeployment(windows, out alreadyPresent);
            }
            if (!installed)
                return new SshPublicKeyDeploymentResult.Failed("remote_install_failed", "远端未确认公钥写入，请检查账户主目录和 authorized_keys 权限。", false);
            mayHaveInstalled = true;

            await orchestrator.EndVerifiedSessionAsync(deploymentWorkspace, asset.Id, CancellationToken.None).ConfigureAwait(false);
            deploymentConnected = false;

            var secret = await keyLibrary.ReadSecretAsync(keyId, cancellationToken).ConfigureAwait(false);
            var verificationWorkspace = Guid.NewGuid();
            var verificationConnected = false;
            try
            {
                var verificationCredential = new CredentialMaterial(string.Empty, secret.PrivateKey, secret.Passphrase);
                var verification = await orchestrator.ConnectWithCredentialAsync(
                    verificationWorkspace,
                    ToServerAsset(asset, allowPasswordFallback: false),
                    verificationCredential,
                    cancellationToken).ConfigureAwait(false);
                if (verification is not ConnectResult.Connected)
                    return new SshPublicKeyDeploymentResult.Failed("key_verification_failed", "公钥已写入远端，但新密钥回连验证失败；原凭据未被替换。", true);
                verificationConnected = true;
                await keyLibrary.AssignToAssetAsync(keyId, asset, cancellationToken).ConfigureAwait(false);
                return new SshPublicKeyDeploymentResult.Succeeded(alreadyPresent);
            }
            finally
            {
                if (verificationConnected)
                {
                    try
                    {
                        await orchestrator.EndVerifiedSessionAsync(verificationWorkspace, asset.Id, CancellationToken.None).ConfigureAwait(false);
                    }
                    catch
                    {
                        // Credential assignment has already been committed only after
                        // verification. Cleanup failure must not turn it into a false failure.
                    }
                }
            }
        }
        catch (OperationCanceledException) when (cancellationToken.IsCancellationRequested)
        {
            throw;
        }
        catch (Exception)
        {
            return new SshPublicKeyDeploymentResult.Failed(
                "deployment_failed",
                mayHaveInstalled ? "公钥可能已写入远端，但验证未完成；原凭据未被替换。" : "部署未完成，请检查网络、凭据和服务器权限后重试。",
                mayHaveInstalled);
        }
        finally
        {
            if (deploymentConnected)
            {
                try
                {
                    await orchestrator.EndVerifiedSessionAsync(deploymentWorkspace, asset.Id, CancellationToken.None).ConfigureAwait(false);
                }
                catch
                {
                    // The temporary verified lease is best-effort cleanup. Never
                    // overwrite the more useful deployment result with cleanup noise.
                }
            }
        }
    }

    private static bool TryReadDeployment(BatchExecResult result, out bool alreadyPresent)
    {
        if (result is BatchExecResult.Completed completed)
            return SshPublicKeyDeploymentPolicy.TryReadSuccess(completed.Stdout, completed.Stderr, out alreadyPresent);
        alreadyPresent = false;
        return false;
    }

    private static ServerAsset ToServerAsset(ServerAssetRecord asset, bool allowPasswordFallback) =>
        new(
            asset.Id,
            asset.CredentialId,
            asset.Name,
            asset.Group,
            asset.Host,
            asset.Port,
            asset.Username,
            ServerAuthMethod.Key,
            ServerTransport.Ssh,
            allowPasswordFallback,
            asset.JumpHost is null
                ? null
                : new JumpHostConfiguration(
                    asset.JumpHost.CredentialId,
                    asset.JumpHost.Host,
                    asset.JumpHost.Port,
                    asset.JumpHost.Username,
                    asset.JumpHost.AllowPasswordFallback));
}

public abstract record SshPublicKeyDeploymentResult
{
    private SshPublicKeyDeploymentResult() { }

    public sealed record Succeeded(bool AlreadyPresent) : SshPublicKeyDeploymentResult;
    public sealed record RequiresHostKeyTrust(HostKeyChallengeViewModel Challenge) : SshPublicKeyDeploymentResult;
    public sealed record Failed(string Code, string Message, bool PublicKeyMayHaveBeenInstalled) : SshPublicKeyDeploymentResult;
}
