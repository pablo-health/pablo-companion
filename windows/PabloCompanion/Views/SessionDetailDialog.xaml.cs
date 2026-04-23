using Microsoft.Extensions.DependencyInjection;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Xaml.Input;
using PabloCompanion.Helpers;
using PabloCompanion.Services;
using PabloCompanion.ViewModels;
using PabloCompanion.Models;

namespace PabloCompanion.Views;

public sealed partial class SessionDetailDialog : ContentDialog
{
    private readonly Session _session;
    private readonly Patient[]? _cachedPatients;
    private readonly TranscriptionViewModel _transcriptionVm;
    private readonly PlaybackService _playbackService;
    private readonly SessionRecordingStore _recordingStore;
    private DispatcherTimer? _positionTimer;
    private bool _isSeeking;

    public SessionDetailDialog(Session session, Patient[]? cachedPatients = null)
    {
        InitializeComponent();
        _session = session;
        _cachedPatients = cachedPatients;
        _transcriptionVm = App.Services.GetRequiredService<TranscriptionViewModel>();
        _playbackService = App.Services.GetRequiredService<PlaybackService>();
        _recordingStore = App.Services.GetRequiredService<SessionRecordingStore>();
        PopulateDetails();
    }

    private void PopulateDetails()
    {
        PatientNameText.Text = SessionFormatting.FormatPatientName(_session, _cachedPatients);
        InitialsText.Text = SessionFormatting.GetPatientInitials(_session, _cachedPatients);
        DateText.Text = SessionFormatting.FormatDate(_session);
        Badge.Status = _session.Status;

        TimeText.Text = SessionFormatting.FormatTime(_session);
        DurationText.Text = SessionFormatting.FormatDuration(_session);
        TypeText.Text = SessionFormatting.FormatSessionType(_session);

        var platform = SessionFormatting.GetPlatformName(_session);
        if (!string.IsNullOrEmpty(platform))
        {
            PlatformLabel.Visibility = Visibility.Visible;
            PlatformText.Visibility = Visibility.Visible;
            PlatformText.Text = platform;
        }

        if (!string.IsNullOrWhiteSpace(_session.Notes))
        {
            NotesLabel.Visibility = Visibility.Visible;
            NotesText.Visibility = Visibility.Visible;
            NotesText.Text = _session.Notes;
        }

        // Recording status + playback
        var recording = _recordingStore.Get(_session.Id);
        var hasLocalRecording = recording != null && File.Exists(recording.FilePath);

        if (hasLocalRecording)
        {
            RecordingText.Text = _session.Status switch
            {
                SessionStatus.InProgress => "Recording in progress...",
                _ => "Local recording available",
            };

            if (_session.Status != SessionStatus.InProgress)
            {
                PlaybackControls.Visibility = Visibility.Visible;
            }
        }
        else
        {
            RecordingText.Text = _session.Status switch
            {
                SessionStatus.InProgress => "Recording in progress...",
                SessionStatus.Finalized => "Available on Pablo",
                _ => "No recording available",
            };
        }

        // Transcript — server-side only
        if (_session.Status == SessionStatus.Finalized ||
            _session.Status == SessionStatus.PendingReview)
        {
            TranscriptSection.Visibility = Visibility.Visible;
            TranscriptPreviewText.Text = "Transcript available on Pablo";
            ViewTranscriptButton.Visibility = Visibility.Collapsed;
        }

        // Cloud upload status — only shown while an upload is still in flight
        // or waiting to retry for this specific session.
        var pendingState = _transcriptionVm.GetSessionTranscriptionState(_session.Id);
        if (pendingState == TranscriptionState.PendingUpload)
        {
            UploadStatusSection.Visibility = Visibility.Visible;
            PendingUploadBadge.Visibility = Visibility.Visible;
            UploadStatusText.Text = "Audio hasn't uploaded yet — Pablo will keep trying.";
            RetryUploadButton.Visibility = Visibility.Visible;
        }
    }

    private async void PlayPause_Click(object sender, RoutedEventArgs e)
    {
        if (_playbackService.IsPlaying && _playbackService.PlayingSessionId == _session.Id)
        {
            _playbackService.Pause();
            UpdatePlaybackUI();
            return;
        }

        if (_playbackService.IsPaused && _playbackService.PlayingSessionId == _session.Id)
        {
            _playbackService.Resume();
            StartPositionTimer();
            UpdatePlaybackUI();
            return;
        }

        var recording = _recordingStore.Get(_session.Id);
        if (recording == null) return;

        PlayPauseButton.IsEnabled = false;
        try
        {
            await _playbackService.PlayAsync(recording, _session.Id);
            _playbackService.PlaybackEnded += OnPlaybackEnded;
            StartPositionTimer();
            UpdatePlaybackUI();
            StopButton.IsEnabled = true;
        }
        catch (Exception ex)
        {
            RecordingText.Text = $"Playback error: {ex.Message}";
        }
        finally
        {
            PlayPauseButton.IsEnabled = true;
        }
    }

    private void Stop_Click(object sender, RoutedEventArgs e) => StopPlayback();

    private void StopPlayback()
    {
        _playbackService.PlaybackEnded -= OnPlaybackEnded;
        _playbackService.Stop();
        StopPositionTimer();
        UpdatePlaybackUI();
        PositionSlider.Value = 0;
        PositionText.Text = "0:00 / 0:00";
        StopButton.IsEnabled = false;
    }

    private void OnPlaybackEnded(object? sender, EventArgs e)
    {
        DispatcherQueue.TryEnqueue(() =>
        {
            StopPositionTimer();
            UpdatePlaybackUI();
            StopButton.IsEnabled = false;
        });
    }

    private void StartPositionTimer()
    {
        _positionTimer?.Stop();
        _positionTimer = new DispatcherTimer { Interval = TimeSpan.FromMilliseconds(200) };
        _positionTimer.Tick += PositionTimer_Tick;
        _positionTimer.Start();
    }

    private void StopPositionTimer()
    {
        _positionTimer?.Stop();
        _positionTimer = null;
    }

    private void PositionTimer_Tick(object? sender, object e)
    {
        if (_isSeeking || !_playbackService.IsActive) return;

        var pos = _playbackService.Position;
        var dur = _playbackService.Duration;

        if (dur.TotalSeconds > 0)
        {
            PositionSlider.Maximum = dur.TotalSeconds;
            PositionSlider.Value = pos.TotalSeconds;
        }

        PositionText.Text = $"{FormatTime(pos)} / {FormatTime(dur)}";
    }

    private void PositionSlider_PointerPressed(object sender, PointerRoutedEventArgs e)
    {
        _isSeeking = true;
    }

    private void PositionSlider_PointerReleased(object sender, PointerRoutedEventArgs e)
    {
        _isSeeking = false;
        if (_playbackService.IsActive)
        {
            _playbackService.Seek(TimeSpan.FromSeconds(PositionSlider.Value));
        }
    }

    private void UpdatePlaybackUI()
    {
        PlayPauseIcon.Symbol = _playbackService.IsPlaying ? Symbol.Pause : Symbol.Play;
    }

    private static string FormatTime(TimeSpan ts)
    {
        return ts.Hours > 0
            ? $"{ts.Hours}:{ts.Minutes:D2}:{ts.Seconds:D2}"
            : $"{ts.Minutes}:{ts.Seconds:D2}";
    }

    private async void RetryUpload_Click(object sender, RoutedEventArgs e)
    {
        RetryUploadButton.IsEnabled = false;
        RetryUploadButton.Content = "Uploading...";

        try
        {
            await _transcriptionVm.ForceRetryPendingUploadsAsync();

            if (_transcriptionVm.GetSessionTranscriptionState(_session.Id) != TranscriptionState.PendingUpload)
            {
                PendingUploadBadge.Visibility = Visibility.Collapsed;
                RetryUploadButton.Visibility = Visibility.Collapsed;
                UploadStatusText.Text = "Uploaded";
            }
            else
            {
                UploadStatusText.Text = _transcriptionVm.ErrorMessage ?? "Still not reachable — will retry.";
            }
        }
        finally
        {
            RetryUploadButton.Content = "Retry Upload";
            RetryUploadButton.IsEnabled = true;
        }
    }

    private void ViewTranscript_Click(object sender, RoutedEventArgs e)
    {
        // Server-side transcript — placeholder
    }

    private void Dialog_Closing(ContentDialog sender, ContentDialogClosingEventArgs args)
    {
        StopPositionTimer();

        if (_playbackService.PlayingSessionId == _session.Id)
        {
            _playbackService.PlaybackEnded -= OnPlaybackEnded;
            _playbackService.Stop();
        }
    }
}
