using Microsoft.Extensions.DependencyInjection;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;
using PabloCompanion.Services;
using PabloCompanion.ViewModels;

namespace PabloCompanion.Views;

/// <summary>
/// The thin-client main surface: connection status, a mic-ready indicator, an
/// "Open Web Dashboard" button, and a footer (preferences / sign-out / version).
/// The web app is the dashboard; this window is a glanceable handoff target.
///
/// Shown when <c>ENABLE_NATIVE_DASHBOARD</c> is false (the default). The full
/// four-tab nav shell still exists and is shown verbatim when the flag is true.
/// </summary>
public sealed partial class MinimalShellView : UserControl
{
    private const string ClientVersion = "1.0.0";

    private readonly AuthViewModel _authVm;
    private readonly CredentialManager _credentials;
    private readonly RecordingViewModel _recordingVm;
    private readonly APIClient _apiClient;

    private Window? _preferencesWindow;

    public MinimalShellView()
    {
        _authVm = App.Services.GetRequiredService<AuthViewModel>();
        _credentials = App.Services.GetRequiredService<CredentialManager>();
        _recordingVm = App.Services.GetRequiredService<RecordingViewModel>();
        _apiClient = App.Services.GetRequiredService<APIClient>();

        InitializeComponent();

        VersionText.Text = $"Pablo Companion (Windows) v{ClientVersion}";
    }

    /// <summary>
    /// Refreshes the status block. Called by <see cref="MainWindow"/> whenever the
    /// shell becomes visible (i.e. after auth restores / changes).
    /// </summary>
    public void Refresh()
    {
        var connected = _authVm.AuthState == AuthState.Authenticated;

        var host = ResolveHost();
        var email = _authVm.UserEmail;
        StatusText.Text = connected
            ? (email is { Length: > 0 }
                ? $"Connected to {host} as {email}"
                : $"Connected to {host}")
            : "Not connected";
        StatusDot.Fill = ThemeBrush(connected ? "PabloSage" : "PabloError");

        _ = RefreshMicStatusAsync();
    }

    private async Task RefreshMicStatusAsync()
    {
        try
        {
            await _recordingVm.LoadAudioDevicesAsync();
        }
        catch (Exception ex)
        {
            App.LogException("MinimalShell.LoadAudioDevices", ex);
        }

        var micReady = _recordingVm.AvailableMics.Length > 0;
        MicDot.Fill = ThemeBrush(micReady ? "PabloSage" : "PabloError");
        MicText.Text = micReady ? "Microphone ready" : "No microphone detected";
    }

    /// <summary>
    /// The web host the companion is connected to, derived from the saved auth
    /// server URL (dev or prod) with the default as fallback. Used for the status
    /// line and as the base for the dashboard URL.
    /// </summary>
    private string ResolveHost()
    {
        var url = DashboardBaseUrl();
        return Uri.TryCreate(url, UriKind.Absolute, out var uri) ? uri.Host : url;
    }

    private string DashboardBaseUrl()
    {
        var saved = _credentials.AuthServerUrl;
        return string.IsNullOrWhiteSpace(saved) ? AppConstants.DefaultAuthServerUrl : saved;
    }

    private async void OpenDashboard_Click(object sender, RoutedEventArgs e)
    {
        var url = $"{DashboardBaseUrl().TrimEnd('/')}/dashboard";
        if (!Uri.TryCreate(url, UriKind.Absolute, out var uri)) return;
        await Windows.System.Launcher.LaunchUriAsync(uri);
    }

    private void SignOut_Click(object sender, RoutedEventArgs e) => _authVm.SignOutCommand.Execute(null);

    private void Preferences_Click(object sender, RoutedEventArgs e)
    {
        // Reuse the existing SettingsPage verbatim, hosted in an ephemeral window
        // with its own Frame (the minimal shell has no nav frame of its own).
        if (_preferencesWindow is not null)
        {
            _preferencesWindow.Activate();
            return;
        }

        var frame = new Frame();
        var window = new Window
        {
            Title = "Preferences",
            Content = frame,
        };
        window.Closed += (_, _) => _preferencesWindow = null;
        _preferencesWindow = window;

        frame.Navigate(typeof(SettingsPage));
        window.Activate();
    }

    private static Microsoft.UI.Xaml.Media.Brush ThemeBrush(string key)
        => (Microsoft.UI.Xaml.Media.Brush)Application.Current.Resources[key];
}
