using Microsoft.UI.Xaml;
using OrbitTerm.Application.Security;
using OrbitTerm.Application.Sessions;
using OrbitTerm.Application.Accounts;
using OrbitTerm.NativeBridge;
using OrbitTerm.Platform.Windows.Security;
using OrbitTerm.Platform.Windows.Sessions;
using OrbitTerm.Presentation;

namespace OrbitTerm.App;

public partial class App : Microsoft.UI.Xaml.Application
{
    private static readonly string startupDiagnosticPath = Path.Combine(
        Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData),
        "OrbitTerm",
        "diagnostics",
        "startup.log");
    private Window? window;

    public App()
    {
        OrbitNativeLibraryLoader.Register();
        InitializeComponent();
        UnhandledException += OnUnhandledException;
    }

    protected override void OnLaunched(LaunchActivatedEventArgs args)
    {
        try
        {
            var coreClient = new CheckedOrbitCoreClient();
            var credentialVault = new WindowsCredentialVault();
            var sshKeyLibrary = new SshKeyLibraryService(
                new WindowsSshKeyVault(),
                credentialVault,
                enforceCoreKeyValidation: true);
            IAccountSessionStore accountSessionStore = new WindowsAccountSessionStore();
            var accountProtocol = new OrbitHttpAccountProtocol(new OrbitEndpointPolicy());
            var serverAssetStore = new WindowsServerAssetStore();
            var snippetStore = new WindowsSnippetStore();
            var portForwardProfileLibrary = new PortForwardProfileLibrary(new WindowsPortForwardProfileVault());
            var encryptedConfigSynchronizer = new EncryptedConfigSynchronizationService(
                accountProtocol,
                serverAssetStore,
                snippetStore,
                credentialVault,
                new WindowsEncryptedSyncStateStore(),
                sshKeyLibrary,
                enforceCorePrivateKeyValidation: true,
                portForwardProfileLibrary: portForwardProfileLibrary);
            var encryptedAssetPublisher = new EncryptedAssetPublisher(
                accountProtocol,
                new WindowsEncryptedSyncStateStore(),
                enforceCorePrivateKeyValidation: true);
            var encryptedSnippetPublisher = new EncryptedSnippetPublisher(
                accountProtocol,
                new WindowsEncryptedSyncStateStore());
            var unlockController = new AccountUnlockController(
                accountSessionStore,
                accountProtocol,
                new ReadOnlyEncryptedConfigUnlockVerifier(accountProtocol),
                new WindowsAccountUnlockVerifierStore());
            var knownHostsPathProvider = new WindowsKnownHostsPathProvider();
            var orchestrator = new SessionOrchestrator(coreClient, credentialVault, knownHostsPathProvider);

            window = new MainWindow(
                orchestrator,
                credentialVault,
                serverAssetStore,
                snippetStore,
                accountSessionStore,
                unlockController,
                encryptedConfigSynchronizer,
                encryptedAssetPublisher,
                encryptedSnippetPublisher,
                sshKeyLibrary,
                portForwardProfileLibrary);
            window.Activate();
        }
        catch (Exception exception)
        {
            WriteStartupDiagnostic("OnLaunched", exception);
            throw;
        }
    }

    private static void WriteStartupDiagnostic(string stage, Exception exception)
    {
        try
        {
            Directory.CreateDirectory(Path.GetDirectoryName(startupDiagnosticPath)!);
            var innerType = exception.InnerException?.GetType().FullName ?? "none";
            var message = exception.Message.Replace('\r', ' ').Replace('\n', ' ');
            var stack = exception.StackTrace?
                .Replace("\r", " ")
                .Replace("\n", " | ")
                .Trim() ?? "none";
            File.AppendAllText(
                startupDiagnosticPath,
                $"{DateTimeOffset.UtcNow:O} stage={stage}; type={exception.GetType().FullName}; hresult=0x{exception.HResult:X8}; inner={innerType}; message={message}; stack={stack}{Environment.NewLine}");
        }
        catch (IOException)
        {
            // Startup diagnostics must never prevent the application from reporting its original failure.
        }
    }

    private void OnUnhandledException(object sender, Microsoft.UI.Xaml.UnhandledExceptionEventArgs args)
    {
        WriteStartupDiagnostic("UnhandledException", args.Exception);
        // UI commands must not terminate the workstation for a recoverable
        // presentation error. The diagnostic preserves the original exception
        // for targeted remediation on the following build.
        args.Handled = true;
    }
}
