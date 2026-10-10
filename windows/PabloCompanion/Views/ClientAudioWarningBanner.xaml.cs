using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Automation.Peers;
using Microsoft.UI.Xaml.Controls;

namespace PabloCompanion.Views;

/// <summary>
/// "Pablo can't hear your client yet": the therapist is talking but nothing is
/// arriving from the call (<see cref="Core.ClientAudioStatus.NoClientAudio"/>).
/// On Windows the likely cause on a working setup is the call playing on an
/// output this PC isn't capturing (another device, a Bluetooth headset's call
/// mode, a muted tab), so it points at the sound settings. Presentational: the
/// host decides when to show it and handles <see cref="Dismissed"/>.
/// </summary>
public sealed partial class ClientAudioWarningBanner : UserControl
{
    public const string Title = "Pablo can't hear your client yet";
    public const string SoundSettingsUri = "ms-settings:sound";

    private bool _shown;

    public ClientAudioWarningBanner()
    {
        InitializeComponent();
    }

    /// <summary>Raised when the therapist closes the warning.</summary>
    public event EventHandler? Dismissed;

    /// <summary>Show or hide the warning; it is read out once each time it appears.</summary>
    public void SetShown(bool shown)
    {
        Visibility = shown ? Visibility.Visible : Visibility.Collapsed;
        if (shown && !_shown)
        {
            var peer = FrameworkElementAutomationPeer.FromElement(TitleText)
                ?? FrameworkElementAutomationPeer.CreatePeerForElement(TitleText);
            peer?.RaiseNotificationEvent(
                AutomationNotificationKind.Other,
                AutomationNotificationProcessing.ImportantMostRecent,
                Title,
                "ClientAudioWarning");
        }
        _shown = shown;
    }

    private void Dismiss_Click(object sender, RoutedEventArgs e) => Dismissed?.Invoke(this, EventArgs.Empty);

    private async void OpenSoundSettings_Click(object sender, RoutedEventArgs e)
    {
        await Windows.System.Launcher.LaunchUriAsync(new Uri(SoundSettingsUri));
    }
}
