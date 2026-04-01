using Microsoft.UI.Dispatching;
using Microsoft.UI.Xaml;

namespace PabloCompanion;

/// <summary>
/// Custom entry point for single-instance support.
///
/// Single-instance is enforced via a named mutex. Auth uses loopback redirect
/// (RFC 8252 §7.3) instead of protocol activation — no URL scheme registration needed.
/// </summary>
public static class Program
{
    private const string MutexName = "PabloCompanion_SingleInstance";

    /// <summary>
    /// True when Main() ran — false when COM activation bypasses Main() entirely.
    /// </summary>
    internal static bool RanThroughMain { get; private set; }

    [STAThread]
    static void Main(string[] args)
    {
        WinRT.ComWrappersSupport.InitializeComWrappers();

        // Unregister WinAppSDK COM-based activation (from previous versions) — it bypasses Main()
        try { Microsoft.Windows.AppLifecycle.ActivationRegistrationManager.UnregisterForProtocolActivation("pablohealth", ""); }
        catch { }

        // Single-instance via named mutex
        bool createdNew;
        using var mutex = new Mutex(true, MutexName, out createdNew);

        if (!createdNew)
        {
            // Another instance is already running — exit
            return;
        }

        // We are the main instance
        RanThroughMain = true;

        Application.Start((p) =>
        {
            var context = new DispatcherQueueSynchronizationContext(
                DispatcherQueue.GetForCurrentThread());
            SynchronizationContext.SetSynchronizationContext(context);
            _ = new App();
        });
    }
}
