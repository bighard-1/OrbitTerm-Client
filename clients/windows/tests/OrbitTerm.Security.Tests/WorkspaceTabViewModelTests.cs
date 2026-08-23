using OrbitTerm.Presentation;
using Xunit;

namespace OrbitTerm.Security.Tests;

public sealed class WorkspaceTabViewModelTests
{
    [Fact]
    public void SessionChromeUsesConfiguredHostInsteadOfManualAssetNameBeforeTitleArrives()
    {
        var tab = Create("手动填写的很长资产名称", "203.0.113.10");

        Assert.Equal("203.0.113.10", tab.DisplayTitle);
        Assert.Equal("手动填写的很长资产名称", tab.Title);
    }

    [Fact]
    public void SessionChromeUsesHostNameFromOscTitle()
    {
        var tab = Create("手动资产名", "203.0.113.10");

        tab.ApplyRemoteTerminalTitle("ubuntu@instance-20260819-1542: ~");

        Assert.Equal("instance-20260819-1542", tab.DisplayTitle);
        Assert.Equal("手动资产名", tab.Title);
    }

    [Fact]
    public void ArbitraryApplicationTitleCannotReplaceSessionHostName()
    {
        var tab = Create("手动资产名", "203.0.113.10");

        tab.ApplyRemoteTerminalTitle("vim README.md");

        Assert.Equal("203.0.113.10", tab.DisplayTitle);
    }

    private static WorkspaceTabViewModel Create(string name, string host) => new(
        Guid.NewGuid(),
        Guid.NewGuid(),
        Guid.NewGuid(),
        name,
        host,
        "22",
        "ubuntu");
}
