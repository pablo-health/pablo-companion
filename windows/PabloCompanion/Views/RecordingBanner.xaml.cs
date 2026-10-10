using Microsoft.Extensions.DependencyInjection;
using Microsoft.UI;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Automation;
using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Xaml.Media;
using PabloCompanion.Helpers;
using PabloCompanion.Models;
using PabloCompanion.ViewModels;

namespace PabloCompanion.Views;

/// <summary>
/// Live recording controls: capture state, duration, levels, Pause / Resume and
/// End Session. Hosted by the minimal window's appointment card (and the day
/// view in the native dashboard). Mirrors the recording panel in
/// <c>MinimalMainView.swift</c>.
/// </summary>
public sealed partial class RecordingBanner : UserControl
{
    private readonly RecordingViewModel _vm;
    private string? _sessionTitle;
    private bool _isEnding;

    public RecordingBanner()
    {
        InitializeComponent();
        _vm = App.Services.GetRequiredService<RecordingViewModel>();
        _vm.PropertyChanged += Vm_PropertyChanged;
        UpdateUI();
    }

    /// <summary>Appointment title for the End Session accessibility label, when known.</summary>
    public string? SessionTitle
    {
        get => _sessionTitle;
        set
        {
            _sessionTitle = value;
            UpdateUI();
        }
    }

    private void Vm_PropertyChanged(object? sender, System.ComponentModel.PropertyChangedEventArgs e)
    {
        DispatcherQueue.TryEnqueue(UpdateUI);
    }

    private void UpdateUI()
    {
        // Visibility managed by the parent.
        var state = _vm.State;
        var isPaused = state == RecordingUIState.Paused;
        var stopped = state == RecordingUIState.Idle;

        StatusText.Text = MinimalShellSelection.CaptureStateLabel(state);
        RecordingDot.Fill = stopped
            ? (Brush)Application.Current.Resources["PabloError"]
            : isPaused
                ? new SolidColorBrush(Colors.Yellow)
                : new SolidColorBrush(Colors.White);

        BannerBorder.Background = isPaused
            ? new SolidColorBrush(Windows.UI.Color.FromArgb(255, 180, 160, 80))
            : (Brush)Application.Current.Resources["PabloSage"];

        // Duration. Screen readers read "00:12:34" as a time of day; spell it out.
        var ts = TimeSpan.FromSeconds(_vm.Duration);
        DurationText.Text = ts.ToString(@"hh\:mm\:ss");
        AutomationProperties.SetName(DurationText,
            $"{(int)ts.TotalMinutes} minutes {ts.Seconds} seconds elapsed");

        // Volume meters
        MicMeter.Level = _vm.MicLevel;
        SysMeter.Level = _vm.SystemLevel;

        // System audio indicator
        SystemAudioDot.Fill = _vm.SystemAudioActive
            ? new SolidColorBrush(Colors.LimeGreen)
            : new SolidColorBrush(Windows.UI.Color.FromArgb(128, 255, 255, 255));

        // Pause means nothing once capture has stopped.
        PauseResumeButton.Visibility = stopped ? Visibility.Collapsed : Visibility.Visible;
        PauseResumeButton.Content = isPaused ? "Resume" : "Pause";
        AutomationProperties.SetName(PauseResumeButton, isPaused ? "Resume recording" : "Pause recording");

        EndSessionButton.IsEnabled = !_isEnding;
        AutomationProperties.SetName(EndSessionButton,
            _sessionTitle is { Length: > 0 } title ? $"End session for {title}" : "End session");
    }

    private void PauseResumeButton_Click(object sender, RoutedEventArgs e)
    {
        if (_vm.State == RecordingUIState.Paused) _vm.ResumeRecording();
        else _vm.PauseRecording();
    }

    private async void EndSessionButton_Click(object sender, RoutedEventArgs e)
    {
        if (_isEnding || _vm.ActiveSessionId is not { } sessionId) return;
        _isEnding = true;
        UpdateUI();
        try
        {
            var sessionVm = App.Services.GetRequiredService<SessionViewModel>();
            await sessionVm.EndSessionAndRefreshAsync(sessionId);
        }
        catch (Exception ex)
        {
            App.LogException("RecordingBanner.EndSession", ex);
        }
        finally
        {
            _isEnding = false;
            UpdateUI();
        }
    }
}
