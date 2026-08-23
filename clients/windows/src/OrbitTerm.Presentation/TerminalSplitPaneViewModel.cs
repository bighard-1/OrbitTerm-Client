using System.Collections.ObjectModel;
using OrbitTerm.Application.Sessions;

namespace OrbitTerm.Presentation;

/// <summary>
/// One auxiliary PTY attached to an already verified workspace session.
/// The primary terminal remains owned by MainWindowViewModel for compatibility;
/// only auxiliary panes are represented here.
/// </summary>
public sealed class TerminalSplitPaneViewModel : ObservableObject
{
    private TerminalSessionLease lease;
    private bool isActive;

    public TerminalSplitPaneViewModel(Guid id, int paneNumber, TerminalSessionLease lease)
    {
        Id = id == Guid.Empty ? Guid.NewGuid() : id;
        PaneNumber = Math.Clamp(paneNumber, 2, 4);
        this.lease = lease;
    }

    public Guid Id { get; }

    public int PaneNumber { get; private set; }

    public string Label => $"分屏 {PaneNumber}";

    public string AccessibilityLabel => $"终端分屏 {PaneNumber}";

    public TerminalSessionLease Lease
    {
        get => lease;
        private set => SetProperty(ref lease, value);
    }

    public ObservableCollection<TerminalLineViewModel> Lines { get; } = [];

    public bool IsActive
    {
        get => isActive;
        set => SetProperty(ref isActive, value);
    }

    public void UpdateLease(TerminalSessionLease updatedLease) => Lease = updatedLease;

    public void UpdatePaneNumber(int paneNumber)
    {
        var normalized = Math.Clamp(paneNumber, 2, 4);
        if (PaneNumber == normalized)
        {
            return;
        }

        PaneNumber = normalized;
        OnPropertyChanged(nameof(PaneNumber));
        OnPropertyChanged(nameof(Label));
        OnPropertyChanged(nameof(AccessibilityLabel));
    }
}
