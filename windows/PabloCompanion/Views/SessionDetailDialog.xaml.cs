using Microsoft.Extensions.DependencyInjection;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;
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

    public SessionDetailDialog(Session session, Patient[]? cachedPatients = null)
    {
        InitializeComponent();
        _session = session;
        _cachedPatients = cachedPatients;
        _transcriptionVm = App.Services.GetRequiredService<TranscriptionViewModel>();
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

        // Recording status
        RecordingText.Text = _session.Status switch
        {
            SessionStatus.InProgress => "Recording in progress...",
            SessionStatus.RecordingComplete or SessionStatus.Queued or SessionStatus.Processing =>
                "Recording playback coming soon",
            SessionStatus.Finalized => "Available on Pablo",
            _ => "No recording available",
        };

        // Transcript section — show placeholder for finalized sessions
        if (_session.Status == SessionStatus.Finalized ||
            _session.Status == SessionStatus.PendingReview)
        {
            TranscriptSection.Visibility = Visibility.Visible;
            TranscriptPreviewText.Text = "Transcript available on Pablo";
            ViewTranscriptButton.Visibility = Visibility.Collapsed;
        }

        // Local transcription — show when we have a local recording
        var recordingStore = App.Services.GetRequiredService<SessionRecordingStore>();
        var recording = recordingStore.Get(_session.Id);
        if (recording?.MicPcmFilePath != null)
        {
            LocalTranscriptSection.Visibility = Visibility.Visible;

            // Check if transcript already exists
            var existingTranscript = _transcriptionVm.GetTranscript(_session.Id);
            if (existingTranscript != null)
            {
                ShowLocalTranscript(existingTranscript);
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

    private async void Transcribe_Click(object sender, RoutedEventArgs e)
    {
        // Get selected quality
        if (QualityDropdown.SelectedItem is ComboBoxItem item && item.Tag is string presetStr)
        {
            if (Enum.TryParse<QualityPreset>(presetStr, out var preset))
                _transcriptionVm.QualityPreset = preset;
        }

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
}
