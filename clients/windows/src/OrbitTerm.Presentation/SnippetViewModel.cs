using OrbitTerm.Application.Sessions;

namespace OrbitTerm.Presentation;

public sealed record SnippetViewModel(
    Guid Id,
    string Title,
    string Command,
    string Category,
    DateTimeOffset CreatedAt,
    DateTimeOffset UpdatedAt,
    SnippetAssetScope? AssetScope = null)
{
    public SnippetAssetScope EffectiveAssetScope => SnippetAssetScope.Normalize(AssetScope);
    public string ScopeDisplay => EffectiveAssetScope.IsRestricted ? "指定资产" : "全部资产";
    public bool AllowsAsset(Guid assetId) => EffectiveAssetScope.Allows(assetId);
    public SnippetRecord ToRecord() => new(Id, Title, Command, Category, CreatedAt, UpdatedAt, EffectiveAssetScope);

    public static SnippetViewModel FromRecord(SnippetRecord record) =>
        new(record.Id, record.Title, record.Command, record.Category, record.CreatedAt, record.UpdatedAt, record.EffectiveAssetScope);
}
