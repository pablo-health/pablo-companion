using System.Runtime.InteropServices;
using System.Web;
using Microsoft.Extensions.DependencyInjection;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;
using PabloCompanion.Services;
using PabloCompanion.ViewModels;

namespace PabloCompanion.Views;

public sealed partial class MainWindow : Window
{
    [DllImport("user32.dll")]
    private static extern uint GetDpiForWindow(IntPtr hwnd);

    private readonly AuthViewModel _authVm;
    private readonly SubscriptionViewModel _subscriptionVm;
    private readonly DeepLinkRouter _deepLinks;

    public MainWindow()
    {
        InitializeComponent();

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
            NavView.Visibility = Visibility.Visible;

            // Pre-load patient cache (matching macOS pattern)
            var patientVm = App.Services.GetRequiredService<PatientViewModel>();
            _ = patientVm.LoadPatientsAsync();

            // Fetch subscription status and start polling
            _ = _subscriptionVm.RefreshStatusAsync();
            _subscriptionVm.StartPolling();

            if (ContentFrame.Content == null)
            {
                ContentFrame.Navigate(typeof(DayPage));
                NavView.SelectedItem = NavView.MenuItems[0];
            }

            TryDrainDeepLink();
        }
        else
        {
            LoginPage.Visibility = Visibility.Visible;
            NavView.Visibility = Visibility.Collapsed;
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

        if (string.Equals(uri.Host, "session", StringComparison.OrdinalIgnoreCase) &&
            string.Equals(uri.AbsolutePath.Trim('/'), "start", StringComparison.OrdinalIgnoreCase))
        {
            var appointmentId = HttpUtility.ParseQueryString(uri.Query).Get("appointment");
            if (string.IsNullOrEmpty(appointmentId))
            {
                System.Diagnostics.Debug.WriteLine($"[DeepLink] session/start without appointment param (deferred): {uri}");
                return;
            }

            ContentFrame.Navigate(typeof(DayPage), new DayPage.StartFromAppointmentArgs(appointmentId));
            NavView.SelectedItem = NavView.MenuItems[0];
            return;
        }

        System.Diagnostics.Debug.WriteLine($"[DeepLink] Unsupported deep link (deferred): {uri}");
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
