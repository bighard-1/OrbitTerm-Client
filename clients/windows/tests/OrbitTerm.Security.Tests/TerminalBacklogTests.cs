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
}
