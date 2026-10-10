using OrbitTerm.Application.Sessions;
using OrbitTerm.Presentation;
using Xunit;

namespace OrbitTerm.Security.Tests;

public sealed class SnippetViewModelTests
{
    [Fact]
    public void GlobalScopeUsesSharedDesktopLabel()
    {
        var snippet = Create(SnippetAssetScope.AllAssets);

        Assert.Equal("全部资产", snippet.ScopeDisplay);
    }

    [Fact]
    public void RestrictedScopeIncludesConcreteAssetCount()
    {
        var snippet = Create(new SnippetAssetScope(
            SnippetAssetScope.SelectedAssetsMode,
            [Guid.NewGuid(), Guid.NewGuid()]));

        Assert.Equal("限 2 台资产", snippet.ScopeDisplay);
    }

    private static SnippetViewModel Create(SnippetAssetScope scope) =>
        new(Guid.NewGuid(), "Health", "uptime", "Ops", DateTimeOffset.UnixEpoch,
            DateTimeOffset.UnixEpoch, scope);
}
