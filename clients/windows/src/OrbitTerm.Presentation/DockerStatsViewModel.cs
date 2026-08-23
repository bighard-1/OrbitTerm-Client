namespace OrbitTerm.Presentation;

public sealed record DockerStatsViewModel(
    string ShortId,
    string Name,
    string CpuPercent,
    string MemoryPercent,
    string MemoryUsage,
    string NetworkIo,
    string BlockIo,
    string Pids,
    string Id);
