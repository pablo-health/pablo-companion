using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Xaml.Media;
using PabloCompanion.Models;

namespace PabloCompanion.Views;

/// <summary>
/// Tells the therapist that session audio is still on this PC, waiting to
/// upload. Presentational: the host passes the backlog and handles Upload Now
/// through <see cref="UploadNowRequested"/>.
/// </summary>
public sealed partial class UploadBacklogNote : UserControl
{
    public UploadBacklogNote()
    {
        InitializeComponent();
    }

    /// <summary>Raised when Upload Now is clicked.</summary>
    public event EventHandler? UploadNowRequested;

    /// <summary>Show the backlog; collapses itself when nothing is waiting.</summary>
    public void Show(UploadBacklog backlog, bool isUploading)
    {
        if (backlog.Message is not { } message)
        {
            Visibility = Visibility.Collapsed;
            return;
        }

        Visibility = Visibility.Visible;
        MessageText.Text = message;

        var tint = (Brush)Application.Current.Resources[backlog.HasFailed ? "PabloError" : "PabloHoney"];
        NoteIcon.Foreground = tint;
        NoteIcon.Glyph = backlog.HasFailed ? "\uE7BA" : "\uE898";
        NoteBorder.Background = new SolidColorBrush(backlog.HasFailed
            ? Windows.UI.Color.FromArgb(0x1A, 0xC4, 0x5B, 0x4A)
            : Windows.UI.Color.FromArgb(0x1A, 0xD4, 0x92, 0x2E));

        UploadNowButton.Visibility = isUploading ? Visibility.Collapsed : Visibility.Visible;
        UploadingRing.Visibility = isUploading ? Visibility.Visible : Visibility.Collapsed;
        UploadingRing.IsActive = isUploading;
    }

    private void UploadNowButton_Click(object sender, RoutedEventArgs e) => UploadNowRequested?.Invoke(this, EventArgs.Empty);
}
