using System.Runtime.InteropServices;
using Microsoft.Extensions.DependencyInjection;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;
using PabloCompanion.Models;
using PabloCompanion.Services;
using PabloCompanion.ViewModels;

namespace PabloCompanion.Views;

public sealed partial class MainWindow : Window
{
    [DllImport("user32.dll")]
    private static extern uint GetDpiForWindow(IntPtr hwnd);

    /// <summary>
    /// Gates the full native dashboard (four-tab nav shell). Default <c>false</c>:
    /// the companion shows only the minimal handoff window. Flip to <c>true</c> to
    /// restore the legacy in-app dashboard verbatim. No view code is deleted either
    /// way — the nav shell stays in the tree, just collapsed when this is false.
    ///
    /// <c>static readonly</c> (not <c>const</c>) so neither shell branch compiles to
    /// unreachable code — both are kept live and one flag flip away.
    /// </summary>
    private static readonly bool EnableNativeDashboard = false;

    private readonly AuthViewModel _authVm;
    private readonly SubscriptionViewModel _subscriptionVm;
    private readonly DeepLinkRouter _deepLinks;
    private readonly APIClient _apiClient;

    public MainWindow()
    {
        InitializeComponent();

        ContentFrame.NavigationFailed += (_, e) =>
        {
            App.LogException(
                $"Frame.NavigationFailed → {e.SourcePageType?.FullName}",
                e.Exception);
            e.Handled = true; // prevent app crash so we can see the log
        };

        var hwnd = WinRT.Interop.WindowNative.GetWindowHandle(this);

        // WinUI 3 AppWindow.Resize uses physical pixels, so scale for DPI
        var dpi = GetDpiForWindow(hwnd);
        var scale = dpi / 96.0;
        var appWindow = this.AppWindow;
        appWindow.Resize(new Windows.Graphics.SizeInt32(
            (int)(1000 * scale),
            (int)(750 * scale)));

        // Ensure window is resizable
        if (appWindow.Presenter is Microsoft.UI.Windowing.OverlappedPresenter presenter)
        {
            presenter.IsResizable = true;
            presenter.IsMinimizable = true;
            presenter.IsMaximizable = true;
        }

        _authVm = App.Services.GetRequiredService<AuthViewModel>();
        _authVm.PropertyChanged += AuthVm_PropertyChanged;

        _subscriptionVm = App.Services.GetRequiredService<SubscriptionViewModel>();
        SubscriptionBannerControl.Bind(_subscriptionVm);

        _deepLinks = App.Services.GetRequiredService<DeepLinkRouter>();
        _deepLinks.UriReceived += OnDeepLinkReceived;

        _apiClient = App.Services.GetRequiredService<APIClient>();

        // Keep the backend session alive while a recording is active — capture
        // is local and uploads happen at stop, so without this the server-side
        // idle timeout can kill the session mid-recording.
        var recordingVm = App.Services.GetRequiredService<RecordingViewModel>();
        var keepAlive = App.Services.GetRequiredService<SessionKeepAliveService>();
        recordingVm.PropertyChanged += (_, e) =>
        {
            if (e.PropertyName != nameof(RecordingViewModel.ActiveSessionId)) return;
            if (recordingVm.ActiveSessionId != null) keepAlive.Start();
            else keepAlive.Stop();
        };

        // Refresh subscription status when a 403 is detected
        var sessionVm = App.Services.GetRequiredService<SessionViewModel>();
        sessionVm.PropertyChanged += (_, e) =>
        {
            if (e.PropertyName == nameof(SessionViewModel.SubscriptionBlocked) && sessionVm.SubscriptionBlocked)
            {
                sessionVm.SubscriptionBlocked = false;
                _ = _subscriptionVm.RefreshStatusAsync();
            }
        };

        _ = InitAsync();
    }

    private async Task InitAsync()
    {
        await _authVm.TryRestoreSessionAsync();
        UpdateAuthUI();
    }

    private void AuthVm_PropertyChanged(object? sender, System.ComponentModel.PropertyChangedEventArgs e)
    {
        if (e.PropertyName == nameof(AuthViewModel.AuthState))
        {
            DispatcherQueue.TryEnqueue(UpdateAuthUI);
        }
    }

    private void UpdateAuthUI()
    {
        if (_authVm.AuthState == AuthState.Authenticated)
        {
            LoginPage.Visibility = Visibility.Collapsed;

            // Fetch subscription status and start polling (banner shows in both shells).
            _ = _subscriptionVm.RefreshStatusAsync();
            _subscriptionVm.StartPolling();

            if (EnableNativeDashboard)
            {
                MinimalShell.Visibility = Visibility.Collapsed;
                NavView.Visibility = Visibility.Visible;

                // Pre-load patient cache (matching macOS pattern)
                var patientVm = App.Services.GetRequiredService<PatientViewModel>();
                _ = patientVm.LoadPatientsAsync();

                if (ContentFrame.Content == null)
                {
                    ContentFrame.Navigate(typeof(DayPage));
                    NavView.SelectedItem = NavView.MenuItems[0];
                }
            }
            else
            {
                NavView.Visibility = Visibility.Collapsed;
                MinimalShell.Visibility = Visibility.Visible;
                MinimalShell.Refresh();
            }

            TryDrainDeepLink();
        }
        else
        {
            LoginPage.Visibility = Visibility.Visible;
            NavView.Visibility = Visibility.Collapsed;
            MinimalShell.Visibility = Visibility.Collapsed;
            _subscriptionVm.ClearAllData();
        }
    }

    private void OnDeepLinkReceived(object? sender, Uri uri)
    {
        DispatcherQueue.TryEnqueue(TryDrainDeepLink);
    }

    private void TryDrainDeepLink()
    {
        if (_authVm.AuthState != AuthState.Authenticated) return;
        var uri = _deepLinks.TakePending();
        if (uri is null) return;

        var (action, intentId) = LaunchIntentParser.Route(uri);
        switch (action)
        {
            case LaunchAction.Redeem when intentId is { } id:
                _ = RedeemAndConfirmAsync(id);
                break;

            case LaunchAction.ShowExpired:
                // Legacy appointment-only link: no intent to redeem, and we no longer
                // trust the raw appointment id to start a session — so we never fetch
                // the appointment. Show the same soft, non-PHI expired-link notice the
                // redeem path uses for a stale intent.
                ShowExpiredNotice();
                break;

            default:
                System.Diagnostics.Debug.WriteLine($"[DeepLink] Unsupported deep link (ignored): {uri}");
                break;
        }
    }

    /// <summary>
    /// Redeems a launch intent and, on success, shows the affirmative
    /// "Start session with [Patient Name]?" confirmation. A <c>410</c> (already
    /// redeemed via the other path, expired, or unknown) surfaces as a soft,
    /// non-PHI "link expired" notice rather than an error. Auth failures route
    /// through the existing 401 sign-out handling in <see cref="APIClient"/>.
    /// </summary>
    private async Task RedeemAndConfirmAsync(string intentId)
    {
        RedeemLaunchIntentResponse redeemed;
        try
        {
            redeemed = await _apiClient.RedeemLaunchIntentAsync(intentId);
        }
        catch (PabloException ex) when (ex.StatusCode == 410)
        {
            ShowExpiredNotice();
            return;
        }
        catch (PabloException ex)
        {
            // 401/403 already drive sign-out via UnauthenticatedDetected; for
            // anything else, fail soft without leaking detail.
            App.LogException("RedeemLaunchIntentAsync", ex);
            return;
        }
        catch (Exception ex)
        {
            App.LogException("RedeemLaunchIntentAsync", ex);
            return;
        }

        ShowConfirmation(redeemed.AppointmentId, redeemed.PatientName);
    }

    private void ShowConfirmation(string appointmentId, string? patientName)
    {
        var window = new SessionConfirmationWindow(
            appointmentId,
            patientName,
            StartSessionFromConfirmation);
        window.Activate();
    }

    private void ShowExpiredNotice()
    {
        var window = new SessionConfirmationWindow(
            "This link has expired. Start again from your web dashboard.");
        window.Activate();
    }

    /// <summary>
    /// Invoked from the confirmation window's Start Recording tap — the consent gate.
    /// Starts the session via the same path the in-app day view uses, so the mic
    /// arms only here. In native-dashboard mode we also surface the day view so the
    /// recording banner is visible.
    /// </summary>
    private void StartSessionFromConfirmation(string appointmentId)
    {
        if (EnableNativeDashboard)
        {
            ContentFrame.Navigate(typeof(DayPage), new DayPage.StartFromAppointmentArgs(appointmentId));
            NavView.SelectedItem = NavView.MenuItems[0];
            return;
        }

        // Minimal shell: no day view in the frame. Drive the recording pipeline
        // directly (the recording itself lives in RecordingViewModel, not the UI),
        // and surface the live controls in an ephemeral recording window so the user
        // can see the duration/levels and Stop / End Session.
        _ = StartSessionDirectAsync(appointmentId);
    }

    private async Task StartSessionDirectAsync(string appointmentId)
    {
        var sessionVm = App.Services.GetRequiredService<SessionViewModel>();
        var session = await sessionVm.StartSessionFromAppointmentAsync(appointmentId);
        if (session is null) return;
        await sessionVm.StartSessionAsync(session.Id);

        // Only show the recording surface once the mic is actually live. The window
        // hosts the same controls the day view uses and closes itself when recording
        // returns to Idle (End Session / sign-out).
        var recordingVm = App.Services.GetRequiredService<RecordingViewModel>();
        if (recordingVm.State == Models.RecordingUIState.Idle) return;
        new RecordingWindow().Activate();
    }

    private void NavView_SelectionChanged(NavigationView sender, NavigationViewSelectionChangedEventArgs args)
    {
        if (args.SelectedItem is NavigationViewItem item)
        {
            var tag = item.Tag?.ToString();
            var pageType = tag switch
            {
                "DayPage" => typeof(DayPage),
                "SessionHistoryPage" => typeof(SessionHistoryPage),
                "PatientListPage" => typeof(PatientListPage),
                "PracticeTopicPage" => typeof(PracticeTopicPage),
                "SettingsPage" => typeof(SettingsPage),
                _ => null,
            };

            if (pageType != null)
            {
                ContentFrame.Navigate(pageType);
            }
        }
    }
}
