using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Automation;
using Microsoft.UI.Xaml.Controls;
using PabloCompanion.Helpers;
using PabloCompanion.Models;

namespace PabloCompanion.Views;

/// <summary>
/// The appointment card in <see cref="MinimalShellView"/>. Purely presentational:
/// the shell decides what to show (<see cref="MinimalShellSelection.SelectCard"/>)
/// and handles Start Session through <see cref="StartRequested"/>.
/// </summary>
public sealed partial class AppointmentCard : UserControl
{
    private Appointment? _appointment;

    public AppointmentCard()
    {
        InitializeComponent();
    }

    /// <summary>Raised when Start Session is clicked, with the appointment's id.</summary>
    public event EventHandler<string>? StartRequested;

    /// <summary>Show an appointment with the action the selection rules picked.</summary>
    public void ShowAppointment(Appointment appointment, AppointmentAction action, DateTimeOffset now)
    {
        _appointment = appointment;

        var title = string.IsNullOrEmpty(appointment.Title) ? "Upcoming appointment" : appointment.Title;
        var time = MinimalShellSelection.FormattedTime(appointment.StartAt);
        TimingText.Text = $"{MinimalShellSelection.TimingLabel(appointment, now)} - {time}";
        TitleText.Text = title;
        DurationText.Text = $"{appointment.DurationMinutes} min";
        AutomationProperties.SetName(SummaryRow, $"Next appointment, {title}, at {time}");

        SummaryRow.Visibility = Visibility.Visible;
        UntrackedRow.Visibility = Visibility.Collapsed;

        StartButton.Visibility = action == AppointmentAction.Start ? Visibility.Visible : Visibility.Collapsed;
        StartingButton.Visibility = action == AppointmentAction.Starting ? Visibility.Visible : Visibility.Collapsed;
        RecordingPanel.Visibility = action == AppointmentAction.StopRecording ? Visibility.Visible : Visibility.Collapsed;

        AutomationProperties.SetName(StartButton, $"Start session for {title}");
        AutomationProperties.SetName(StartingButton, $"Starting session for {title}");
        RecordingPanel.SessionTitle = title;
    }

    /// <summary>
    /// A recording is live but its appointment isn't in today's list (a handoff
    /// for another day, or a list that failed to refresh). Show the controls
    /// anyway: the therapist still has to be able to end the session.
    /// </summary>
    public void ShowUntrackedRecording()
    {
        _appointment = null;
        SummaryRow.Visibility = Visibility.Collapsed;
        UntrackedRow.Visibility = Visibility.Visible;
        StartButton.Visibility = Visibility.Collapsed;
        StartingButton.Visibility = Visibility.Collapsed;
        RecordingPanel.Visibility = Visibility.Visible;
        RecordingPanel.SessionTitle = null;
    }

    private void StartButton_Click(object sender, RoutedEventArgs e)
    {
        if (_appointment is { } appointment) StartRequested?.Invoke(this, appointment.Id);
    }
}
