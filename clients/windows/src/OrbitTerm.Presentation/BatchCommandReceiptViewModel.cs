namespace OrbitTerm.Presentation;

/// <summary>
/// One asset-scoped batch command receipt. Keeping results structured allows
/// the UI to search, isolate failures, and export without parsing display text.
/// </summary>
public sealed class BatchCommandReceiptViewModel(
    Guid assetId,
    string name,
    string endpoint,
    bool isSuccess,
    string output)
{
    public Guid AssetId { get; } = assetId;

    public string Name { get; } = name;

    public string Endpoint { get; } = endpoint;

    public bool IsSuccess { get; } = isSuccess;

    public string Status => IsSuccess ? "成功" : "失败";

    public string Output { get; } = output;

    public string DisplayText => string.Concat("[", Name, " · ", Endpoint, "]\n", Output);
}
