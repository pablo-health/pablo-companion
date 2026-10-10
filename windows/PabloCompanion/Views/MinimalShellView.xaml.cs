using System.ComponentModel;
using Microsoft.Extensions.DependencyInjection;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Automation;
using Microsoft.UI.Xaml.Controls;
using PabloCompanion.Core;
using PabloCompanion.Helpers;
using PabloCompanion.Models;
using PabloCompanion.Services;
using PabloCompanion.ViewModels;

namespace PabloCompanion.Views;

/// <summary>
/// The session-first main surface: today's next appointment with Start Session
/// and the live recording controls (Pause / Resume, End Session), a
/// "Recording on another device" note, an "Open Web Dashboard" button, and a
/// footer (connection + mic status, preferences, sign-out, version).
/// Mirrors <c>MinimalMainView.swift</c>; the selection rules live in
/// <see cref="MinimalShellSelection"/>.
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
    private readonly SessionViewModel _sessionVm;
    private readonly RecordingConsentViewModel _consentVm;

    private Window? _preferencesWindow;

    public MinimalShellView()
    {
        _authVm = App.Services.GetRequiredService<AuthViewModel>();
        _credentials = App.Services.GetRequiredService<CredentialManager>();
        _recordingVm = App.Services.GetRequiredService<RecordingViewModel>();
        _sessionVm = App.Services.GetRequiredService<SessionViewModel>();
        _consentVm = App.Services.GetRequiredService<RecordingConsentViewModel>();

        InitializeComponent();

        VersionText.Text = $"Pablo Companion (Windows) v{ClientVersion}";
        Card.StartRequested += Card_StartRequested;

        _sessionVm.PropertyChanged += ViewModel_PropertyChanged;
        _recordingVm.PropertyChanged += RecordingVm_PropertyChanged;
        _consentVm.PropertyChanged += ConsentVm_PropertyChanged;
        AskPanel.Bind(_consentVm);
    }

    /// <summary>
    /// Refreshes the status block and the card. Called by <see cref="MainWindow"/>
    /// whenever the shell becomes visible (i.e. after auth restores / changes).
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
        UpdateCard();
    }

    private void ViewModel_PropertyChanged(object? sender, PropertyChangedEventArgs e)
    {
        switch (e.PropertyName)
        {
            case nameof(SessionViewModel.TodayAppointments):
            case nameof(SessionViewModel.IsLoadingAppointments):
            case nameof(SessionViewModel.AppointmentsErrorMessage):
            case nameof(SessionViewModel.StartingAppointmentId):
                DispatcherQueue.TryEnqueue(UpdateCard);
                break;
        }
    }

    private void RecordingVm_PropertyChanged(object? sender, PropertyChangedEventArgs e)
    {
        // Levels and duration tick many times a second; the banner handles those.
        if (e.PropertyName is nameof(RecordingViewModel.ActiveSessionId) or nameof(RecordingViewModel.State))
            DispatcherQueue.TryEnqueue(UpdateCard);
    }

    /// <summary>
    /// Card priority: recording, then loading, then error, then "No upcoming
    /// appointments for today". The "Recording on another device" note sits
    /// above whichever card shows.
    /// </summary>
    private void UpdateCard()
    {
        var now = DateTimeOffset.Now;
        var appointments = _sessionVm.TodayAppointments;
        var activeSessionId = _recordingVm.ActiveSessionId;
        var startingId = _sessionVm.StartingAppointmentId;

        var elsewhere = MinimalShellSelection.InProgressElsewhere(appointments, now, activeSessionId, startingId);
        ElsewhereNote.Visibility = elsewhere is null ? Visibility.Collapsed : Visibility.Visible;
        if (elsewhere is not null)
        {
            var title = string.IsNullOrEmpty(elsewhere.Title) ? "a session" : elsewhere.Title;
            ElsewhereText.Text = $"Recording on another device: {title}";
        }

        var card = MinimalShellSelection.SelectCard(
            appointments,
            now,
            activeSessionId,
            startingId,
            isLoading: _sessionVm.IsLoadingAppointments,
            hasError: _sessionVm.AppointmentsErrorMessage is not null);

        Card.Visibility = _consentVm.Prompt == ConsentPromptKind.None
            && card.Kind is ShellCardKind.Appointment or ShellCardKind.UntrackedRecording
            ? Visibility.Visible
            : Visibility.Collapsed;
        LoadingCard.Visibility = Show(card.Kind == ShellCardKind.Loading);
        ErrorCard.Visibility = Show(card.Kind == ShellCardKind.Error);
        NoUpcomingCard.Visibility = Show(card.Kind == ShellCardKind.NoUpcoming);

        if (card.Kind == ShellCardKind.Appointment && card.Appointment is { } appointment)
            Card.ShowAppointment(appointment, card.Action, now);
        else if (card.Kind == ShellCardKind.UntrackedRecording)
            Card.ShowUntrackedRecording();
    }

    private static Visibility Show(bool visible) => visible ? Visibility.Visible : Visibility.Collapsed;

    /// <summary>
    /// Start Session. The client's answer about AI-assisted notes is read first:
    /// a client who is clear (or a practice that does not ask) starts at once, as
    /// before; otherwise the prompt takes the card's place and nothing arms until
    /// the clinician chooses "Start recording and ask".
    /// </summary>
    private async void Card_StartRequested(object? sender, string appointmentId)
    {
        try
        {
            var appointment = _sessionVm.TodayAppointments.FirstOrDefault(a => a.Id == appointmentId);
            var patientId = string.IsNullOrEmpty(appointment?.PatientId) ? null : appointment.PatientId;
            // Guarded in the view models: a double-click starts one session.
            await _consentVm.RequestStartAsync(appointmentId, patientId, appointment?.ConsentModality());
        }
        catch (Exception ex)
        {
            App.LogException("MinimalShell.StartAppointmentSession", ex);
        }
    }

    private void ConsentVm_PropertyChanged(object? sender, PropertyChangedEventArgs e)
        => DispatcherQueue.TryEnqueue(UpdateConsentPrompt);

    /// <summary>Renders the before-arming prompt; the card hides while it shows.</summary>
    private void UpdateConsentPrompt()
    {
        var prompt = _consentVm.Prompt;
        ConsentPrompt.Visibility = Show(prompt != ConsentPromptKind.None);
        if (prompt == ConsentPromptKind.None)
        {
            UpdateCard();
            return;
        }
        Card.Visibility = Visibility.Collapsed;

        if (prompt == ConsentPromptKind.AskOnRecording)
        {
            ConsentPromptIcon.Glyph = "\uE897";
            ConsentPromptTitle.Text = RecordingConsentCopy.NotAskedTitle;
            ConsentPromptMessage.Text = RecordingConsentCopy.AskOnRecordingMessage;
            SetButton(ConsentPrimaryButton, RecordingConsentCopy.StartAndAsk, "PabloPrimaryButton", visible: true);
            SetButton(ConsentSecondaryButton, RecordingConsentCopy.DontRecord, "PabloSecondaryButton", visible: true);
        }
        else
        {
            ConsentPromptIcon.Glyph = "\uEC54";
            ConsentPromptTitle.Text = RecordingConsentCopy.DeclinedTitle;
            ConsentPromptMessage.Text = _consentVm.DeclinedMessage;
            SetButton(ConsentPrimaryButton, RecordingConsentCopy.OpenChart, "PabloSecondaryButton",
                visible: _consentVm.PatientId is not null);
            SetButton(ConsentSecondaryButton, RecordingConsentCopy.Close, "PabloPrimaryButton", visible: true);
        }
        AutomationProperties.SetName(ConsentPrompt, ConsentPromptTitle.Text);
    }

    private static void SetButton(Button button, string text, string styleKey, bool visible)
    {
        button.Content = text;
        button.Style = (Style)Application.Current.Resources[styleKey];
        button.Visibility = Show(visible);
        AutomationProperties.SetName(button, text);
    }

    private async void ConsentPrimary_Click(object sender, RoutedEventArgs e)
    {
        try
        {
            if (_consentVm.Prompt == ConsentPromptKind.AskOnRecording)
                await _consentVm.StartAndAskAsync();
            else if (_consentVm.PatientId is { } patientId)
                await OpenChartAsync(patientId);
        }
        catch (Exception ex)
        {
            App.LogException("MinimalShell.ConsentPrimary", ex);
        }
    }

    private void ConsentSecondary_Click(object sender, RoutedEventArgs e) => _consentVm.DismissPrompt();

    /// <summary>
    /// The client's chart in the web app, where a declined answer can be changed.
    /// The same URL the Mac declined prompt opens: the dashboard's patient page.
    /// </summary>
    private async Task OpenChartAsync(string patientId)
    {
        var url = $"{DashboardBaseUrl().TrimEnd('/')}/dashboard/patients/{Uri.EscapeDataString(patientId)}";
        _consentVm.DismissPrompt();
        if (!Uri.TryCreate(url, UriKind.Absolute, out var uri)) return;
        await Windows.System.Launcher.LaunchUriAsync(uri);
    }

    private async void TryAgain_Click(object sender, RoutedEventArgs e)
    {
        await _sessionVm.LoadTodayAppointmentsAsync();
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
