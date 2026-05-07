using Microsoft.Extensions.DependencyInjection;
using Microsoft.UI.Xaml;
using Microsoft.Windows.AppLifecycle;

namespace PabloCompanion;

public partial class App : Application
{
    public static IServiceProvider Services { get; private set; } = null!;
    public static Microsoft.UI.Dispatching.DispatcherQueue? UiDispatcherQueue { get; private set; }

    private Window? _window;

    public App()
    {
        InitializeComponent();

        var services = new ServiceCollection();
        ConfigureServices(services);
        Services = services.BuildServiceProvider();
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

        // Resume pending transcription uploads after launch
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
            var transcriptionVm = Services.GetRequiredService<ViewModels.TranscriptionViewModel>();
            await transcriptionVm.ResumePendingUploadsAsync();
        }
        catch
        {
            // Best effort — don't crash on resume failures
        }
    }
}
