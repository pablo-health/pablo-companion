using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Automation;
using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Xaml.Media;
using PabloCompanion.Helpers;

namespace PabloCompanion.Views;

/// <summary>
/// Whether the client's side of the call is reaching the recording: "Hearing
/// client", "Waiting for client audio" (honey), "No client audio" or "No system
/// audio" (blush). Replaces the old "System Audio" dot, which only showed that
/// the loopback had some signal. Presentational; the host calls <see cref="Show"/>.
/// </summary>
public sealed partial class ClientAudioIndicator : UserControl
{
    // On the sage recording banner a sage dot would vanish, so the good state
    // is white, matching the recording dot and the meters.
    private static readonly SolidColorBrush GoodBrush = new(Windows.UI.Color.FromArgb(255, 255, 255, 255));

    private ClientAudioIndicatorState? _shown;

    public ClientAudioIndicator()
    {
        InitializeComponent();
    }

    public void Show(ClientAudioIndicatorState state)
    {
        if (state == _shown) return;
        _shown = state;

        LabelText.Text = state.Label;
        Dot.Fill = state.Tone switch
        {
            ClientAudioTone.Good => GoodBrush,
            ClientAudioTone.Waiting => (Brush)Application.Current.Resources["PabloHoney"],
            _ => (Brush)Application.Current.Resources["PabloBlush"],
        };
        AutomationProperties.SetName(Root, state.Label);
    }
}
