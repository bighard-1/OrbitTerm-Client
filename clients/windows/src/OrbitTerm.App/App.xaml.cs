using Microsoft.UI.Xaml;
using OrbitTerm.Application.Sessions;
using OrbitTerm.NativeBridge;
using OrbitTerm.Platform.Windows.Security;
using OrbitTerm.Platform.Windows.Sessions;
using OrbitTerm.Presentation;

namespace OrbitTerm.App;

public partial class App : Microsoft.UI.Xaml.Application
{
    private Window? window;

    public App()
    {
        OrbitNativeLibraryLoader.Register();
        InitializeComponent();
    }

    protected override void OnLaunched(LaunchActivatedEventArgs args)
    {
        var coreClient = new CheckedOrbitCoreClient();
        var credentialVault = new WindowsCredentialVault();
        var serverAssetStore = new WindowsServerAssetStore();
        var snippetStore = new WindowsSnippetStore();
        var knownHostsPathProvider = new WindowsKnownHostsPathProvider();
        var orchestrator = new SessionOrchestrator(coreClient, credentialVault, knownHostsPathProvider);

        window = new MainWindow(orchestrator, credentialVault, serverAssetStore, snippetStore);
        window.Activate();
    }
}
