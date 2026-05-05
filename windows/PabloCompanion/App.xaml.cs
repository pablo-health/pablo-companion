using System.Diagnostics;
using System.IO;
using System.Text;
using Microsoft.Extensions.DependencyInjection;
using Microsoft.UI.Xaml;

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

        // Resume pending transcription uploads after launch
        _ = ResumePendingUploadsAsync();
    }

    private static void ConfigureServices(ServiceCollection services)
    {
        services.AddSingleton<Services.CredentialManager>();
        services.AddSingleton<Services.TokenRefresher>();
        services.AddSingleton<Services.APIClient>();
        services.AddSingleton<Services.VideoLaunchService>();

        services.AddSingleton<Services.RecordingService>();
        services.AddSingleton<Services.SessionRecordingStore>();

        services.AddSingleton<Services.PendingTranscriptionStore>();
        services.AddSingleton<Services.PlaybackService>();
        services.AddSingleton<Services.InactivityMonitor>();
        services.AddSingleton<Services.EhrNavigator>();

        services.AddSingleton<Services.PracticeApiClient>();
        services.AddSingleton<Services.ProtocolActivationListener>();

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
            var transcriptionVm = Services.GetRequiredService<ViewModels.TranscriptionViewModel>();
            await transcriptionVm.ResumePendingUploadsAsync();
        }
        catch
        {
            // Best effort — don't crash on resume failures
        }
    }
}
