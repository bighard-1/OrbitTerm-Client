namespace OrbitTerm.Application.Sessions;

/// <summary>Matches Apple's allAssets / selectedAssets SnippetAssetScope contract.</summary>
public sealed record SnippetAssetScope(string Mode, IReadOnlyList<Guid> AssetIds)
{
    public const string AllAssetsMode = "allAssets";
    public const string SelectedAssetsMode = "selectedAssets";
    public static SnippetAssetScope AllAssets { get; } = new(AllAssetsMode, []);

    public bool IsRestricted => string.Equals(Mode, SelectedAssetsMode, StringComparison.Ordinal) && AssetIds.Count > 0;

    public bool Allows(Guid assetId) => !IsRestricted || AssetIds.Contains(assetId);

    public static SnippetAssetScope Normalize(SnippetAssetScope? scope) =>
        scope is { IsRestricted: true }
            ? new(SelectedAssetsMode, scope.AssetIds.Where(id => id != Guid.Empty).Distinct().Order().ToArray())
            : AllAssets;
}
