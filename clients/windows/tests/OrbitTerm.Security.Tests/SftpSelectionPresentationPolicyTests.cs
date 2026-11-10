using OrbitTerm.Presentation;
using Xunit;

namespace OrbitTerm.Security.Tests;

public sealed class SftpSelectionPresentationPolicyTests
{
    [Theory]
    [InlineData(0, false)]
    [InlineData(1, false)]
    [InlineData(2, true)]
    [InlineData(12, true)]
    public void BatchActionsRequireAnExtendedSelection(int selectedCount, bool expected)
    {
        Assert.Equal(expected, SftpSelectionPresentationPolicy.ShouldShowBatchActions(selectedCount));
    }
}
