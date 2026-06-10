using System.Runtime.InteropServices;
using Microsoft.UI.Xaml;

namespace PabloCompanion.Views;

/// <summary>
/// Ephemeral "Start session with [Patient Name]?" confirmation window shown after
/// a launch intent is redeemed (verified deep link or legacy-scheme fallback).
///
/// Security-critical consent gate: the microphone MUST NOT arm until the therapist
/// taps <c>Start Recording</c>. This window does no recording itself — on confirm
/// it invokes <see cref="_onConfirm"/> with the redeemed appointment id, and the
/// caller drives the existing (mic-arming) session-start path. Closing or
/// cancelling arms nothing.
/// </summary>
public sealed partial class SessionConfirmationWindow : Window
{
    [DllImport("user32.dll")]
    private static extern uint GetDpiForWindow(IntPtr hwnd);

    private readonly string? _appointmentId;
    private readonly Action<string>? _onConfirm;
    private bool _confirmed;

    /// <param name="appointmentId">The redeemed appointment id to start a session for.</param>
    /// <param name="patientName">
    /// Patient display name from the redeem response (PHI). Shown once here and never
    /// persisted. Null when the backend could not resolve the patient — we fall back
    /// to a generic prompt rather than show a blank name.
    /// </param>
    /// <param name="onConfirm">
    /// Invoked with <paramref name="appointmentId"/> when the therapist taps
    /// Start Recording. The caller is responsible for actually arming the mic /
    /// starting the session (reusing the proven session-start path).
    /// </param>
    public SessionConfirmationWindow(string appointmentId, string? patientName, Action<string> onConfirm)
    {
        _appointmentId = appointmentId;
        _onConfirm = onConfirm;

        InitializeComponent();

        HeadingText.Text = "Start a session?";
        PromptText.Text = string.IsNullOrWhiteSpace(patientName)
            ? "Start a recorded session for this appointment?"
            : $"Start session with {patientName}?";

        ConfigureWindowChrome();
    }

    /// <summary>
    /// Error variant: shown when a redeem fails (e.g. <c>410 Gone</c> — the link was
    /// already used via the other path, expired, or is unknown). Carries no PHI and
    /// offers only a dismiss action — no Start Recording, so nothing can arm the mic.
    /// </summary>
    /// <param name="message">A non-PHI, user-facing explanation.</param>
    public SessionConfirmationWindow(string message)
    {
        _appointmentId = null;
        _onConfirm = null;

        InitializeComponent();

        HeadingText.Text = "Link expired";
        PromptText.Text = message;
        ConsentHint.Visibility = Visibility.Collapsed;
        StartRecordingButton.Visibility = Visibility.Collapsed;
        DismissButton.Content = "Close";

        ConfigureWindowChrome();
    }

    private void ConfigureWindowChrome()
    {
        var hwnd = WinRT.Interop.WindowNative.GetWindowHandle(this);

        // AppWindow.Resize uses physical pixels — scale for DPI (matches MainWindow).
        var dpi = GetDpiForWindow(hwnd);
        var scale = dpi / 96.0;
        var appWindow = this.AppWindow;
        appWindow.Resize(new Windows.Graphics.SizeInt32(
            (int)(460 * scale),
            (int)(360 * scale)));

        if (appWindow.Presenter is Microsoft.UI.Windowing.OverlappedPresenter presenter)
        {
            presenter.IsResizable = false;
            presenter.IsMaximizable = false;
            presenter.IsMinimizable = false;
        }
    }

    private void StartRecording_Click(object sender, RoutedEventArgs e)
    {
        // Error variant has no appointment / callback — nothing to start.
        if (_appointmentId is null || _onConfirm is null) return;

        // Guard against a double-tap re-firing the start path after we begin closing.
        if (_confirmed) return;
        _confirmed = true;

        // Disable so the button can't be hit again before the window tears down.
        StartRecordingButton.IsEnabled = false;

        _onConfirm(_appointmentId);
        Close();
    }

    private void Cancel_Click(object sender, RoutedEventArgs e) => Close();
}
