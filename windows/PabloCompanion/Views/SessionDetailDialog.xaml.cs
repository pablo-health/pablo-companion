using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;
using PabloCompanion.Helpers;
using uniffi.pablo_core;

namespace PabloCompanion.Views;

public sealed partial class SessionDetailDialog : ContentDialog
{
    private readonly Session _session;

    public SessionDetailDialog(Session session)
    {
        InitializeComponent();
        _session = session;
        PopulateDetails();
    }

    private void PopulateDetails()
    {
        // Patient header
        PatientNameText.Text = SessionFormatting.FormatPatientName(_session);
        InitialsText.Text = SessionFormatting.GetPatientInitials(_session);
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
    }

    private void ViewTranscript_Click(object sender, RoutedEventArgs e)
    {
        // Will be wired in Phase 3 when transcript data is available
    }
}
