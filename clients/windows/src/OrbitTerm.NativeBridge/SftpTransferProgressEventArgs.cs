namespace OrbitTerm.NativeBridge;

public sealed class SftpTransferProgressEventArgs : EventArgs
{
    public SftpTransferProgressEventArgs(string requestId, ulong transferredBytes, ulong? totalBytes)
    {
        RequestId = requestId;
        TransferredBytes = transferredBytes;
        TotalBytes = totalBytes;
    }

    public string RequestId { get; }

    public ulong TransferredBytes { get; }

    public ulong? TotalBytes { get; }
}
