using System.Runtime.InteropServices;
using System.Text;
using Microsoft.Extensions.DependencyInjection;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;
using PabloCompanion.ViewModels;

namespace PabloCompanion.Views;

public sealed partial class MainWindow : Window
{
    [DllImport("user32.dll")]
    private static extern uint GetDpiForWindow(IntPtr hwnd);

    private const int WM_COPYDATA = 0x004A;
    private const int GWLP_WNDPROC = -4;

    private delegate IntPtr WndProcDelegate(IntPtr hWnd, int msg, IntPtr wParam, IntPtr lParam);

    [DllImport("user32.dll")]
    private static extern IntPtr SetWindowLongPtr(IntPtr hWnd, int nIndex, IntPtr dwNewLong);

    [DllImport("user32.dll")]
    private static extern IntPtr CallWindowProc(IntPtr lpPrevWndFunc, IntPtr hWnd, int msg, IntPtr wParam, IntPtr lParam);

    [StructLayout(LayoutKind.Sequential)]
    private struct COPYDATASTRUCT
    {
        public IntPtr dwData;
        public int cbData;
        public IntPtr lpData;
    }

    private readonly AuthViewModel _authVm;
    private IntPtr _hwnd;
    private IntPtr _originalWndProc;
    private WndProcDelegate? _wndProcDelegate; // prevent GC

    public MainWindow()
    {
        InitializeComponent();

        _hwnd = WinRT.Interop.WindowNative.GetWindowHandle(this);

        // WinUI 3 AppWindow.Resize uses physical pixels, so scale for DPI
        var dpi = GetDpiForWindow(_hwnd);
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

        // Subclass the window to receive WM_COPYDATA from second instances
        _wndProcDelegate = new WndProcDelegate(WndProc);
        _originalWndProc = SetWindowLongPtr(_hwnd, GWLP_WNDPROC,
            Marshal.GetFunctionPointerForDelegate(_wndProcDelegate));

        _authVm = App.Services.GetRequiredService<AuthViewModel>();
        _authVm.PropertyChanged += AuthVm_PropertyChanged;

        _ = InitAsync();
    }

    private IntPtr WndProc(IntPtr hWnd, int msg, IntPtr wParam, IntPtr lParam)
    {
        if (msg == WM_COPYDATA)
        {
            try
            {
                var cds = Marshal.PtrToStructure<COPYDATASTRUCT>(lParam);
                if (cds.dwData == (IntPtr)0x5041424C && cds.cbData > 0) // "PABL" magic
                {
                    var bytes = new byte[cds.cbData];
                    Marshal.Copy(cds.lpData, bytes, 0, cds.cbData);
                    var uriString = Encoding.UTF8.GetString(bytes);

                    if (Uri.TryCreate(uriString, UriKind.Absolute, out var uri))
                    {
                        DispatcherQueue.TryEnqueue(() =>
                        {
                            App.HandleProtocolActivationStatic(uri);
                        });
                    }
                    return (IntPtr)1; // handled
                }
            }
            catch { }
        }

        return CallWindowProc(_originalWndProc, hWnd, msg, wParam, lParam);
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
