using Microsoft.UI.Xaml.Controls;
using PabloCompanion.Helpers;

namespace PabloCompanion.Views;

public sealed partial class TranscriptViewerDialog : ContentDialog
{
    private readonly string _transcriptContent;

    public TranscriptViewerDialog(string transcriptContent)
    {
        InitializeComponent();
        _transcriptContent = transcriptContent;
        TranscriptText.Text = transcriptContent;
    }

    private void CopyAll_Click(ContentDialog sender, ContentDialogButtonClickEventArgs args)
    {
        // Prevent dialog from closing
        args.Cancel = true;

        HipaaClipboard.CopyWithAutoClear(_transcriptContent);
        CopyConfirmation.IsOpen = true;
    }
}
