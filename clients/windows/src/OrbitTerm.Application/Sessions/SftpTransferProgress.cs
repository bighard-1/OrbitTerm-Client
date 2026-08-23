namespace OrbitTerm.Application.Sessions;

public sealed record SftpTransferProgress(ulong TransferredBytes, ulong? TotalBytes);
