using OrbitTerm.Application.Security;
using OrbitTerm.NativeBridge;
using OrbitTerm.Terminal;
using System.Collections.Concurrent;
using System.Net.Sockets;

namespace OrbitTerm.Application.Sessions;

public sealed class SessionOrchestrator
{
    private readonly ICheckedOrbitCoreClient coreClient;
    private readonly ICredentialVault credentialVault;
    private readonly IKnownHostsPathProvider knownHostsPathProvider;
    private readonly VerifiedSessionRegistry sessionRegistry;
    private readonly TerminalSessionRegistry terminalRegistry;
    private readonly object terminalBacklogGate = new();
    private readonly Dictionary<ulong, TerminalBacklog> terminalBacklogs = [];
    private readonly Dictionary<ulong, TerminalScreen> terminalScreens = [];
    private readonly ConcurrentDictionary<ulong, TelnetConnectionSession> telnetSessions = new();
    private long telnetChannelSeed = long.MaxValue;

    public SessionOrchestrator(
        ICheckedOrbitCoreClient coreClient,
        ICredentialVault credentialVault,
        IKnownHostsPathProvider knownHostsPathProvider,
        VerifiedSessionRegistry? sessionRegistry = null,
        TerminalSessionRegistry? terminalRegistry = null)
    {
        this.coreClient = coreClient;
        this.credentialVault = credentialVault;
        this.knownHostsPathProvider = knownHostsPathProvider;
        this.sessionRegistry = sessionRegistry ?? new VerifiedSessionRegistry();
        this.terminalRegistry = terminalRegistry ?? new TerminalSessionRegistry();
        this.coreClient.TerminalDataReceived += OnTerminalDataReceived;
    }

    public event EventHandler<TerminalOutputReceivedEventArgs>? TerminalOutputReceived;

    public async ValueTask<TerminalOpenResult> ConnectTelnetAsync(
        Guid workspaceId,
        ServerAsset asset,
        TerminalSize size,
        CancellationToken cancellationToken)
    {
        if (asset.Transport != ServerTransport.Telnet)
        {
            throw new ArgumentException("A Telnet asset is required.", nameof(asset));
        }
        if (asset.JumpHost is not null)
        {
            return new TerminalOpenResult.Failed("telnet_jump_host_unsupported", "Telnet 不支持跳板机连接。");
        }

        var credential = await credentialVault.ReadAsync(asset.CredentialId, cancellationToken).ConfigureAwait(false);
        if (string.IsNullOrEmpty(credential.Password))
        {
            return new TerminalOpenResult.Failed("telnet_password_required", "Telnet 自动登录需要密码凭据。");
        }

        var channelId = unchecked((ulong)Interlocked.Decrement(ref telnetChannelSeed));
        var lease = new TerminalSessionLease(
            workspaceId,
            asset.Id,
            channelId,
            channelId,
            size,
            asset.Host,
            asset.Port,
            "telnet-insecure",
            "unverified");
        var session = new TelnetConnectionSession(lease, asset.Username, credential.Password);
        session.DataReceived += data => PublishTerminalData(session.Lease, data.Span);
        terminalRegistry.Register(lease);
        lock (terminalBacklogGate)
        {
            terminalBacklogs[channelId] = new TerminalBacklog();
            terminalScreens[channelId] = new TerminalScreen(size);
        }
        try
        {
            await session.ConnectAsync(cancellationToken).ConfigureAwait(false);
            telnetSessions[channelId] = session;
            return new TerminalOpenResult.Opened(lease);
        }
        catch (OperationCanceledException) when (cancellationToken.IsCancellationRequested)
        {
            await session.DisposeAsync().ConfigureAwait(false);
            RemoveTelnetPresentationState(lease);
            throw;
        }
        catch (Exception exception) when (exception is SocketException or IOException or OperationCanceledException)
        {
            await session.DisposeAsync().ConfigureAwait(false);
            RemoveTelnetPresentationState(lease);
            return new TerminalOpenResult.Failed("telnet_connect_failed", "无法建立 Telnet 连接，请检查地址、端口和网络。");
        }
    }

    public async ValueTask CloseAllTelnetSessionsAsync(CancellationToken cancellationToken)
    {
        foreach (var lease in telnetSessions.Values.Select(session => session.Lease).ToArray())
        {
            cancellationToken.ThrowIfCancellationRequested();
            await CloseTelnetTerminalAsync(lease, cancellationToken).ConfigureAwait(false);
        }
    }

    public async ValueTask<ConnectResult> ConnectAsync(
        Guid workspaceId,
        ServerAsset asset,
        CancellationToken cancellationToken)
    {
        if (asset.Transport != ServerTransport.Ssh)
        {
            throw new NotSupportedException("Only SSH can enter the checked session flow.");
        }

        var credential = await credentialVault.ReadAsync(asset.CredentialId, cancellationToken).ConfigureAwait(false);
        credential = CredentialMaterialPolicy.NormalizeSshCredential(credential);
        if (credential.IsEmpty)
        {
            throw new InvalidOperationException("The selected asset has no usable credential.");
        }

        return await ConnectWithCredentialAsync(
            workspaceId,
            asset,
            credential,
            cancellationToken).ConfigureAwait(false);
    }

    /// <summary>
    /// Establishes a checked SSH session with foreground-only credential material.
    /// This is reserved for security workflows such as verifying a newly deployed
    /// public key before replacing the asset's persisted credential.
    /// </summary>
    public async ValueTask<ConnectResult> ConnectWithCredentialAsync(
        Guid workspaceId,
        ServerAsset asset,
        CredentialMaterial credential,
        CancellationToken cancellationToken)
    {
        if (asset.Transport != ServerTransport.Ssh)
        {
            throw new NotSupportedException("Only SSH can enter the checked session flow.");
        }
        ArgumentNullException.ThrowIfNull(credential);
        credential = CredentialMaterialPolicy.NormalizeSshCredential(credential);
        if (credential.IsEmpty)
        {
            throw new InvalidOperationException("The selected asset has no usable credential.");
        }

        CheckedJumpHostRequest? jumpRequest = null;
        if (asset.JumpHost is { } jump)
        {
            var jumpCredential = await credentialVault.ReadAsync(jump.CredentialId, cancellationToken).ConfigureAwait(false);
            jumpCredential = CredentialMaterialPolicy.NormalizeSshCredential(jumpCredential);
            if (jumpCredential.IsEmpty)
            {
                throw new InvalidOperationException("The configured jump host has no usable credential.");
            }
            jumpRequest = new CheckedJumpHostRequest(
                jump.Host, jump.Port, jump.Username, jumpCredential.Password,
                jumpCredential.PrivateKey, jumpCredential.PrivateKeyPassphrase,
                jump.AllowPasswordFallback);
        }

        var requestId = HostKeyRequestId.Create();
        var request = new CheckedConnectionRequest(
            asset.Host,
            asset.Port,
            asset.Username,
            credential.Password,
            credential.PrivateKey,
            credential.PrivateKeyPassphrase,
            asset.AllowPasswordFallback,
            knownHostsPathProvider.GetKnownHostsPath(),
            jumpRequest);

        var outcome = coreClient.Connect(request, requestId);
        var result = ConnectResult.FromNative(workspaceId, asset.Id, outcome);
        if (result is ConnectResult.Connected connected)
        {
            sessionRegistry.Register(connected.Lease);
        }

        return result;
    }

    public ValueTask<TerminalOpenResult> OpenTerminalAsync(
        Guid workspaceId,
        Guid serverId,
        TerminalSize size,
        CancellationToken cancellationToken)
    {
        cancellationToken.ThrowIfCancellationRequested();
        size.Validate();

        if (!sessionRegistry.TryGet(workspaceId, serverId, out var lease))
        {
            throw new InvalidOperationException("A verified SSH session is required before opening a terminal.");
        }

        var outcome = coreClient.OpenTerminal(
            lease.BaseSessionId,
            size.Columns,
            size.Rows,
            HostKeyRequestId.Create());

        var result = TerminalOpenResult.FromNative(lease, size, outcome);
        if (result is TerminalOpenResult.Opened opened)
        {
            terminalRegistry.Register(opened.Lease);
            lock (terminalBacklogGate)
            {
                terminalBacklogs[opened.Lease.TerminalChannelId] = new TerminalBacklog();
                terminalScreens[opened.Lease.TerminalChannelId] = new TerminalScreen(opened.Lease.Size);
            }
        }

        return ValueTask.FromResult(result);
    }

    public ValueTask<SftpOpenResult> OpenSftpAsync(
        Guid workspaceId,
        Guid serverId,
        CancellationToken cancellationToken)
    {
        cancellationToken.ThrowIfCancellationRequested();
        if (!sessionRegistry.TryGet(workspaceId, serverId, out var lease))
        {
            throw new InvalidOperationException("A verified SSH session is required before opening SFTP.");
        }

        var envelope = coreClient.OpenSftp(lease.BaseSessionId, HostKeyRequestId.Create());
        return ValueTask.FromResult(SftpOpenResult.FromEnvelope(lease, envelope));
    }

    public ValueTask<LocalTunnelLease> StartLocalTunnelAsync(
        Guid workspaceId,
        Guid serverId,
        string destinationHost,
        int destinationPort,
        int preferredLocalPort,
        CancellationToken cancellationToken)
    {
        cancellationToken.ThrowIfCancellationRequested();
        if (!sessionRegistry.TryGet(workspaceId, serverId, out var lease))
            throw new InvalidOperationException("端口映射需要当前资产的已验证 SSH 会话。");
        var requestId = HostKeyRequestId.Create();
        var envelope = coreClient.StartLocalTunnel(
            lease.BaseSessionId, "127.0.0.1", preferredLocalPort,
            destinationHost, destinationPort, requestId);
        var payload = CheckedEnvelopeDecoder.DecodePayload<LocalTunnelStartedPayload>(
            envelope, "local_tunnel_started");
        if (payload.ParsedBaseSessionId != lease.BaseSessionId || payload.ParsedTunnelId == 0)
            throw new OrbitNativeException("Local tunnel response did not match the verified session.");
        return ValueTask.FromResult(new LocalTunnelLease(
            workspaceId, serverId, lease.BaseSessionId, payload.ParsedTunnelId,
            payload.BindHost, payload.BindPort, destinationHost, destinationPort));
    }

    public ValueTask StopLocalTunnelAsync(LocalTunnelLease lease, CancellationToken cancellationToken)
    {
        cancellationToken.ThrowIfCancellationRequested();
        var requestId = HostKeyRequestId.Create();
        var envelope = coreClient.StopLocalTunnel(lease.TunnelId, requestId);
        var payload = CheckedEnvelopeDecoder.DecodePayload<LocalTunnelStoppedPayload>(
            envelope, "local_tunnel_stopped");
        if (payload.ParsedTunnelId != lease.TunnelId)
            throw new OrbitNativeException("Stopped tunnel response did not match the request.");
        return ValueTask.CompletedTask;
    }

    public ValueTask<MonitorSnapshotResult> CaptureMonitorSnapshotAsync(
        Guid workspaceId,
        Guid serverId,
        CancellationToken cancellationToken)
    {
        cancellationToken.ThrowIfCancellationRequested();
        if (!sessionRegistry.TryGet(workspaceId, serverId, out var lease))
        {
            throw new InvalidOperationException("A verified SSH session is required before capturing a monitor snapshot.");
        }

        var envelope = coreClient.MonitorSnapshot(lease.BaseSessionId, HostKeyRequestId.Create());
        return ValueTask.FromResult(MonitorSnapshotResult.FromEnvelope(lease, envelope));
    }

    public ValueTask<DockerContainersResult> ListDockerContainersAsync(
        Guid workspaceId,
        Guid serverId,
        CancellationToken cancellationToken)
    {
        cancellationToken.ThrowIfCancellationRequested();
        if (!sessionRegistry.TryGet(workspaceId, serverId, out var lease))
        {
            throw new InvalidOperationException("A verified SSH session is required before listing Docker containers.");
        }

        var envelope = coreClient.DockerList(lease.BaseSessionId, HostKeyRequestId.Create());
        return ValueTask.FromResult(DockerContainersResult.FromEnvelope(lease, envelope));
    }

    public ValueTask<DockerStatsResult> CaptureDockerStatsAsync(
        Guid workspaceId,
        Guid serverId,
        CancellationToken cancellationToken)
    {
        cancellationToken.ThrowIfCancellationRequested();
        if (!sessionRegistry.TryGet(workspaceId, serverId, out var lease))
        {
            throw new InvalidOperationException("A verified SSH session is required before capturing Docker stats.");
        }

        var envelope = coreClient.DockerStats(lease.BaseSessionId, HostKeyRequestId.Create());
        return ValueTask.FromResult(DockerStatsResult.FromEnvelope(lease, envelope));
    }

    public ValueTask<DockerLogsResult> CaptureDockerLogsAsync(
        Guid workspaceId,
        Guid serverId,
        string containerId,
        uint tailLines,
        CancellationToken cancellationToken)
    {
        cancellationToken.ThrowIfCancellationRequested();
        if (!sessionRegistry.TryGet(workspaceId, serverId, out var lease))
        {
            throw new InvalidOperationException("A verified SSH session is required before capturing Docker logs.");
        }

        var envelope = coreClient.DockerLogs(lease.BaseSessionId, containerId, tailLines, HostKeyRequestId.Create());
        return ValueTask.FromResult(DockerLogsResult.FromEnvelope(lease, containerId, envelope));
    }

    public ValueTask<DockerActionResult> RunDockerActionAsync(
        Guid workspaceId,
        Guid serverId,
        string containerId,
        string action,
        CancellationToken cancellationToken)
    {
        cancellationToken.ThrowIfCancellationRequested();
        if (!sessionRegistry.TryGet(workspaceId, serverId, out var lease))
        {
            throw new InvalidOperationException("A verified SSH session is required before running a Docker action.");
        }

        var envelope = coreClient.DockerAction(lease.BaseSessionId, containerId, action, HostKeyRequestId.Create());
        return ValueTask.FromResult(DockerActionResult.FromEnvelope(lease, containerId, action, envelope));
    }

    public ValueTask<BatchExecResult> RunBatchCommandAsync(
        Guid workspaceId,
        Guid serverId,
        string command,
        CancellationToken cancellationToken)
    {
        cancellationToken.ThrowIfCancellationRequested();
        if (!sessionRegistry.TryGet(workspaceId, serverId, out var lease))
        {
            throw new InvalidOperationException("A verified SSH session is required before running a batch command.");
        }

        var envelope = coreClient.Exec(lease.BaseSessionId, command, HostKeyRequestId.Create());
        return ValueTask.FromResult(BatchExecResult.FromEnvelope(lease, envelope));
    }

    public ValueTask<RemoteProcessActionResult> RunRemoteProcessActionAsync(
        Guid workspaceId,
        Guid serverId,
        uint processId,
        long startIdentity,
        RemoteProcessAction action,
        CancellationToken cancellationToken)
    {
        cancellationToken.ThrowIfCancellationRequested();
        if (!sessionRegistry.TryGet(workspaceId, serverId, out var lease))
        {
            throw new InvalidOperationException("A verified SSH session is required before managing a process.");
        }
        if (processId <= 1)
        {
            return ValueTask.FromResult<RemoteProcessActionResult>(
                new RemoteProcessActionResult.Protected(processId));
        }

        string command;
        try
        {
            command = RemoteProcessActionPolicy.BuildCommand(processId, startIdentity, action);
        }
        catch (ArgumentOutOfRangeException)
        {
            return ValueTask.FromResult<RemoteProcessActionResult>(
                new RemoteProcessActionResult.Failed(
                    "process_action_invalid_request",
                    "error.process.action.invalid_request"));
        }

        var envelope = coreClient.Exec(lease.BaseSessionId, command, HostKeyRequestId.Create());
        var batchResult = BatchExecResult.FromEnvelope(lease, envelope);
        return ValueTask.FromResult(RemoteProcessActionPolicy.Parse(
            lease,
            processId,
            action,
            batchResult));
    }

    public ValueTask<SftpDirectoryListResult> ListSftpDirectoryAsync(
        SftpSessionLease lease,
        string remotePath,
        CancellationToken cancellationToken)
    {
        cancellationToken.ThrowIfCancellationRequested();
        if (lease.SftpSessionId == 0)
        {
            throw new InvalidOperationException("An active checked SFTP channel is required before listing.");
        }

        var envelope = coreClient.ListSftpDirectory(
            lease.SftpSessionId,
            remotePath,
            HostKeyRequestId.Create());
        return ValueTask.FromResult(SftpDirectoryListResult.FromEnvelope(lease, remotePath, envelope));
    }

    public ValueTask<SftpTextPreviewResult> ReadSftpTextFileAsync(
        SftpSessionLease lease,
        string remotePath,
        CancellationToken cancellationToken)
    {
        cancellationToken.ThrowIfCancellationRequested();
        if (lease.SftpSessionId == 0)
        {
            throw new InvalidOperationException("An active checked SFTP channel is required before reading a text file.");
        }

        var envelope = coreClient.ReadSftpTextFile(
            lease.SftpSessionId,
            remotePath,
            HostKeyRequestId.Create());
        return ValueTask.FromResult(SftpTextPreviewResult.FromEnvelope(lease, remotePath, envelope));
    }

    public ValueTask<SftpDownloadResult> DownloadSftpFileAsync(
        SftpSessionLease lease,
        string remotePath,
        string localPath,
        CancellationToken cancellationToken,
        IProgress<SftpTransferProgress>? progress = null,
        SftpTransferControl? control = null)
    {
        cancellationToken.ThrowIfCancellationRequested();
        if (lease.SftpSessionId == 0)
        {
            throw new InvalidOperationException("An active checked SFTP channel is required before downloading.");
        }

        var requestId = HostKeyRequestId.Create();
        var progressThrottle = new SftpTransferProgressThrottle();
        using var cancellationRegistration = cancellationToken.Register(
            static state =>
            {
                var cancellation = (SftpCancellationRequest)state!;
                cancellation.CoreClient.CancelSftpTransfer(cancellation.RequestId);
            },
            new SftpCancellationRequest(coreClient, requestId));
        EventHandler<SftpTransferProgressEventArgs>? progressHandler = progress is null && control is null
            ? null
            : (_, args) =>
            {
                if (string.Equals(args.RequestId, requestId.Value, StringComparison.Ordinal))
                {
                    if (control?.WaitWhilePaused(cancellationToken) == false)
                    {
                        return;
                    }
                    if (progress is not null && progressThrottle.ShouldReport(args.TransferredBytes, args.TotalBytes))
                    {
                        progress.Report(new SftpTransferProgress(args.TransferredBytes, args.TotalBytes));
                    }
                }
            };
        if (progressHandler is not null)
        {
            coreClient.SftpTransferProgress += progressHandler;
        }
        try
        {
            var envelope = coreClient.DownloadSftpFile(
                lease.SftpSessionId,
                remotePath,
                localPath,
                requestId);
            return ValueTask.FromResult(SftpDownloadResult.FromEnvelope(lease, remotePath, envelope));
        }
        finally
        {
            if (progressHandler is not null)
            {
                coreClient.SftpTransferProgress -= progressHandler;
            }
        }
    }

    public ValueTask<SftpUploadResult> UploadSftpFileAsync(
        SftpSessionLease lease,
        string localPath,
        string remotePath,
        CancellationToken cancellationToken,
        IProgress<SftpTransferProgress>? progress = null,
        SftpTransferControl? control = null)
    {
        cancellationToken.ThrowIfCancellationRequested();
        if (lease.SftpSessionId == 0)
        {
            throw new InvalidOperationException("An active checked SFTP channel is required before uploading.");
        }

        var requestId = HostKeyRequestId.Create();
        var progressThrottle = new SftpTransferProgressThrottle();
        using var cancellationRegistration = cancellationToken.Register(
            static state =>
            {
                var cancellation = (SftpCancellationRequest)state!;
                cancellation.CoreClient.CancelSftpTransfer(cancellation.RequestId);
            },
            new SftpCancellationRequest(coreClient, requestId));
        EventHandler<SftpTransferProgressEventArgs>? progressHandler = progress is null && control is null
            ? null
            : (_, args) =>
            {
                if (string.Equals(args.RequestId, requestId.Value, StringComparison.Ordinal))
                {
                    if (control?.WaitWhilePaused(cancellationToken) == false)
                    {
                        return;
                    }
                    if (progress is not null && progressThrottle.ShouldReport(args.TransferredBytes, args.TotalBytes))
                    {
                        progress.Report(new SftpTransferProgress(args.TransferredBytes, args.TotalBytes));
                    }
                }
            };
        if (progressHandler is not null)
        {
            coreClient.SftpTransferProgress += progressHandler;
        }
        try
        {
            var envelope = coreClient.UploadSftpFile(
                lease.SftpSessionId,
                localPath,
                remotePath,
                requestId);
            return ValueTask.FromResult(SftpUploadResult.FromEnvelope(lease, remotePath, envelope));
        }
        finally
        {
            if (progressHandler is not null)
            {
                coreClient.SftpTransferProgress -= progressHandler;
            }
        }
    }

    public ValueTask<SftpMutationResult> CreateSftpDirectoryAsync(
        SftpSessionLease lease,
        string remotePath,
        CancellationToken cancellationToken)
    {
        EnsureSftpMutationLease(lease, cancellationToken);
        var envelope = coreClient.CreateSftpDirectory(
            lease.SftpSessionId,
            remotePath,
            HostKeyRequestId.Create());
        return ValueTask.FromResult(SftpMutationResult.FromEnvelope(
            lease,
            SftpMutationOperations.MakeDirectory,
            remotePath,
            null,
            envelope));
    }

    public ValueTask<SftpMutationResult> CreateSftpFileAsync(
        SftpSessionLease lease,
        string remotePath,
        CancellationToken cancellationToken)
    {
        EnsureSftpMutationLease(lease, cancellationToken);
        var envelope = coreClient.CreateSftpFile(
            lease.SftpSessionId,
            remotePath,
            HostKeyRequestId.Create());
        return ValueTask.FromResult(SftpMutationResult.FromEnvelope(
            lease,
            SftpMutationOperations.CreateFile,
            remotePath,
            null,
            envelope));
    }

    public ValueTask<SftpMutationResult> RenameSftpEntryAsync(
        SftpSessionLease lease,
        string oldRemotePath,
        string newRemotePath,
        SftpMutationSnapshot snapshot,
        CancellationToken cancellationToken)
    {
        EnsureSftpMutationLease(lease, cancellationToken);
        var envelope = coreClient.RenameSftpEntry(
            lease.SftpSessionId,
            oldRemotePath,
            newRemotePath,
            ToNativeSnapshot(snapshot),
            HostKeyRequestId.Create());
        return ValueTask.FromResult(SftpMutationResult.FromEnvelope(
            lease,
            SftpMutationOperations.Rename,
            oldRemotePath,
            newRemotePath,
            envelope));
    }

    public ValueTask<SftpMutationResult> RemoveSftpEntryAsync(
        SftpSessionLease lease,
        string remotePath,
        SftpMutationSnapshot snapshot,
        CancellationToken cancellationToken)
    {
        EnsureSftpMutationLease(lease, cancellationToken);
        var envelope = coreClient.RemoveSftpEntry(
            lease.SftpSessionId,
            remotePath,
            ToNativeSnapshot(snapshot),
            HostKeyRequestId.Create());
        return ValueTask.FromResult(SftpMutationResult.FromEnvelope(
            lease,
            SftpMutationOperations.Remove,
            remotePath,
            null,
            envelope));
    }

    public ValueTask<SftpMutationResult> ChangeSftpPermissionsAsync(
        SftpSessionLease lease,
        string remotePath,
        uint mode,
        SftpMutationSnapshot snapshot,
        CancellationToken cancellationToken)
    {
        EnsureSftpMutationLease(lease, cancellationToken);
        var envelope = coreClient.ChangeSftpPermissions(
            lease.SftpSessionId,
            remotePath,
            mode,
            ToNativeSnapshot(snapshot),
            HostKeyRequestId.Create());
        return ValueTask.FromResult(SftpMutationResult.FromEnvelope(
            lease,
            SftpMutationOperations.ChangePermissions,
            remotePath,
            null,
            envelope));
    }

    public ValueTask<SftpMutationResult> WriteSftpTextFileAsync(
        SftpSessionLease lease,
        string remotePath,
        string content,
        SftpMutationSnapshot snapshot,
        CancellationToken cancellationToken)
    {
        EnsureSftpMutationLease(lease, cancellationToken);
        var envelope = coreClient.WriteSftpTextFile(
            lease.SftpSessionId,
            remotePath,
            content,
            ToNativeSnapshot(snapshot),
            HostKeyRequestId.Create());
        return ValueTask.FromResult(SftpMutationResult.FromEnvelope(
            lease,
            SftpMutationOperations.WriteText,
            remotePath,
            null,
            envelope));
    }

    private static void EnsureSftpMutationLease(
        SftpSessionLease lease,
        CancellationToken cancellationToken)
    {
        cancellationToken.ThrowIfCancellationRequested();
        if (lease.SftpSessionId == 0)
        {
            throw new InvalidOperationException("An active checked SFTP channel is required before changing remote entries.");
        }
    }

    private static SftpEntrySnapshot ToNativeSnapshot(SftpMutationSnapshot snapshot)
    {
        return new SftpEntrySnapshot(
            snapshot.Size,
            snapshot.PermissionsOctal,
            snapshot.ModifiedAtUnix,
            snapshot.IsDirectory);
    }

    public ValueTask<HostKeyTrustResult> TrustHostKeyAsync(
        HostKeyChallengeViewModel challenge,
        string comment,
        CancellationToken cancellationToken)
    {
        cancellationToken.ThrowIfCancellationRequested();

        if (!challenge.CanTrust ||
            string.IsNullOrWhiteSpace(challenge.ChallengeId) ||
            string.IsNullOrWhiteSpace(challenge.RequestId))
        {
            throw new InvalidOperationException("Only an active trustable Host Key challenge can be persisted.");
        }

        var outcome = coreClient.AcceptAndPersistHostKey(
            challenge.ChallengeId,
            knownHostsPathProvider.GetKnownHostsPath(),
            comment,
            new HostKeyRequestId(challenge.RequestId));

        return ValueTask.FromResult(MapHostKeyTrustResult(challenge, outcome));
    }

    public ValueTask<SessionEndResult> EndVerifiedSessionAsync(
        Guid workspaceId,
        Guid serverId,
        CancellationToken cancellationToken)
    {
        cancellationToken.ThrowIfCancellationRequested();
        var telnet = telnetSessions.Values.FirstOrDefault(candidate =>
            candidate.Lease.WorkspaceId == workspaceId && candidate.Lease.ServerId == serverId);
        if (telnet is not null)
        {
            return CloseTelnetSessionAsync(telnet.Lease, cancellationToken);
        }
        if (!sessionRegistry.TryGet(workspaceId, serverId, out var lease))
        {
            return ValueTask.FromResult(SessionEndResult.NoActiveSession);
        }

        return ValueTask.FromResult(
            sessionRegistry.Remove(lease)
                ? SessionEndResult.Ended
                : SessionEndResult.NoActiveSession);
    }

    /// <summary>
    /// Drops local leases after the transport has already disappeared. This is
    /// intentionally not a graceful disconnect and performs no remote action.
    /// It prevents stale connected badges and monitor data after host reboot.
    /// </summary>
    public void AbandonSession(Guid workspaceId, Guid serverId)
    {
        foreach (var terminal in terminalRegistry.RemoveAll(workspaceId, serverId))
        {
            lock (terminalBacklogGate)
            {
                terminalBacklogs.Remove(terminal.TerminalChannelId);
                terminalScreens.Remove(terminal.TerminalChannelId);
            }
            if (telnetSessions.TryRemove(terminal.TerminalChannelId, out var telnet))
            {
                _ = telnet.DisposeAsync();
            }
        }

        if (sessionRegistry.TryGet(workspaceId, serverId, out var session))
        {
            sessionRegistry.Remove(session);
        }
    }

    public ValueTask<TerminalControlOutcome> WriteTerminalAsync(
        TerminalSessionLease lease,
        ReadOnlyMemory<byte> data,
        CancellationToken cancellationToken)
    {
        cancellationToken.ThrowIfCancellationRequested();
        if (telnetSessions.TryGetValue(lease.TerminalChannelId, out var telnet))
        {
            return WriteTelnetAsync(telnet, data, cancellationToken);
        }
        var current = RequireTerminalLease(lease);
        var result = coreClient.WriteTerminal(current.TerminalChannelId, data);
        return ValueTask.FromResult(MapTerminalControlResult(result));
    }

    public ValueTask<TerminalControlOutcome> ResizeTerminalAsync(
        TerminalSessionLease lease,
        TerminalSize size,
        CancellationToken cancellationToken)
    {
        cancellationToken.ThrowIfCancellationRequested();
        size.Validate();

        if (telnetSessions.TryGetValue(lease.TerminalChannelId, out var telnet))
        {
            return ResizeTelnetAsync(telnet, size, cancellationToken);
        }

        var current = RequireTerminalLease(lease);
        var result = coreClient.ResizeTerminal(current.TerminalChannelId, size.Columns, size.Rows);
        if (result is TerminalControlResult.Succeeded)
        {
            terminalRegistry.UpdateSize(current, size);
            lock (terminalBacklogGate)
            {
                RebuildTerminalScreenForSize(current.TerminalChannelId, size);
            }
        }

        return ValueTask.FromResult(MapTerminalControlResult(result));
    }

    public TerminalScreenSnapshot ClearTerminalPresentation(TerminalSessionLease lease)
    {
        var current = RequireTerminalLease(lease);
        lock (terminalBacklogGate)
        {
            if (!terminalScreens.TryGetValue(current.TerminalChannelId, out var screen))
            {
                throw new InvalidOperationException("The terminal screen is not active.");
            }

            terminalBacklogs.GetValueOrDefault(current.TerminalChannelId)?.Clear();
            return screen.ClearPresentation();
        }
    }

    public TerminalScreenSnapshot GetTerminalScreenSnapshot(TerminalSessionLease lease)
    {
        var current = RequireTerminalLease(lease);
        lock (terminalBacklogGate)
        {
            if (!terminalScreens.TryGetValue(current.TerminalChannelId, out var screen))
            {
                throw new InvalidOperationException("The terminal screen is not active.");
            }

            return screen.Snapshot();
        }
    }

    public ValueTask<TerminalControlOutcome> CloseTerminalAsync(
        TerminalSessionLease lease,
        CancellationToken cancellationToken)
    {
        cancellationToken.ThrowIfCancellationRequested();
        if (telnetSessions.TryGetValue(lease.TerminalChannelId, out _))
        {
            return CloseTelnetTerminalAsync(lease, cancellationToken);
        }
        var current = RequireTerminalLease(lease);
        var result = coreClient.CloseTerminal(current.TerminalChannelId);
        if (result is TerminalControlResult.Succeeded)
        {
            terminalRegistry.Remove(current);
            lock (terminalBacklogGate)
            {
                terminalBacklogs.Remove(current.TerminalChannelId);
                terminalScreens.Remove(current.TerminalChannelId);
            }
        }

        return ValueTask.FromResult(MapTerminalControlResult(result));
    }

    private TerminalSessionLease RequireTerminalLease(TerminalSessionLease lease)
    {
        if (!terminalRegistry.TryGet(
                lease.WorkspaceId,
                lease.ServerId,
                lease.TerminalChannelId,
                out var current) ||
            current != lease)
        {
            throw new InvalidOperationException("The terminal channel is not active.");
        }

        return current;
    }

    private void OnTerminalDataReceived(object? sender, TerminalDataReceivedEventArgs e)
    {
        if (!terminalRegistry.TryGetByChannelId(e.TerminalChannelId, out var lease))
        {
            return;
        }

        PublishTerminalData(lease, e.Data);
    }

    private void PublishTerminalData(TerminalSessionLease lease, ReadOnlySpan<byte> data)
    {
        string text;
        string snapshot;
        TerminalScreenSnapshot screenSnapshot;
        lock (terminalBacklogGate)
        {
            if (!terminalBacklogs.TryGetValue(lease.TerminalChannelId, out var backlog))
            {
                backlog = new TerminalBacklog();
                terminalBacklogs[lease.TerminalChannelId] = backlog;
            }

            text = backlog.Append(data);
            snapshot = backlog.Snapshot();
            if (!terminalScreens.TryGetValue(lease.TerminalChannelId, out var screen))
            {
                screen = new TerminalScreen(lease.Size);
                terminalScreens[lease.TerminalChannelId] = screen;
            }

            screen.Write(text);
            screenSnapshot = screen.Snapshot();
        }

        // An incomplete multi-byte UTF-8 character is retained by TerminalBacklog
        // until the following callback. Do not publish a replacement character.
        if (text.Length == 0)
        {
            return;
        }

        TerminalOutputReceived?.Invoke(
            this,
            new TerminalOutputReceivedEventArgs(lease, text, snapshot, screenSnapshot));
    }

    private static async ValueTask<TerminalControlOutcome> WriteTelnetAsync(
        TelnetConnectionSession session,
        ReadOnlyMemory<byte> data,
        CancellationToken cancellationToken)
    {
        try
        {
            await session.WriteAsync(data, cancellationToken).ConfigureAwait(false);
            return new TerminalControlOutcome.Succeeded();
        }
        catch (Exception exception) when (exception is IOException or SocketException or InvalidOperationException)
        {
            return new TerminalControlOutcome.Failed("telnet_write_failed", "Telnet 数据未发送，请检查连接状态。");
        }
    }

    private async ValueTask<TerminalControlOutcome> ResizeTelnetAsync(
        TelnetConnectionSession session,
        TerminalSize size,
        CancellationToken cancellationToken)
    {
        try
        {
            await session.ResizeAsync(size, cancellationToken).ConfigureAwait(false);
            terminalRegistry.UpdateSize(session.Lease, size);
            lock (terminalBacklogGate)
            {
                RebuildTerminalScreenForSize(session.Lease.TerminalChannelId, size);
            }
            return new TerminalControlOutcome.Succeeded();
        }
        catch (Exception exception) when (exception is IOException or SocketException or InvalidOperationException)
        {
            return new TerminalControlOutcome.Failed("telnet_resize_failed", "Telnet 终端尺寸未同步。");
        }
    }

    private async ValueTask<TerminalControlOutcome> CloseTelnetTerminalAsync(
        TerminalSessionLease lease,
        CancellationToken cancellationToken)
    {
        cancellationToken.ThrowIfCancellationRequested();
        if (!telnetSessions.TryRemove(lease.TerminalChannelId, out var session))
        {
            return new TerminalControlOutcome.Failed("telnet_session_missing", "Telnet 会话已关闭。");
        }
        await session.DisposeAsync().ConfigureAwait(false);
        RemoveTelnetPresentationState(lease);
        return new TerminalControlOutcome.Succeeded();
    }

    private void RemoveTelnetPresentationState(TerminalSessionLease lease)
    {
        terminalRegistry.Remove(lease);
        lock (terminalBacklogGate)
        {
            terminalBacklogs.Remove(lease.TerminalChannelId);
            terminalScreens.Remove(lease.TerminalChannelId);
        }
    }

    private void RebuildTerminalScreenForSize(ulong terminalChannelId, TerminalSize size)
    {
        if (terminalBacklogs.TryGetValue(terminalChannelId, out var backlog))
        {
            // Replaying the bounded ANSI backlog at the new PTY width gives the
            // terminal a real reflow. Existing output no longer gets cropped by
            // a narrower inspector and expanding it again restores the same data.
            var rebuilt = new TerminalScreen(size);
            rebuilt.Write(backlog.Snapshot());
            terminalScreens[terminalChannelId] = rebuilt;
            return;
        }

        if (terminalScreens.TryGetValue(terminalChannelId, out var screen))
        {
            screen.Resize(size);
        }
    }

    private async ValueTask<SessionEndResult> CloseTelnetSessionAsync(
        TerminalSessionLease lease,
        CancellationToken cancellationToken)
    {
        var result = await CloseTelnetTerminalAsync(lease, cancellationToken).ConfigureAwait(false);
        return result is TerminalControlOutcome.Succeeded ? SessionEndResult.Ended : SessionEndResult.NoActiveSession;
    }

    private static HostKeyTrustResult MapHostKeyTrustResult(
        HostKeyChallengeViewModel challenge,
        CheckedHostKeyTrustOutcome outcome)
    {
        return outcome switch
        {
            CheckedHostKeyTrustOutcome.Persisted persisted => MapPersistedHostKeyTrust(challenge, persisted.Payload),
            CheckedHostKeyTrustOutcome.Failed failed => new HostKeyTrustResult.Failed(
                failed.Error.Code,
                failed.Error.MessageKey),
            _ => throw new InvalidOperationException("Unknown Host Key trust result."),
        };
    }

    private static HostKeyTrustResult.Persisted MapPersistedHostKeyTrust(
        HostKeyChallengeViewModel challenge,
        HostKeyTrustPersistedPayload payload)
    {
        if (!string.Equals(payload.ChallengeId, challenge.ChallengeId, StringComparison.Ordinal) ||
            !string.Equals(payload.FingerprintSha256, challenge.FingerprintSha256, StringComparison.Ordinal) ||
            !string.Equals(payload.KeyAlgorithm, challenge.KeyAlgorithm, StringComparison.Ordinal) ||
            !string.Equals(payload.NormalizedHost, challenge.NormalizedHost, StringComparison.Ordinal) ||
            payload.Port != challenge.Port)
        {
            throw new InvalidOperationException("Persisted Host Key result does not match the active challenge.");
        }

        return new HostKeyTrustResult.Persisted(
            payload.ChallengeId,
            payload.Host,
            payload.NormalizedHost,
            payload.Port,
            payload.KeyAlgorithm,
            payload.FingerprintSha256,
            payload.Status);
    }

    private static TerminalControlOutcome MapTerminalControlResult(TerminalControlResult result)
    {
        return result switch
        {
            TerminalControlResult.Succeeded => new TerminalControlOutcome.Succeeded(),
            TerminalControlResult.Failed => new TerminalControlOutcome.Failed(
                "terminal_control_failed",
                "error.terminal.operation_failed"),
            _ => throw new InvalidOperationException("Unknown terminal control result."),
        };
    }

    private sealed record SftpCancellationRequest(
        ICheckedOrbitCoreClient CoreClient,
        HostKeyRequestId RequestId);
}
