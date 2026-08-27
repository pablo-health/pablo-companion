using Microsoft.Extensions.DependencyInjection;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;
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
    private readonly SessionRecordingStore _recordingStore;

    public SessionDetailDialog(Session session, Patient[]? cachedPatients = null)
    {
        InitializeComponent();
        _session = session;
        _cachedPatients = cachedPatients;
        _transcriptionVm = App.Services.GetRequiredService<TranscriptionViewModel>();
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

        // Recording status. Local audio only exists until the backend confirms the
        // upload, at which point RecordingCleaner deletes it — so its absence on a
        // finalized session is the expected end state, not a fault.
        var recording = _recordingStore.Get(_session.Id);
        var hasLocalRecording = recording != null && File.Exists(recording.FilePath);

        if (hasLocalRecording)
        {
            RecordingText.Text = _session.Status switch
            {
                SessionStatus.InProgress => "Recording in progress...",
                _ => "Local recording available",
            };
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
}
