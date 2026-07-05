using System.Diagnostics;
using System.IO;
using System.Text;
using Microsoft.Extensions.DependencyInjection;
using Microsoft.UI.Xaml;
using Microsoft.Windows.AppLifecycle;

namespace PabloCompanion;

public partial class App : Application
{
    public static IServiceProvider Services { get; private set; } = null!;
    public static Microsoft.UI.Dispatching.DispatcherQueue? UiDispatcherQueue { get; private set; }

    public static string CrashLogPath { get; } = Path.Combine(
        Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData),
        "PabloCompanion",
        "crash.log");

    public static void Log(string message)
    {
        try
        {
            Directory.CreateDirectory(Path.GetDirectoryName(CrashLogPath)!);
            var line = $"{DateTime.Now:HH:mm:ss.fff} {message}{Environment.NewLine}";
            File.AppendAllText(CrashLogPath, line);
            Debug.WriteLine(line);
        }
        catch { /* never crash on logging */ }
    }

    private Window? _window;

    public App()
    {
        WireUpCrashLogging();
        InitializeComponent();

        var services = new ServiceCollection();
        ConfigureServices(services);
        Services = services.BuildServiceProvider();
    }

    private void WireUpCrashLogging()
    {
        UnhandledException += (_, e) =>
        {
            LogCrash("Application.UnhandledException", e.Exception, e.Message);
        };
        AppDomain.CurrentDomain.UnhandledException += (_, e) =>
        {
            LogCrash("AppDomain.UnhandledException",
                e.ExceptionObject as Exception,
                $"IsTerminating={e.IsTerminating}");
        };
        TaskScheduler.UnobservedTaskException += (_, e) =>
        {
            LogCrash("TaskScheduler.UnobservedTaskException", e.Exception, null);
            e.SetObserved();
        };
    }

    private static void LogCrash(string source, Exception? ex, string? extra)
        => LogException(source, ex, extra);

    public static void LogException(string source, Exception? ex, string? extra = null)
    {
        try
        {
            Directory.CreateDirectory(Path.GetDirectoryName(CrashLogPath)!);
            var sb = new StringBuilder();
            sb.AppendLine($"=== {DateTime.Now:O} {source} ===");
            if (!string.IsNullOrEmpty(extra)) sb.AppendLine(extra);

            var current = ex;
            int depth = 0;
            while (current != null)
            {
                var prefix = depth == 0 ? "Exception" : $"Inner[{depth}]";
                sb.AppendLine($"{prefix}: {current.GetType().FullName}");
                sb.AppendLine($"  HResult: 0x{current.HResult:X8}");
                sb.AppendLine($"  Message: {current.Message}");
                if (!string.IsNullOrEmpty(current.StackTrace))
                {
                    sb.AppendLine("  StackTrace:");
                    sb.AppendLine(current.StackTrace);
                }
                current = current.InnerException;
                depth++;
            }
            sb.AppendLine();
            File.AppendAllText(CrashLogPath, sb.ToString());
            Debug.WriteLine(sb.ToString());
        }
        catch
        {
            // Never let logging itself crash the app.
        }
    }

    protected override void OnLaunched(LaunchActivatedEventArgs args)
    {
        _window = new Views.MainWindow();
        UiDispatcherQueue = _window.DispatcherQueue;
        _window.Activate();

        // If the app was cold-launched by a non-OAuth pablohealth:// URI,
        // OnActivated does NOT fire — we have to read it off the initial
        // activation args and seed the router so MainWindow can drain it
        // after auth restore. (OAuth callbacks go to ProtocolActivationListener
        // and are routed by Program.cs's OnActivated for warm launches; cold
        // launches into OAuth never happen because the listener isn't awaiting
        // before the browser hand-off.)
        SeedDeepLinkFromInitialActivation();

        DropLegacyArtifacts();

        // Adopt orphaned recordings + resume pending transcription uploads after launch.
        _ = ResumePendingUploadsAsync();
    }

    private static void SeedDeepLinkFromInitialActivation()
    {
        var activatedArgs = AppInstance.GetCurrent().GetActivatedEventArgs();
        if (activatedArgs.Kind != ExtendedActivationKind.Protocol) return;
        if (activatedArgs.Data is not Windows.ApplicationModel.Activation.IProtocolActivatedEventArgs pa) return;
        if (string.Equals(pa.Uri.Host, "callback", StringComparison.OrdinalIgnoreCase)) return;

        Services.GetService<Services.DeepLinkRouter>()?.Deliver(pa.Uri);
    }

    /// <summary>
    /// Best-effort cleanup of artifacts left over from earlier app versions:
    ///   * <c>TranscriptionSettings.json</c> — held the now-removed <c>autoTranscribe</c> toggle
    ///   * <c>Models\</c> — local Whisper <c>ggml-*.bin</c> files (~4 GB) from the
    ///     pre-cloud-only architecture, when transcription ran on-device
    /// Both are unused by the current code path. Safe on fresh installs.
    /// </summary>
    private static void DropLegacyArtifacts()
    {
        var appData = Path.Combine(
            Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData),
            "PabloCompanion");

        try
        {
            var legacySettings = Path.Combine(appData, "TranscriptionSettings.json");
            if (File.Exists(legacySettings)) File.Delete(legacySettings);
        }
        catch { /* never block launch on cleanup */ }

        try
        {
            var legacyModels = Path.Combine(appData, "Models");
            if (Directory.Exists(legacyModels))
                Directory.Delete(legacyModels, recursive: true);
        }
        catch { /* never block launch on cleanup */ }
    }

    private static void ConfigureServices(ServiceCollection services)
    {
        services.AddSingleton<Services.CredentialManager>();
        services.AddSingleton<Services.DeviceKeyService>();
        services.AddSingleton<Services.TokenRefresher>();
        services.AddSingleton<Services.APIClient>();
        services.AddSingleton<Services.VideoLaunchService>();

        services.AddSingleton<Services.RecordingService>();
        services.AddSingleton<Services.SessionRecordingStore>();

        services.AddSingleton<Services.PendingTranscriptionStore>();
        services.AddSingleton<Services.RecordingDirectoryScanner>();
        services.AddSingleton<Services.PlaybackService>();
        services.AddSingleton<Services.InactivityMonitor>();
        services.AddSingleton<Services.EhrNavigator>();

        services.AddSingleton<Services.SessionKeepAliveService>();
        services.AddSingleton<Services.PracticeApiClient>();
        services.AddSingleton<Services.ProtocolActivationListener>();
        services.AddSingleton<Services.DeepLinkRouter>();

        services.AddSingleton<ViewModels.AuthViewModel>();
        services.AddSingleton<ViewModels.SessionViewModel>();
        services.AddSingleton<ViewModels.PatientViewModel>();
        services.AddSingleton<ViewModels.RecordingViewModel>();
        services.AddSingleton<ViewModels.TranscriptionViewModel>();
        services.AddSingleton<ViewModels.SubscriptionViewModel>();
        services.AddSingleton<ViewModels.PracticeViewModel>();
    }

    private static async Task ResumePendingUploadsAsync()
    {
        try
        {
            // Small delay to let the UI settle before background work
            await Task.Delay(2000);

            // First, sweep the disk for orphaned recordings and adopt them into
            // the pending queue. This is the safety net for any path where audio
            // ended up on disk but never reached the upload pipeline.
            var scanner = Services.GetRequiredService<Services.RecordingDirectoryScanner>();
            var adopted = scanner.AdoptOrphans();
            if (adopted > 0) Log($"Adopted {adopted} orphaned recording(s) into pending queue.");

            var transcriptionVm = Services.GetRequiredService<ViewModels.TranscriptionViewModel>();
            await transcriptionVm.ResumePendingUploadsAsync();
        }
        catch (Exception ex)
        {
            // Best effort — don't crash on resume failures
            LogException("ResumePendingUploadsAsync", ex);
        }
    }
}
