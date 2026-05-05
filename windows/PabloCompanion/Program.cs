using Microsoft.Extensions.DependencyInjection;
using Microsoft.UI.Dispatching;
using Microsoft.UI.Xaml;
using Microsoft.Windows.AppLifecycle;
using PabloCompanion.Services;

namespace PabloCompanion;

/// <summary>
/// Custom entry point.
///
/// Single-instance via WinAppSDK AppInstance.FindOrRegisterForKey — works in
/// both direct .exe launch and packaged COM activation paths (a named mutex
/// alone does not, since COM activation can bypass Main entirely).
///
/// Protocol activations (`pablohealth://callback?...`) for OAuth callbacks are
/// forwarded to the running instance and delivered to ProtocolActivationListener,
/// which is awaited by AuthViewModel during sign-in.
/// </summary>
public static class Program
{
    private const string MainInstanceKey = "PabloCompanion-Main";

    [STAThread]
    static int Main(string[] args)
    {
        WinRT.ComWrappersSupport.InitializeComWrappers();

        var isRedirect = DecideRedirectionAsync().GetAwaiter().GetResult();
        if (isRedirect) return 0;

        Application.Start((p) =>
        {
            var context = new DispatcherQueueSynchronizationContext(
                DispatcherQueue.GetForCurrentThread());
            SynchronizationContext.SetSynchronizationContext(context);
            _ = new App();
        });

        return 0;
    }

    private static async Task<bool> DecideRedirectionAsync()
    {
        var activatedArgs = AppInstance.GetCurrent().GetActivatedEventArgs();
        var keyInstance = AppInstance.FindOrRegisterForKey(MainInstanceKey);

        if (keyInstance.IsCurrent)
        {
            keyInstance.Activated += OnActivated;
            return false;
        }

        await keyInstance.RedirectActivationToAsync(activatedArgs);
        return true;
    }

    private static void OnActivated(object? sender, AppActivationArguments args)
    {
        if (args.Kind != ExtendedActivationKind.Protocol) return;
        if (args.Data is not Windows.ApplicationModel.Activation.IProtocolActivatedEventArgs pa) return;

        var listener = App.Services?.GetService<ProtocolActivationListener>();
        listener?.Deliver(pa.Uri);
    }
}
