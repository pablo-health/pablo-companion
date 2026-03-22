using Microsoft.Extensions.DependencyInjection;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Xaml.Input;
using PabloCompanion.Helpers;
using PabloCompanion.Services;
using PabloCompanion.ViewModels;
using uniffi.pablo_core;
using QualityPreset = PabloCompanion.Services.QualityPreset;

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
        // Patient header
        PatientNameText.Text = SessionFormatting.FormatPatientName(_session, _cachedPatients);
        InitialsText.Text = SessionFormatting.GetPatientInitials(_session, _cachedPatients);
        DateText.Text = SessionFormatting.FormatDate(_session);
        Badge.Status = _session.Status;

        // Session info
        TimeText.Text = SessionFormatting.FormatTime(_session);
        DurationText.Text = SessionFormatting.FormatDuration(_session);
        TypeText.Text = SessionFormatting.FormatSessionType(_session);

        // Platform
        var platform = SessionFormatting.GetPlatformName(_session);
        if (!string.IsNullOrEmpty(platform))
        {
            PlatformLabel.Visibility = Visibility.Visible;
            PlatformText.Visibility = Visibility.Visible;
            PlatformText.Text = platform;
        }

        // Notes
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

        // Transcript section — show placeholder for finalized sessions
        if (_session.Status == SessionStatus.Finalized ||
            _session.Status == SessionStatus.PendingReview)
        {
            TranscriptSection.Visibility = Visibility.Visible;
            TranscriptPreviewText.Text = "Transcript available on Pablo";
            ViewTranscriptButton.Visibility = Visibility.Collapsed;
        }

        // Local transcription — show when we have a local recording with PCM sidecars
        if (recording?.MicPcmFilePath != null)
        {
            LocalTranscriptSection.Visibility = Visibility.Visible;

            // Check transcription state for this session
            var transcriptState = _transcriptionVm.GetSessionTranscriptionState(_session.Id);
            var existingTranscript = _transcriptionVm.GetTranscript(_session.Id);

            if (existingTranscript != null)
            {
                ShowLocalTranscript(existingTranscript);

                if (transcriptState == TranscriptionState.PendingUpload)
                {
                    PendingUploadBadge.Visibility = Visibility.Visible;
                    RetryUploadButton.Visibility = Visibility.Visible;
                }
            }
        }
    }

    private void ShowLocalTranscript(string transcript)
    {
        TranscribeControls.Visibility = Visibility.Collapsed;
        TranscriptionProgress.Visibility = Visibility.Collapsed;
        LocalTranscriptPreview.Visibility = Visibility.Visible;
        LocalTranscriptText.Text = transcript;
    }

    // --- Playback ---

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

        // Start new playback
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

    private void Stop_Click(object sender, RoutedEventArgs e)
    {
        StopPlayback();
    }

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
        if (_playbackService.IsPlaying)
        {
            PlayPauseIcon.Symbol = Symbol.Pause;
        }
        else
        {
            PlayPauseIcon.Symbol = Symbol.Play;
        }
    }

    private static string FormatTime(TimeSpan ts)
    {
        return ts.Hours > 0
            ? $"{ts.Hours}:{ts.Minutes:D2}:{ts.Seconds:D2}"
            : $"{ts.Minutes}:{ts.Seconds:D2}";
    }

    // --- Transcription ---

    private async void Transcribe_Click(object sender, RoutedEventArgs e)
    {
        // Get selected quality
        if (QualityDropdown.SelectedItem is ComboBoxItem item && item.Tag is string presetStr)
        {
            if (Enum.TryParse<QualityPreset>(presetStr, out var preset))
                _transcriptionVm.QualityPreset = preset;
        }

        // Add to pending store for resiliency
        var pendingStore = App.Services.GetRequiredService<PendingTranscriptionStore>();
        pendingStore.Add(_session.Id, _transcriptionVm.QualityPreset);

        TranscribeControls.Visibility = Visibility.Collapsed;
        TranscriptionProgress.Visibility = Visibility.Visible;

        _transcriptionVm.PropertyChanged += TranscriptionVm_PropertyChanged;

        try
        {
            await _transcriptionVm.TranscribeSessionAsync(_session.Id);

            if (_transcriptionVm.State == TranscriptionState.Complete && _transcriptionVm.TranscriptText != null)
            {
                ShowLocalTranscript(_transcriptionVm.TranscriptText);
            }
            else if (_transcriptionVm.State == TranscriptionState.PendingUpload && _transcriptionVm.TranscriptText != null)
            {
                ShowLocalTranscript(_transcriptionVm.TranscriptText);
                PendingUploadBadge.Visibility = Visibility.Visible;
                RetryUploadButton.Visibility = Visibility.Visible;
            }
            else if (_transcriptionVm.State == TranscriptionState.Error)
            {
                TranscriptionStatusText.Text = $"Error: {_transcriptionVm.ErrorMessage}";
                TranscribeControls.Visibility = Visibility.Visible;
            }
        }
        finally
        {
            _transcriptionVm.PropertyChanged -= TranscriptionVm_PropertyChanged;
        }
    }

    private void TranscriptionVm_PropertyChanged(object? sender, System.ComponentModel.PropertyChangedEventArgs e)
    {
        DispatcherQueue.TryEnqueue(() =>
        {
            TranscriptionProgressBar.Value = _transcriptionVm.Progress * 100;
            TranscriptionStatusText.Text = _transcriptionVm.ProgressMessage;
        });
    }

    private async void RetryUpload_Click(object sender, RoutedEventArgs e)
    {
        RetryUploadButton.IsEnabled = false;
        RetryUploadButton.Content = "Uploading...";

        try
        {
            await _transcriptionVm.ForceRetryPendingUploadsAsync();

            var state = _transcriptionVm.GetSessionTranscriptionState(_session.Id);
            if (state == TranscriptionState.Complete)
            {
                PendingUploadBadge.Visibility = Visibility.Collapsed;
                RetryUploadButton.Visibility = Visibility.Collapsed;
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

    private async void ViewLocalTranscript_Click(object sender, RoutedEventArgs e)
    {
        var transcript = _transcriptionVm.GetTranscript(_session.Id);
        if (transcript == null) return;

        var viewer = new TranscriptViewerDialog(transcript)
        {
            XamlRoot = XamlRoot,
        };

        // Close this dialog first, then show transcript viewer
        Hide();
        await viewer.ShowAsync();
    }

    private void Dialog_Closing(ContentDialog sender, ContentDialogClosingEventArgs args)
    {
        StopPositionTimer();

        // Stop playback when dialog closes
        if (_playbackService.PlayingSessionId == _session.Id)
        {
            _playbackService.PlaybackEnded -= OnPlaybackEnded;
            _playbackService.Stop();
        }
    }
}
