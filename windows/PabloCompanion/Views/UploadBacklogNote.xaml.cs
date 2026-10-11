using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Xaml.Media;
using PabloCompanion.Models;

namespace PabloCompanion.Views;

/// <summary>
/// Tells the therapist that session audio is still on this PC, waiting to
/// upload, and separately about recordings that can never be uploaded.
/// Presentational: the host passes the backlog and handles Upload Now through
/// <see cref="UploadNowRequested"/> and Remove through <see cref="RemoveRequested"/>.
/// </summary>
public sealed partial class UploadBacklogNote : UserControl
{
    public UploadBacklogNote()
    {
        InitializeComponent();
    }

    /// <summary>Raised when Upload Now is clicked.</summary>
    public event EventHandler? UploadNowRequested;

    /// <summary>Raised when Remove is clicked.</summary>
    public event EventHandler? RemoveRequested;

    /// <summary>Show the backlog; collapses itself when nothing is waiting or dead.</summary>
    public void Show(UploadBacklog backlog, bool isUploading)
    {
        var message = backlog.Message;
        var deadMessage = backlog.UnrecoverableMessage;
        if (message is null && deadMessage is null)
        {
            Visibility = Visibility.Collapsed;
            return;
        }

        Visibility = Visibility.Visible;

        WaitingRow.Visibility = message is null ? Visibility.Collapsed : Visibility.Visible;
        MessageText.Text = message ?? "";
        UnrecoverableRow.Visibility = deadMessage is null ? Visibility.Collapsed : Visibility.Visible;
        UnrecoverableText.Text = deadMessage ?? "";

        var failed = backlog.HasFailed || deadMessage is not null;
        var tint = (Brush)Application.Current.Resources[backlog.HasFailed ? "PabloError" : "PabloHoney"];
        NoteIcon.Foreground = tint;
        NoteIcon.Glyph = backlog.HasFailed ? "\uE7BA" : "\uE898";
        NoteBorder.Background = new SolidColorBrush(failed
            ? Windows.UI.Color.FromArgb(0x1A, 0xC4, 0x5B, 0x4A)
            : Windows.UI.Color.FromArgb(0x1A, 0xD4, 0x92, 0x2E));

        UploadNowButton.Visibility = isUploading ? Visibility.Collapsed : Visibility.Visible;
        UploadingRing.Visibility = isUploading ? Visibility.Visible : Visibility.Collapsed;
        UploadingRing.IsActive = isUploading;
        RemoveButton.IsEnabled = !isUploading;
    }

    private void UploadNowButton_Click(object sender, RoutedEventArgs e) => UploadNowRequested?.Invoke(this, EventArgs.Empty);

    private void RemoveButton_Click(object sender, RoutedEventArgs e) => RemoveRequested?.Invoke(this, EventArgs.Empty);
}
