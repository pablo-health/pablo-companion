using Microsoft.Extensions.DependencyInjection;
using Microsoft.UI.Xaml;

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
