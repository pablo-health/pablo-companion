using System.Runtime.InteropServices;
using Microsoft.Extensions.DependencyInjection;
using Microsoft.UI.Xaml;
using PabloCompanion.Models;
using PabloCompanion.ViewModels;

namespace PabloCompanion.Views;

/// <summary>
/// Ephemeral window that surfaces the live recording controls (duration, levels,
/// Stop / End Session) after the user confirms a handoff. In minimal-shell mode the
/// day view is never shown, so without this window a redeemed session would arm the
/// mic with no on-screen indicator and no way to stop short of signing out.
///
/// Hosts the same <see cref="RecordingBanner"/> the day view uses, so Stop / End
/// Session behave identically. The window dismisses itself when the recording
/// returns to <see cref="RecordingUIState.Idle"/> (session ended, or data cleared on
/// sign-out), matching the design's "ephemeral window, closed when the session ends."
/// </summary>
public sealed partial class RecordingWindow : Window
{
    [DllImport("user32.dll")]
    private static extern uint GetDpiForWindow(IntPtr hwnd);

    private readonly RecordingViewModel _recordingVm;

    public RecordingWindow()
    {
        InitializeComponent();

        _recordingVm = App.Services.GetRequiredService<RecordingViewModel>();
        _recordingVm.PropertyChanged += RecordingVm_PropertyChanged;

        // Close when the window is dismissed so we don't leak the subscription.
        Closed += (_, _) => _recordingVm.PropertyChanged -= RecordingVm_PropertyChanged;

        ConfigureWindowChrome();
    }

    private void RecordingVm_PropertyChanged(object? sender, System.ComponentModel.PropertyChangedEventArgs e)
    {
        if (e.PropertyName != nameof(RecordingViewModel.State)) return;

        // Recording ended (End Session) or was cleared (sign-out) → tear down.
        if (_recordingVm.State == RecordingUIState.Idle)
        {
            DispatcherQueue.TryEnqueue(Close);
        }
    }

    private void ConfigureWindowChrome()
    {
        var hwnd = WinRT.Interop.WindowNative.GetWindowHandle(this);

        // AppWindow.Resize uses physical pixels — scale for DPI (matches MainWindow).
        var dpi = GetDpiForWindow(hwnd);
        var scale = dpi / 96.0;
        var appWindow = this.AppWindow;
        appWindow.Resize(new Windows.Graphics.SizeInt32(
            (int)(720 * scale),
            (int)(200 * scale)));

        if (appWindow.Presenter is Microsoft.UI.Windowing.OverlappedPresenter presenter)
        {
            presenter.IsResizable = false;
            presenter.IsMaximizable = false;
            presenter.IsMinimizable = true;
        }
    }
}
