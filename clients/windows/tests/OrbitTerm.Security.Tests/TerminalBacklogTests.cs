using System.Text;
using OrbitTerm.Terminal;
using Xunit;

namespace OrbitTerm.Security.Tests;

public sealed class TerminalBacklogTests
{
    [Fact]
    public void AppendMaintainsBoundedBacklog()
    {
        var backlog = new TerminalBacklog(maxBytes: 8);

        backlog.Append(Encoding.UTF8.GetBytes("1234"));
        backlog.Append(Encoding.UTF8.GetBytes("5678"));
        backlog.Append(Encoding.UTF8.GetBytes("90"));

        Assert.True(backlog.CurrentBytes <= 8);
        Assert.Equal("567890", backlog.Snapshot());
    }

    [Fact]
    public void AppendPreservesUtf8CharactersSplitAcrossTerminalCallbacks()
    {
        var backlog = new TerminalBacklog();
        var bytes = Encoding.UTF8.GetBytes("中");

        var first = backlog.Append(bytes.AsSpan(0, 2));
        var second = backlog.Append(bytes.AsSpan(2));

        Assert.Equal(string.Empty, first);
        Assert.Equal("中", second);
        Assert.Equal("中", backlog.Snapshot());
    }

    [Fact]
    public void ClearRemovesBufferedOutputAndResetsDecoder()
    {
        var backlog = new TerminalBacklog();
        var bytes = Encoding.UTF8.GetBytes("中");
        backlog.Append(bytes.AsSpan(0, 2));

        backlog.Clear();
        var next = backlog.Append(Encoding.UTF8.GetBytes("A"));

        Assert.Equal("A", next);
        Assert.Equal("A", backlog.Snapshot());
        Assert.Equal(1, backlog.CurrentBytes);
    }
}
