using System.Runtime.InteropServices;
using System.Text;
using Microsoft.UI.Dispatching;
using Microsoft.UI.Xaml;
using Microsoft.Win32;

namespace PabloCompanion;

/// <summary>
/// Custom entry point for single-instance support and pablohealth:// protocol activation.
///
/// Uses traditional registry-based protocol registration (shell\open\command) instead of
/// WinAppSDK's ActivationRegistrationManager, which uses COM activation that can bypass
/// our Main() and launch unwanted second windows.
///
/// Single-instance is enforced via a named mutex. Protocol URIs from second instances
/// are forwarded to the existing window via WM_COPYDATA.
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

        // Register pablohealth:// protocol via traditional registry (reliable for unpackaged apps)
        RegisterProtocolHandler();

        // Check if launched via protocol activation (URL passed as command-line arg)
        Uri? protocolUri = null;
        if (args.Length > 0 && args[0].StartsWith("pablohealth://", StringComparison.OrdinalIgnoreCase))
        {
            Uri.TryCreate(args[0], UriKind.Absolute, out protocolUri);
        }

        // Single-instance via named mutex
        bool createdNew;
        using var mutex = new Mutex(true, MutexName, out createdNew);

        if (!createdNew)
        {
            // Another instance is running — forward URI and exit
            if (protocolUri != null)
            {
                SendUriToExistingInstance(protocolUri);
            }
            return;
        }

        // We are the main instance
        RanThroughMain = true;

        if (protocolUri != null)
        {
            App.PendingProtocolUri = protocolUri;
        }

        Application.Start((p) =>
        {
            var context = new DispatcherQueueSynchronizationContext(
                DispatcherQueue.GetForCurrentThread());
            SynchronizationContext.SetSynchronizationContext(context);
            _ = new App();
        });
    }

    /// <summary>
    /// Registers pablohealth:// protocol handler via HKCU registry.
    /// Windows will launch our exe with the URL as the first command-line argument.
    /// </summary>
    private static void RegisterProtocolHandler()
    {
        var exePath = Environment.ProcessPath;
        if (string.IsNullOrEmpty(exePath)) return;

        try
        {
            // Standard URL protocol handler
            using var key = Registry.CurrentUser.CreateSubKey(@"Software\Classes\pablohealth");
            key.SetValue("", "URL:Pablo Companion Protocol");
            key.SetValue("URL Protocol", "");

            using var iconKey = key.CreateSubKey("DefaultIcon");
            iconKey.SetValue("", $"\"{exePath}\",0");

            using var commandKey = key.CreateSubKey(@"shell\open\command");
            commandKey.SetValue("", $"\"{exePath}\" \"%1\"");

            // Registered Application + Capabilities — required for Windows 11
            // browsers/Explorer to discover the handler via "Open with" dialogs
            using var capKey = Registry.CurrentUser.CreateSubKey(@"Software\PabloCompanion\Capabilities");
            capKey.SetValue("ApplicationName", "Pablo Companion");
            capKey.SetValue("ApplicationDescription", "Desktop companion for Pablo Health therapists");

            using var urlAssoc = capKey.CreateSubKey("URLAssociations");
            urlAssoc.SetValue("pablohealth", "pablohealth");

            using var regApps = Registry.CurrentUser.CreateSubKey(@"Software\RegisteredApplications");
            regApps.SetValue("PabloCompanion", @"Software\PabloCompanion\Capabilities");

            // Clean up stale WinAppSDK COM activation remnants
            try
            {
                Registry.CurrentUser.DeleteSubKeyTree(@"Software\Classes\App.2b0068b4a419ea20.Protocol", false);
            }
            catch { }
        }
        catch
        {
            // Non-fatal — protocol registration is best-effort
        }
    }

    /// <summary>
    /// Finds the existing main window and sends the protocol URI via WM_COPYDATA.
    /// </summary>
    public static void SendUriToExistingInstance(Uri uri)
    {
        var hwnd = FindWindow(null, "Pablo Companion");
        if (hwnd == IntPtr.Zero) return;

        var uriBytes = Encoding.UTF8.GetBytes(uri.ToString());
        var dataHandle = GCHandle.Alloc(uriBytes, GCHandleType.Pinned);
        try
        {
            var copyData = new COPYDATASTRUCT
            {
                dwData = (IntPtr)0x5041424C, // "PABL" magic
                cbData = uriBytes.Length,
                lpData = dataHandle.AddrOfPinnedObject(),
            };
            SendMessage(hwnd, WM_COPYDATA, IntPtr.Zero, ref copyData);
            SetForegroundWindow(hwnd);
        }
        finally
        {
            dataHandle.Free();
        }
    }

    // P/Invoke
    private const int WM_COPYDATA = 0x004A;

    [StructLayout(LayoutKind.Sequential)]
    private struct COPYDATASTRUCT
    {
        public IntPtr dwData;
        public int cbData;
        public IntPtr lpData;
    }

    [DllImport("user32.dll", CharSet = CharSet.Unicode)]
    private static extern IntPtr FindWindow(string? className, string windowName);

    [DllImport("user32.dll")]
    private static extern IntPtr SendMessage(IntPtr hWnd, int msg, IntPtr wParam, ref COPYDATASTRUCT lParam);

    [DllImport("user32.dll")]
    private static extern bool SetForegroundWindow(IntPtr hWnd);
}
