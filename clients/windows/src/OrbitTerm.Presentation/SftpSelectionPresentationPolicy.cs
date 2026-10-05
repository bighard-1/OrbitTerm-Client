namespace OrbitTerm.Presentation;

/// <summary>
/// Keeps ordinary file navigation separate from destructive/batch actions.
/// A single click is selection only; batch chrome appears only after the user
/// deliberately extends the selection.
/// </summary>
public static class SftpSelectionPresentationPolicy
{
    public static bool ShouldShowBatchActions(int selectedCount) => selectedCount > 1;
}
