using System.Windows.Input;

namespace OrbitTerm.Presentation;

public sealed class AsyncRelayCommand : ICommand
{
    private readonly Func<CancellationToken, Task> execute;
    private readonly Func<bool>? canExecute;
    private bool isRunning;
    private CancellationTokenSource? cancellationSource;

    public AsyncRelayCommand(Func<CancellationToken, Task> execute, Func<bool>? canExecute = null)
    {
        this.execute = execute;
        this.canExecute = canExecute;
    }

    public event EventHandler? CanExecuteChanged;

    public bool IsRunning => isRunning;

    public void Cancel() => cancellationSource?.Cancel();

    public bool CanExecute(object? parameter)
    {
        return !isRunning && (canExecute?.Invoke() ?? true);
    }

    public async void Execute(object? parameter)
    {
        await ExecuteAsync(parameter).ConfigureAwait(true);
    }

    public async Task ExecuteAsync(object? parameter)
    {
        if (!CanExecute(parameter))
        {
            return;
        }

        isRunning = true;
        cancellationSource = new CancellationTokenSource();
        RaiseCanExecuteChanged();
        try
        {
            await execute(cancellationSource.Token).ConfigureAwait(true);
        }
        catch (OperationCanceledException) when (cancellationSource.IsCancellationRequested)
        {
            // The owning view model is responsible for the user-facing status.
        }
        finally
        {
            cancellationSource.Dispose();
            cancellationSource = null;
            isRunning = false;
            RaiseCanExecuteChanged();
        }
    }

    public void RaiseCanExecuteChanged()
    {
        CanExecuteChanged?.Invoke(this, EventArgs.Empty);
    }
}
