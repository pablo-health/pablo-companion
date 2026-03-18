using Microsoft.Extensions.DependencyInjection;
using Microsoft.UI.Xaml;

namespace PabloCompanion;

public partial class App : Application
{
    private const string MutexName = "PabloCompanion_SingleInstance";

    public static IServiceProvider Services { get; private set; } = null!;
    public static Microsoft.UI.Dispatching.DispatcherQueue? UiDispatcherQueue { get; private set; }
    public static Uri? PendingProtocolUri { get; set; }

    /// <summary>
    /// True when COM activation bypassed Main() and another instance already owns the mutex.
    /// </summary>
    private bool _isSecondInstance;
    private Uri? _comProtocolUri;
    private Window? _window;

    public App()
    {
        InitializeComponent();

        // Normal path: Main() ran, mutex already acquired, we're the primary instance.
        // COM activation path: Main() was bypassed — check if another instance is running.
        if (!Program.RanThroughMain)
        {
            bool createdNew;
            _ = new Mutex(true, MutexName, out createdNew);
            if (!createdNew)
            {
                _isSecondInstance = true;
                try
                {
                    var activatedArgs = Microsoft.Windows.AppLifecycle.AppInstance.GetCurrent().GetActivatedEventArgs();
                    if (activatedArgs.Kind == Microsoft.Windows.AppLifecycle.ExtendedActivationKind.Protocol)
                    {
                        var protocolArgs = activatedArgs.Data as Windows.ApplicationModel.Activation.IProtocolActivatedEventArgs;
                        _comProtocolUri = protocolArgs?.Uri;
                    }
                }
                catch { }
                return;
            }
        }

        var services = new ServiceCollection();
        ConfigureServices(services);
        Services = services.BuildServiceProvider();
    }

    protected override void OnLaunched(LaunchActivatedEventArgs args)
    {
        if (_isSecondInstance)
        {
            if (_comProtocolUri != null)
            {
                Program.SendUriToExistingInstance(_comProtocolUri);
            }
            Environment.Exit(0);
            return;
        }

        _window = new Views.MainWindow();
        UiDispatcherQueue = _window.DispatcherQueue;
        _window.Activate();

        if (PendingProtocolUri != null)
        {
            HandleProtocolActivation(PendingProtocolUri);
            PendingProtocolUri = null;
        }
    }

    private static void ConfigureServices(ServiceCollection services)
    {
        services.AddSingleton<Services.CredentialManager>();
        services.AddSingleton<Services.TokenRefresher>();
        services.AddSingleton<Services.APIClient>();
        services.AddSingleton<Services.VideoLaunchService>();

        services.AddSingleton<ViewModels.AuthViewModel>();
        services.AddSingleton<ViewModels.SessionViewModel>();
        services.AddTransient<ViewModels.PatientViewModel>();
    }

    public static void HandleProtocolActivationStatic(Uri uri)
    {
        var app = (App)Current;
        app.HandleProtocolActivation(uri);
    }

    private void HandleProtocolActivation(Uri uri)
    {
        var authVm = Services.GetRequiredService<ViewModels.AuthViewModel>();
        _ = authVm.HandleAuthCallbackAsync(uri);
    }
}
