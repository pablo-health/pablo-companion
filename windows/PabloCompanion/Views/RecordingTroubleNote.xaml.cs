using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Automation.Peers;
using Microsoft.UI.Xaml.Controls;
using PabloCompanion.Helpers;
using PabloCompanion.Models;

namespace PabloCompanion.Views;

/// <summary>
/// The stalled / stopped capture note in the session card. Presentational: the
/// host decides when to show it (<see cref="ViewModels.RecordingViewModel.Trouble"/>)
/// and handles Restart Recording through <see cref="RestartRequested"/>.
/// </summary>
public sealed partial class RecordingTroubleNote : UserControl
{
    private RecordingTrouble? _trouble;

    public RecordingTroubleNote()
    {
        InitializeComponent();
    }

    /// <summary>Raised when Restart Recording is clicked.</summary>
    public event EventHandler? RestartRequested;

    /// <summary>Show a trouble; offers Open Settings when the fix is the microphone privacy setting.</summary>
    public void Show(RecordingTrouble trouble, bool offerMicrophoneSettings)
    {
        var changed = trouble != _trouble;
        _trouble = trouble;
        MessageText.Text = trouble.Message;
        OpenSettingsButton.Visibility = offerMicrophoneSettings ? Visibility.Visible : Visibility.Collapsed;

        // Read the new trouble out once, the way the Mac note announces on appear.
        if (changed && FrameworkElementAutomationPeer.FromElement(MessageText) is { } peer)
            peer.RaiseAutomationEvent(AutomationEvents.LiveRegionChanged);
    }

    /// <summary>Forget the shown trouble, so the same one is announced again if it comes back.</summary>
    public void Clear() => _trouble = null;

    private void RestartButton_Click(object sender, RoutedEventArgs e) => RestartRequested?.Invoke(this, EventArgs.Empty);

    private async void OpenSettingsButton_Click(object sender, RoutedEventArgs e)
    {
        await Windows.System.Launcher.LaunchUriAsync(new Uri(RecordingStartFailure.MicrophoneSettingsUri));
    }
}
