using OrbitTerm.Application.Security;
using OrbitTerm.Application.Sessions;
using OrbitTerm.NativeBridge;
using OrbitTerm.Terminal;
using Xunit;

namespace OrbitTerm.Security.Tests;

public sealed class SessionOrchestratorTests
{
    [Fact]
    public async Task ConnectRegistersVerifiedLeaseAndAllowsTerminalOpen()
    {
        var workspaceId = Guid.NewGuid();
        var serverId = Guid.NewGuid();
        var credentialId = Guid.NewGuid();
        var core = new FakeCheckedCoreClient();
        var orchestrator = new SessionOrchestrator(
            core,
            new FakeCredentialVault(new CredentialMaterial("secret", string.Empty, string.Empty)),
            new FakeKnownHostsPathProvider(),
            new VerifiedSessionRegistry());

        var connected = await orchestrator.ConnectAsync(
            workspaceId,
            CreateAsset(serverId, credentialId),
            CancellationToken.None);
        var terminal = await orchestrator.OpenTerminalAsync(
            workspaceId,
            serverId,
            new TerminalSize(120, 32),
            CancellationToken.None);

        Assert.IsType<ConnectResult.Connected>(connected);
        var opened = Assert.IsType<TerminalOpenResult.Opened>(terminal);
        Assert.Equal(88UL, opened.Lease.TerminalChannelId);
        Assert.Equal(1, core.OpenTerminalCalls);
    }

    [Fact]
    public async Task TerminalWriteResizeAndCloseRequireActiveLease()
    {
        var workspaceId = Guid.NewGuid();
        var serverId = Guid.NewGuid();
        var orchestrator = CreateConnectedOrchestrator(out var core);

        var connected = await orchestrator.ConnectAsync(
            workspaceId,
            CreateAsset(serverId, Guid.NewGuid()),
            CancellationToken.None);
        Assert.IsType<ConnectResult.Connected>(connected);

        var terminal = await orchestrator.OpenTerminalAsync(
            workspaceId,
            serverId,
            TerminalSize.Default,
            CancellationToken.None);
        var lease = Assert.IsType<TerminalOpenResult.Opened>(terminal).Lease;

        var write = await orchestrator.WriteTerminalAsync(
            lease,
            "ls\n"u8.ToArray(),
            CancellationToken.None);
        var resize = await orchestrator.ResizeTerminalAsync(
            lease,
            new TerminalSize(100, 30),
            CancellationToken.None);
        var resizedLease = lease with { Size = new TerminalSize(100, 30) };
        var close = await orchestrator.CloseTerminalAsync(resizedLease, CancellationToken.None);

        Assert.IsType<TerminalControlOutcome.Succeeded>(write);
        Assert.IsType<TerminalControlOutcome.Succeeded>(resize);
        Assert.IsType<TerminalControlOutcome.Succeeded>(close);
        Assert.Equal(1, core.WriteTerminalCalls);
        Assert.Equal(1, core.ResizeTerminalCalls);
        Assert.Equal(1, core.CloseTerminalCalls);

        await Assert.ThrowsAsync<InvalidOperationException>(async () =>
            await orchestrator.WriteTerminalAsync(
                resizedLease,
                "pwd\n"u8.ToArray(),
                CancellationToken.None));
    }

    [Fact]
    public async Task TerminalControlFailureUsesStableUiSafeKeys()
    {
        var workspaceId = Guid.NewGuid();
        var serverId = Guid.NewGuid();
        var orchestrator = CreateConnectedOrchestrator(out var core);
        core.FailWrites = true;

        await orchestrator.ConnectAsync(
            workspaceId,
            CreateAsset(serverId, Guid.NewGuid()),
            CancellationToken.None);
        var terminal = await orchestrator.OpenTerminalAsync(
            workspaceId,
            serverId,
            TerminalSize.Default,
            CancellationToken.None);
        var lease = Assert.IsType<TerminalOpenResult.Opened>(terminal).Lease;

        var result = await orchestrator.WriteTerminalAsync(
            lease,
            "ls\n"u8.ToArray(),
            CancellationToken.None);

        var failed = Assert.IsType<TerminalControlOutcome.Failed>(result);
        Assert.Equal("terminal_control_failed", failed.Code);
        Assert.Equal("error.terminal.operation_failed", failed.MessageKey);
    }

    [Fact]
    public async Task SftpListUsesCheckedSftpLeaseAndMapsEntries()
    {
        var workspaceId = Guid.NewGuid();
        var serverId = Guid.NewGuid();
        var orchestrator = CreateConnectedOrchestrator(out var core);

        await orchestrator.ConnectAsync(
            workspaceId,
            CreateAsset(serverId, Guid.NewGuid()),
            CancellationToken.None);
        var sftp = await orchestrator.OpenSftpAsync(workspaceId, serverId, CancellationToken.None);
        var lease = Assert.IsType<SftpOpenResult.Opened>(sftp).Lease;

        var result = await orchestrator.ListSftpDirectoryAsync(
            lease,
            "/var/log",
            CancellationToken.None);

        var listed = Assert.IsType<SftpDirectoryListResult.Listed>(result);
        Assert.Equal(55UL, lease.SftpSessionId);
        Assert.Equal("/var/log", listed.Path);
        Assert.Single(listed.Entries);
        Assert.Equal("syslog", listed.Entries[0].Name);
        Assert.Equal(1, core.ListSftpDirectoryCalls);
        Assert.Equal(55UL, core.LastSftpListSessionId);
        Assert.Equal("/var/log", core.LastSftpListPath);

        var preview = await orchestrator.ReadSftpTextFileAsync(
            lease,
            "/var/log/syslog",
            CancellationToken.None);

        var previewed = Assert.IsType<SftpTextPreviewResult.Previewed>(preview);
        Assert.Equal("/var/log/syslog", previewed.Path);
        Assert.Equal("hello\nworld\n", previewed.Content);
        Assert.Equal(1, core.ReadSftpTextFileCalls);
        Assert.Equal(55UL, core.LastSftpReadSessionId);
        Assert.Equal("/var/log/syslog", core.LastSftpReadPath);

        var download = await orchestrator.DownloadSftpFileAsync(
            lease,
            "/var/log/syslog",
            @"C:\Downloads\syslog",
            CancellationToken.None);

        var downloaded = Assert.IsType<SftpDownloadResult.Downloaded>(download);
        Assert.Equal("/var/log/syslog", downloaded.Path);
        Assert.Equal(42UL, downloaded.ByteLength);
        Assert.Equal(1, core.DownloadSftpFileCalls);
        Assert.Equal(55UL, core.LastSftpDownloadSessionId);
        Assert.Equal("/var/log/syslog", core.LastSftpDownloadPath);

        var upload = await orchestrator.UploadSftpFileAsync(
            lease,
            @"C:\Uploads\report.txt",
            "/var/log/report.txt",
            CancellationToken.None);

        var uploaded = Assert.IsType<SftpUploadResult.Uploaded>(upload);
        Assert.Equal("/var/log/report.txt", uploaded.Path);
        Assert.Equal(42UL, uploaded.ByteLength);
        Assert.Equal(1, core.UploadSftpFileCalls);
        Assert.Equal(55UL, core.LastSftpUploadSessionId);
        Assert.Equal(@"C:\Uploads\report.txt", core.LastSftpUploadLocalPath);
        Assert.Equal("/var/log/report.txt", core.LastSftpUploadRemotePath);

        var snapshot = new SftpMutationSnapshot(42, 0x81A4U, 1_700_000_000, false);
        var created = await orchestrator.CreateSftpDirectoryAsync(
            lease,
            "/var/log/archive",
            CancellationToken.None);
        Assert.IsType<SftpMutationResult.Completed>(created);

        var fileCreated = await orchestrator.CreateSftpFileAsync(
            lease,
            "/var/log/empty.txt",
            CancellationToken.None);
        Assert.IsType<SftpMutationResult.Completed>(fileCreated);

        var renamed = await orchestrator.RenameSftpEntryAsync(
            lease,
            "/var/log/syslog",
            "/var/log/syslog.old",
            snapshot,
            CancellationToken.None);
        Assert.IsType<SftpMutationResult.Completed>(renamed);

        var removed = await orchestrator.RemoveSftpEntryAsync(
            lease,
            "/var/log/syslog.old",
            snapshot,
            CancellationToken.None);
        Assert.IsType<SftpMutationResult.Completed>(removed);
        var permissionsChanged = await orchestrator.ChangeSftpPermissionsAsync(
            lease,
            "/var/log/syslog",
            0x1A0U,
            snapshot,
            CancellationToken.None);
        Assert.IsType<SftpMutationResult.Completed>(permissionsChanged);
        Assert.Equal(1, core.CreateSftpDirectoryCalls);
        Assert.Equal(1, core.CreateSftpFileCalls);
        Assert.Equal(1, core.RenameSftpEntryCalls);
        Assert.Equal(1, core.RemoveSftpEntryCalls);
        Assert.Equal(1, core.ChangeSftpPermissionsCalls);
        Assert.Equal(0x1A0U, core.LastSftpPermissionsMode);
        Assert.Equal(snapshot.Size, core.LastSftpMutationSnapshot?.Size);
        Assert.Equal(snapshot.PermissionsOctal, core.LastSftpMutationSnapshot?.PermissionsOctal);
    }

    [Fact]
    public async Task TerminalOutputIsPublishedOnlyForActiveTerminalLease()
    {
        var workspaceId = Guid.NewGuid();
        var serverId = Guid.NewGuid();
        var orchestrator = CreateConnectedOrchestrator(out var core);
        TerminalOutputReceivedEventArgs? received = null;
        orchestrator.TerminalOutputReceived += (_, args) => received = args;

        await orchestrator.ConnectAsync(
            workspaceId,
            CreateAsset(serverId, Guid.NewGuid()),
            CancellationToken.None);
        var terminal = await orchestrator.OpenTerminalAsync(
            workspaceId,
            serverId,
            TerminalSize.Default,
            CancellationToken.None);
        var lease = Assert.IsType<TerminalOpenResult.Opened>(terminal).Lease;

        core.RaiseTerminalData(999, "ignored"u8.ToArray());
        Assert.Null(received);

        core.RaiseTerminalData(lease.TerminalChannelId, "hello\n"u8.ToArray());

        Assert.NotNull(received);
        Assert.Equal(lease.TerminalChannelId, received.Lease.TerminalChannelId);
        Assert.Equal("hello\n", received.Text);
        Assert.Contains("hello", received.Snapshot, StringComparison.Ordinal);
    }

    [Fact]
    public async Task ClosedTerminalNoLongerReceivesOutput()
    {
        var workspaceId = Guid.NewGuid();
        var serverId = Guid.NewGuid();
        var orchestrator = CreateConnectedOrchestrator(out var core);
        var count = 0;
        orchestrator.TerminalOutputReceived += (_, _) => count++;

        await orchestrator.ConnectAsync(
            workspaceId,
            CreateAsset(serverId, Guid.NewGuid()),
            CancellationToken.None);
        var terminal = await orchestrator.OpenTerminalAsync(
            workspaceId,
            serverId,
            TerminalSize.Default,
            CancellationToken.None);
        var lease = Assert.IsType<TerminalOpenResult.Opened>(terminal).Lease;

        await orchestrator.CloseTerminalAsync(lease, CancellationToken.None);
        core.RaiseTerminalData(lease.TerminalChannelId, "late"u8.ToArray());

        Assert.Equal(0, count);
    }

    [Fact]
    public async Task OpenTerminalRequiresRegisteredVerifiedSession()
    {
        var orchestrator = new SessionOrchestrator(
            new FakeCheckedCoreClient(),
            new FakeCredentialVault(new CredentialMaterial("secret", string.Empty, string.Empty)),
            new FakeKnownHostsPathProvider(),
            new VerifiedSessionRegistry());

        await Assert.ThrowsAsync<InvalidOperationException>(async () =>
            await orchestrator.OpenTerminalAsync(
                Guid.NewGuid(),
                Guid.NewGuid(),
                TerminalSize.Default,
                CancellationToken.None));
    }

    [Fact]
    public async Task OpenSftpRequiresRegisteredVerifiedSession()
    {
        var workspaceId = Guid.NewGuid();
        var serverId = Guid.NewGuid();
        var orchestrator = CreateConnectedOrchestrator(out var core);

        await Assert.ThrowsAsync<InvalidOperationException>(async () =>
            await orchestrator.OpenSftpAsync(workspaceId, serverId, CancellationToken.None));

        await orchestrator.ConnectAsync(
            workspaceId,
            CreateAsset(serverId, Guid.NewGuid()),
            CancellationToken.None);

        var result = await orchestrator.OpenSftpAsync(workspaceId, serverId, CancellationToken.None);

        var opened = Assert.IsType<SftpOpenResult.Opened>(result);
        Assert.Equal(55UL, opened.Lease.SftpSessionId);
        Assert.Equal("example.com", opened.Lease.Host);
        Assert.Equal(1, core.OpenSftpCalls);
    }

    [Fact]
    public async Task TrustHostKeyPersistsOnlyMatchingChallenge()
    {
        var orchestrator = CreateConnectedOrchestrator(out var core);
        var challenge = CreateChallenge();

        var result = await orchestrator.TrustHostKeyAsync(
            challenge,
            "ops managed",
            CancellationToken.None);

        var persisted = Assert.IsType<HostKeyTrustResult.Persisted>(result);
        Assert.Equal(challenge.ChallengeId, persisted.ChallengeId);
        Assert.Equal("trusted_added", persisted.Status);
        Assert.Equal("ops managed", core.LastTrustComment);
        Assert.Equal("/tmp/orbitterm-known-hosts", core.LastKnownHostsPath);
    }

    [Fact]
    public async Task TrustHostKeyFailureStaysStructured()
    {
        var orchestrator = CreateConnectedOrchestrator(out var core);
        core.FailHostKeyTrust = true;

        var result = await orchestrator.TrustHostKeyAsync(
            CreateChallenge(),
            "ops managed",
            CancellationToken.None);

        var failed = Assert.IsType<HostKeyTrustResult.Failed>(result);
        Assert.Equal("challenge_already_resolved", failed.Code);
        Assert.Equal("error.host_key.challenge_resolved", failed.MessageKey);
    }

    [Fact]
    public async Task TrustHostKeyRejectsMismatchedPersistenceResult()
    {
        var orchestrator = CreateConnectedOrchestrator(out var core);
        core.MismatchHostKeyTrust = true;

        await Assert.ThrowsAsync<InvalidOperationException>(async () =>
            await orchestrator.TrustHostKeyAsync(
                CreateChallenge(),
                "ops managed",
                CancellationToken.None));
    }

    private static SessionOrchestrator CreateConnectedOrchestrator(out FakeCheckedCoreClient core)
    {
        core = new FakeCheckedCoreClient();
        return new SessionOrchestrator(
            core,
            new FakeCredentialVault(new CredentialMaterial("secret", string.Empty, string.Empty)),
            new FakeKnownHostsPathProvider(),
            new VerifiedSessionRegistry(),
            new TerminalSessionRegistry());
    }

    private static ServerAsset CreateAsset(Guid serverId, Guid credentialId)
    {
        return new ServerAsset(
            serverId,
            credentialId,
            "Example",
            "Default",
            "example.com",
            22,
            "alice",
            ServerAuthMethod.Password,
            ServerTransport.Ssh,
            false);
    }

    private static HostKeyChallengeViewModel CreateChallenge()
    {
        return new HostKeyChallengeViewModel(
            "challenge-1",
            "request-1",
            "Example.COM",
            "example.com",
            22,
            "ssh-ed25519",
            "SHA256:abc",
            "unknown_host",
            true,
            DateTimeOffset.UtcNow.AddMinutes(5));
    }

    private sealed class FakeCheckedCoreClient : ICheckedOrbitCoreClient
    {
        public event EventHandler<TerminalDataReceivedEventArgs>? TerminalDataReceived;

        public int OpenTerminalCalls { get; private set; }
        public int OpenSftpCalls { get; private set; }
        public int WriteTerminalCalls { get; private set; }
        public int ResizeTerminalCalls { get; private set; }
        public int CloseTerminalCalls { get; private set; }
        public int ListSftpDirectoryCalls { get; private set; }
        public int ReadSftpTextFileCalls { get; private set; }
        public int DownloadSftpFileCalls { get; private set; }
        public int UploadSftpFileCalls { get; private set; }
        public int CreateSftpDirectoryCalls { get; private set; }
        public int CreateSftpFileCalls { get; private set; }
        public int RenameSftpEntryCalls { get; private set; }
        public int RemoveSftpEntryCalls { get; private set; }
        public int ChangeSftpPermissionsCalls { get; private set; }
        public uint LastSftpPermissionsMode { get; private set; }
        public ulong LastSftpListSessionId { get; private set; }
        public string? LastSftpListPath { get; private set; }
        public ulong LastSftpReadSessionId { get; private set; }
        public string? LastSftpReadPath { get; private set; }
        public ulong LastSftpDownloadSessionId { get; private set; }
        public string? LastSftpDownloadPath { get; private set; }
        public ulong LastSftpUploadSessionId { get; private set; }
        public string? LastSftpUploadLocalPath { get; private set; }
        public string? LastSftpUploadRemotePath { get; private set; }
        public SftpEntrySnapshot? LastSftpMutationSnapshot { get; private set; }
        public bool FailWrites { get; set; }
        public bool FailHostKeyTrust { get; set; }
        public bool MismatchHostKeyTrust { get; set; }
        public string? LastKnownHostsPath { get; private set; }
        public string? LastTrustComment { get; private set; }

        public CheckedConnectOutcome Connect(CheckedConnectionRequest request, HostKeyRequestId requestId)
        {
            return new CheckedConnectOutcome.Connected(new ConnectedPayload(
                "9",
                request.Host,
                request.Host,
                checked((ushort)request.Port),
                $"{request.Host}:{request.Port}",
                "ssh-ed25519",
                "SHA256:abc",
                CheckedSecurityGeneration.HostKeyVerified));
        }

        public CheckedTerminalOpenOutcome OpenTerminal(
            ulong baseSessionId,
            uint columns,
            uint rows,
            HostKeyRequestId requestId)
        {
            OpenTerminalCalls++;
            return new CheckedTerminalOpenOutcome.Opened(new TerminalChannelOpenedPayload(
                baseSessionId.ToString(System.Globalization.CultureInfo.InvariantCulture),
                "88",
                CheckedSecurityGeneration.HostKeyVerified,
                columns,
                rows));
        }

        public CheckedHostKeyTrustOutcome AcceptAndPersistHostKey(
            string challengeId,
            string knownHostsPath,
            string comment,
            HostKeyRequestId requestId)
        {
            LastKnownHostsPath = knownHostsPath;
            LastTrustComment = comment;

            if (FailHostKeyTrust)
            {
                return new CheckedHostKeyTrustOutcome.Failed(new CheckedErrorPayload(
                    "challenge_already_resolved",
                    "error.host_key.challenge_resolved",
                    requestId.Value));
            }

            return new CheckedHostKeyTrustOutcome.Persisted(new HostKeyTrustPersistedPayload(
                challengeId,
                "Example.COM",
                MismatchHostKeyTrust ? "other.example" : "example.com",
                22,
                "example.com:22",
                "ssh-ed25519",
                "SHA256:abc",
                "trusted_added"));
        }

        public CheckedEnvelope OpenSftp(ulong baseSessionId, HostKeyRequestId requestId)
        {
            OpenSftpCalls++;
            Assert.Equal(9UL, baseSessionId);
            return CreateEnvelope(
                CheckedFfiKind.SftpChannelOpened,
                requestId.Value,
                $$"""
                {
                  "base_session_id": "{{baseSessionId}}",
                  "sftp_session_id": "55",
                  "security_generation": "host_key_verified"
                }
                """);
        }

        public CheckedEnvelope ListSftpDirectory(ulong sftpSessionId, string remotePath, HostKeyRequestId requestId)
        {
            ListSftpDirectoryCalls++;
            LastSftpListSessionId = sftpSessionId;
            LastSftpListPath = remotePath;
            return CreateEnvelope(
                CheckedFfiKind.SftpDirectoryList,
                requestId.Value,
                $$"""
                {
                  "sftp_session_id": "{{sftpSessionId}}",
                  "path": "{{remotePath}}",
                  "security_generation": "host_key_verified",
                  "entries": [
                    {
                      "name": "syslog",
                      "size": 42,
                      "permissions": "-rw-r--r--",
                    "permissions_octal": 33188,
                      "modified_at_unix": 1700000000
                    }
                  ]
                }
                """);
        }

        public CheckedEnvelope ReadSftpTextFile(ulong sftpSessionId, string remotePath, HostKeyRequestId requestId)
        {
            ReadSftpTextFileCalls++;
            LastSftpReadSessionId = sftpSessionId;
            LastSftpReadPath = remotePath;
            return CreateEnvelope(
                CheckedFfiKind.SftpTextFile,
                requestId.Value,
                $$"""
                {
                  "sftp_session_id": "{{sftpSessionId}}",
                  "path": "{{remotePath}}",
                  "security_generation": "host_key_verified",
                  "byte_length": 12,
                  "content": "hello\nworld\n"
                }
                """);
        }

        public CheckedEnvelope DownloadSftpFile(ulong sftpSessionId, string remotePath, string localPath, HostKeyRequestId requestId)
        {
            DownloadSftpFileCalls++;
            LastSftpDownloadSessionId = sftpSessionId;
            LastSftpDownloadPath = remotePath;
            return CreateEnvelope(
                CheckedFfiKind.SftpDownloadCompleted,
                requestId.Value,
                $$"""
                {
                  "sftp_session_id": "{{sftpSessionId}}",
                  "path": "{{remotePath}}",
                  "security_generation": "host_key_verified",
                  "byte_length": 42
                }
                """);
        }

        public CheckedEnvelope UploadSftpFile(ulong sftpSessionId, string localPath, string remotePath, HostKeyRequestId requestId)
        {
            UploadSftpFileCalls++;
            LastSftpUploadSessionId = sftpSessionId;
            LastSftpUploadLocalPath = localPath;
            LastSftpUploadRemotePath = remotePath;
            return CreateEnvelope(
                CheckedFfiKind.SftpUploadCompleted,
                requestId.Value,
                $$"""
                {
                  "sftp_session_id": "{{sftpSessionId}}",
                  "path": "{{remotePath}}",
                  "security_generation": "host_key_verified",
                  "byte_length": 42
                }
                """);
        }

        public CheckedEnvelope CreateSftpDirectory(ulong sftpSessionId, string remotePath, HostKeyRequestId requestId)
        {
            CreateSftpDirectoryCalls++;
            return CreateMutationEnvelope(sftpSessionId, "mkdir", remotePath, null, requestId);
        }

        public CheckedEnvelope CreateSftpFile(ulong sftpSessionId, string remotePath, HostKeyRequestId requestId)
        {
            CreateSftpFileCalls++;
            return CreateMutationEnvelope(sftpSessionId, "create_file", remotePath, null, requestId);
        }

        public CheckedEnvelope RenameSftpEntry(
            ulong sftpSessionId,
            string oldRemotePath,
            string newRemotePath,
            SftpEntrySnapshot snapshot,
            HostKeyRequestId requestId)
        {
            RenameSftpEntryCalls++;
            LastSftpMutationSnapshot = snapshot;
            return CreateMutationEnvelope(sftpSessionId, "rename", oldRemotePath, newRemotePath, requestId);
        }

        public CheckedEnvelope RemoveSftpEntry(
            ulong sftpSessionId,
            string remotePath,
            SftpEntrySnapshot snapshot,
            HostKeyRequestId requestId)
        {
            RemoveSftpEntryCalls++;
            LastSftpMutationSnapshot = snapshot;
            return CreateMutationEnvelope(sftpSessionId, "remove", remotePath, null, requestId);
        }

        public CheckedEnvelope ChangeSftpPermissions(
            ulong sftpSessionId,
            string remotePath,
            uint mode,
            SftpEntrySnapshot snapshot,
            HostKeyRequestId requestId)
        {
            ChangeSftpPermissionsCalls++;
            LastSftpPermissionsMode = mode;
            LastSftpMutationSnapshot = snapshot;
            return CreateMutationEnvelope(sftpSessionId, "chmod", remotePath, null, requestId);
        }

        public CheckedEnvelope WriteSftpTextFile(
            ulong sftpSessionId,
            string remotePath,
            string content,
            SftpEntrySnapshot snapshot,
            HostKeyRequestId requestId)
        {
            LastSftpMutationSnapshot = snapshot;
            return CreateMutationEnvelope(sftpSessionId, "write_text", remotePath, null, requestId);
        }

        private static CheckedEnvelope CreateMutationEnvelope(
            ulong sftpSessionId,
            string operation,
            string path,
            string? destinationPath,
            HostKeyRequestId requestId)
        {
            var destinationJson = destinationPath is null
                ? "null"
                : System.Text.Json.JsonSerializer.Serialize(destinationPath);
            return CreateEnvelope(
                CheckedFfiKind.SftpMutationCompleted,
                requestId.Value,
                $$"""
                {
                  "sftp_session_id": "{{sftpSessionId}}",
                  "operation": "{{operation}}",
                  "path": "{{path}}",
                  "destination_path": {{destinationJson}},
                  "security_generation": "host_key_verified"
                }
                """);
        }

        public TerminalControlResult WriteTerminal(ulong terminalChannelId, ReadOnlyMemory<byte> data)
        {
            WriteTerminalCalls++;
            Assert.Equal(88UL, terminalChannelId);
            Assert.False(data.IsEmpty);
            if (FailWrites)
            {
                return new TerminalControlResult.Failed("backend detail should not reach UI");
            }

            return new TerminalControlResult.Succeeded("wrote");
        }

        public TerminalControlResult ResizeTerminal(ulong terminalChannelId, uint columns, uint rows)
        {
            ResizeTerminalCalls++;
            Assert.Equal(88UL, terminalChannelId);
            Assert.Equal(100U, columns);
            Assert.Equal(30U, rows);
            return new TerminalControlResult.Succeeded("resized");
        }

        public TerminalControlResult CloseTerminal(ulong terminalChannelId)
        {
            CloseTerminalCalls++;
            Assert.Equal(88UL, terminalChannelId);
            return new TerminalControlResult.Succeeded("closed");
        }

        public CheckedEnvelope MonitorSnapshot(ulong baseSessionId, HostKeyRequestId requestId)
        {
            throw new NotSupportedException();
        }

        public CheckedEnvelope DockerList(ulong baseSessionId, HostKeyRequestId requestId)
        {
            throw new NotSupportedException();
        }

        public CheckedEnvelope DockerStats(ulong baseSessionId, HostKeyRequestId requestId)
        {
            throw new NotSupportedException();
        }

        public CheckedEnvelope DockerLogs(ulong baseSessionId, string containerId, uint tailLines, HostKeyRequestId requestId)
        {
            throw new NotSupportedException();
        }

        public CheckedEnvelope DockerAction(ulong baseSessionId, string containerId, string action, HostKeyRequestId requestId)
        {
            throw new NotSupportedException();
        }

        public CheckedEnvelope Exec(ulong baseSessionId, string command, HostKeyRequestId requestId)
        {
            throw new NotSupportedException();
        }

        public void RaiseTerminalData(ulong terminalChannelId, byte[] data)
        {
            TerminalDataReceived?.Invoke(this, new TerminalDataReceivedEventArgs(terminalChannelId, data));
        }

        private static CheckedEnvelope CreateEnvelope(string kind, string requestId, string dataJson)
        {
            using var document = System.Text.Json.JsonDocument.Parse(dataJson);
            return new CheckedEnvelope(1, kind, requestId, document.RootElement.Clone(), null);
        }
    }

    private sealed class FakeCredentialVault(CredentialMaterial credential) : ICredentialVault
    {
        public ValueTask<CredentialMaterial> ReadAsync(Guid credentialId, CancellationToken cancellationToken)
        {
            return ValueTask.FromResult(credential);
        }

        public ValueTask SaveAsync(Guid credentialId, CredentialMaterial credential, CancellationToken cancellationToken)
        {
            return ValueTask.CompletedTask;
        }

        public ValueTask DeleteAsync(Guid credentialId, CancellationToken cancellationToken)
        {
            return ValueTask.CompletedTask;
        }
    }

    private sealed class FakeKnownHostsPathProvider : IKnownHostsPathProvider
    {
        public string GetKnownHostsPath()
        {
            return "/tmp/orbitterm-known-hosts";
        }
    }
}
