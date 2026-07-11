namespace OrbitTerm.Presentation;

public sealed record DockerContainerViewModel(
    string ShortId,
    string Name,
    string Image,
    string State,
    string Status,
    string RunningFor,
    string Id);
