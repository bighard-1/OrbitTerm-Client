using OrbitTerm.Application.Shortcuts;
using Xunit;

namespace OrbitTerm.Security.Tests;

public sealed class KeyboardShortcutPolicyTests
{
    [Fact]
    public void DefaultsAreUniqueAndValid()
    {
        var assignments = KeyboardShortcutCatalog.CreateDefaults();

        var result = KeyboardShortcutPolicy.ValidateAll(assignments);

        Assert.True(result.IsValid, result.Message);
    }

    [Fact]
    public void TerminalFullscreenUsesStandardF11WithoutModifiers()
    {
        var assignments = KeyboardShortcutCatalog.CreateDefaults();

        Assert.Equal(
            new KeyboardShortcutGesture("F11", ShortcutModifiers.None),
            assignments[AppShortcutAction.ToggleTerminalFullscreen]);
        Assert.True(KeyboardShortcutPolicy.ValidateAll(assignments).IsValid);
    }

    [Fact]
    public void DuplicateAssignmentReportsTheExistingAction()
    {
        var assignments = KeyboardShortcutCatalog.CreateDefaults();
        assignments[AppShortcutAction.OpenSettings] = assignments[AppShortcutAction.NewWorkspaceTab];

        var result = KeyboardShortcutPolicy.ValidateAssignment(
            AppShortcutAction.OpenSettings,
            assignments[AppShortcutAction.OpenSettings]!,
            assignments);

        Assert.False(result.IsValid);
        Assert.Contains("新建会话标签", result.Message);
    }

    [Theory]
    [InlineData("F4", ShortcutModifiers.Alt)]
    [InlineData("Tab", ShortcutModifiers.Alt)]
    [InlineData("Delete", ShortcutModifiers.Control | ShortcutModifiers.Alt)]
    [InlineData("Escape", ShortcutModifiers.Control | ShortcutModifiers.Shift)]
    public void WindowsReservedCombinationsCannotBeAssigned(string key, ShortcutModifiers modifiers)
    {
        var assignments = KeyboardShortcutCatalog.CreateDefaults();
        var result = KeyboardShortcutPolicy.ValidateAssignment(
            AppShortcutAction.OpenSettings,
            new KeyboardShortcutGesture(key, modifiers),
            assignments);

        Assert.False(result.IsValid);
        Assert.Contains("Windows", result.Message);
    }

    [Theory]
    [InlineData("C")]
    [InlineData("V")]
    [InlineData("X")]
    [InlineData("Z")]
    public void EditingCombinationsCannotBeAssigned(string key)
    {
        var result = KeyboardShortcutPolicy.ValidateAssignment(
            AppShortcutAction.OpenSettings,
            new KeyboardShortcutGesture(key, ShortcutModifiers.Control),
            new Dictionary<AppShortcutAction, KeyboardShortcutGesture?>());

        Assert.False(result.IsValid);
        Assert.Contains("复制", result.Message);
    }

    [Fact]
    public void UnlistedControlLetterIsReservedForRemoteTerminal()
    {
        var result = KeyboardShortcutPolicy.ValidateAssignment(
            AppShortcutAction.OpenSettings,
            new KeyboardShortcutGesture("D", ShortcutModifiers.Control),
            new Dictionary<AppShortcutAction, KeyboardShortcutGesture?>());

        Assert.False(result.IsValid);
        Assert.Contains("远端终端", result.Message);
    }

    [Fact]
    public void ControlShiftAndAltAssignmentsRemainAvailable()
    {
        var empty = new Dictionary<AppShortcutAction, KeyboardShortcutGesture?>();

        Assert.True(KeyboardShortcutPolicy.ValidateAssignment(
            AppShortcutAction.OpenSettings,
            new KeyboardShortcutGesture("D", ShortcutModifiers.Control | ShortcutModifiers.Shift),
            empty).IsValid);
        Assert.True(KeyboardShortcutPolicy.ValidateAssignment(
            AppShortcutAction.OpenSettings,
            new KeyboardShortcutGesture("D", ShortcutModifiers.Alt),
            empty).IsValid);
    }
}
