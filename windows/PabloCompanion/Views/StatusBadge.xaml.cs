using Microsoft.UI;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Xaml.Media;
using uniffi.pablo_core;

namespace PabloCompanion.Views;

public sealed partial class StatusBadge : UserControl
{
    public StatusBadge()
    {
        InitializeComponent();
    }

    private SessionStatus _status;
    public SessionStatus Status
    {
        get => _status;
        set
        {
            _status = value;
            UpdateBadge();
        }
    }

    private void UpdateBadge()
    {
        var (text, bg, fg) = _status switch
        {
            SessionStatus.Scheduled => ("Scheduled", "#E8D5B8", "#6B5344"),
            SessionStatus.InProgress => ("In Progress", "#7A9E7E", "#FFFFFF"),
            SessionStatus.RecordingComplete => ("Recorded", "#89B4C8", "#FFFFFF"),
            SessionStatus.Queued => ("Queued", "#E8D5B8", "#6B5344"),
            SessionStatus.Processing => ("Processing", "#89B4C8", "#FFFFFF"),
            SessionStatus.PendingReview => ("Review", "#D4922E", "#FFFFFF"),
            SessionStatus.Finalized => ("Done", "#7A9E7E", "#FFFFFF"),
            SessionStatus.Cancelled => ("Cancelled", "#C45B4A", "#FFFFFF"),
            SessionStatus.Failed => ("Failed", "#C45B4A", "#FFFFFF"),
            _ => ("Unknown", "#E8D5B8", "#6B5344"),
        };

        BadgeText.Text = text;
        BadgeBorder.Background = new SolidColorBrush(ColorFromHex(bg));
        BadgeText.Foreground = new SolidColorBrush(ColorFromHex(fg));
    }

    private static Windows.UI.Color ColorFromHex(string hex)
    {
        hex = hex.TrimStart('#');
        return Windows.UI.Color.FromArgb(
            0xFF,
            Convert.ToByte(hex[..2], 16),
            Convert.ToByte(hex[2..4], 16),
            Convert.ToByte(hex[4..6], 16)
        );
    }
}
