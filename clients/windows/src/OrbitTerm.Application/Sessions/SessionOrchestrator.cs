using OrbitTerm.Application.Security;
using OrbitTerm.NativeBridge;
using OrbitTerm.Terminal;

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
        if (credential.IsEmpty)
        {
            throw new InvalidOperationException("The selected asset has no usable credential.");
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
            knownHostsPathProvider.GetKnownHostsPath());

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
        CancellationToken cancellationToken)
    {
        cancellationToken.ThrowIfCancellationRequested();
        if (lease.SftpSessionId == 0)
        {
            throw new InvalidOperationException("An active checked SFTP channel is required before downloading.");
        }

        var envelope = coreClient.DownloadSftpFile(
            lease.SftpSessionId,
            remotePath,
            localPath,
            HostKeyRequestId.Create());
        return ValueTask.FromResult(SftpDownloadResult.FromEnvelope(lease, remotePath, envelope));
    }

    public ValueTask<SftpUploadResult> UploadSftpFileAsync(
        SftpSessionLease lease,
        string localPath,
        string remotePath,
        CancellationToken cancellationToken)
    {
        cancellationToken.ThrowIfCancellationRequested();
        if (lease.SftpSessionId == 0)
        {
            throw new InvalidOperationException("An active checked SFTP channel is required before uploading.");
        }

        var envelope = coreClient.UploadSftpFile(
            lease.SftpSessionId,
            localPath,
            remotePath,
            HostKeyRequestId.Create());
        return ValueTask.FromResult(SftpUploadResult.FromEnvelope(lease, remotePath, envelope));
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
        if (!sessionRegistry.TryGet(workspaceId, serverId, out var lease))
        {
            return ValueTask.FromResult(SessionEndResult.NoActiveSession);
        }

        return ValueTask.FromResult(
            sessionRegistry.Remove(lease)
                ? SessionEndResult.Ended
                : SessionEndResult.NoActiveSession);
    }

    public ValueTask<TerminalControlOutcome> WriteTerminalAsync(
        TerminalSessionLease lease,
        ReadOnlyMemory<byte> data,
        CancellationToken cancellationToken)
    {
        cancellationToken.ThrowIfCancellationRequested();
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

        var current = RequireTerminalLease(lease);
        var result = coreClient.ResizeTerminal(current.TerminalChannelId, size.Columns, size.Rows);
        if (result is TerminalControlResult.Succeeded)
        {
            terminalRegistry.UpdateSize(current, size);
        }

        return ValueTask.FromResult(MapTerminalControlResult(result));
    }

    public ValueTask<TerminalControlOutcome> CloseTerminalAsync(
        TerminalSessionLease lease,
        CancellationToken cancellationToken)
    {
        cancellationToken.ThrowIfCancellationRequested();
        var current = RequireTerminalLease(lease);
        var result = coreClient.CloseTerminal(current.TerminalChannelId);
        if (result is TerminalControlResult.Succeeded)
        {
            terminalRegistry.Remove(current);
            lock (terminalBacklogGate)
            {
                terminalBacklogs.Remove(current.TerminalChannelId);
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

        string snapshot;
        lock (terminalBacklogGate)
        {
            if (!terminalBacklogs.TryGetValue(e.TerminalChannelId, out var backlog))
            {
                backlog = new TerminalBacklog();
                terminalBacklogs[e.TerminalChannelId] = backlog;
            }

            backlog.Append(e.Data);
            snapshot = backlog.Snapshot();
        }

        var text = System.Text.Encoding.UTF8.GetString(e.Data);
        TerminalOutputReceived?.Invoke(
            this,
            new TerminalOutputReceivedEventArgs(lease, text, snapshot));
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
}
