using System.Runtime.InteropServices;
using Microsoft.Extensions.DependencyInjection;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;
using PabloCompanion.ViewModels;

namespace PabloCompanion.Views;

public sealed partial class MainWindow : Window
{
    [DllImport("user32.dll")]
    private static extern uint GetDpiForWindow(IntPtr hwnd);

    private readonly AuthViewModel _authVm;

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

        _ = InitAsync();
    }

    private async Task InitAsync()
    {
        try
        {
            await _authVm.TryRestoreSessionAsync();
        }
        catch (Exception)
        {
            // Prevent unhandled exceptions from fire-and-forget startup initialization.
            // Keep default unauthenticated UI state when restore fails.
        }

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
            _ = PreloadPatientsAsync(patientVm);

            if (ContentFrame.Content == null)
            {
                ContentFrame.Navigate(typeof(DayPage));
                NavView.SelectedItem = NavView.MenuItems[0];
            }
        }
        else
        {
            LoginPage.Visibility = Visibility.Visible;
            NavView.Visibility = Visibility.Collapsed;
        }
    }

    private async Task PreloadPatientsAsync(PatientViewModel patientVm)
    {
        try
        {
            await patientVm.LoadPatientsAsync();
        }
        catch (Exception ex)
        {
            // Debug-only diagnostic — not a support log. Log only the exception type
            // to avoid any risk of PHI appearing in log output (e.g. from HTTP response
            // bodies embedded in inner exception messages).
            System.Diagnostics.Debug.WriteLine($"Failed to preload patients: {ex.GetType().Name}");
        }
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
