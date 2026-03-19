using Microsoft.UI.Xaml;
using Windows.ApplicationModel.DataTransfer;

namespace PabloCompanion.Helpers;

/// <summary>
/// Copies text to clipboard and auto-clears after a timeout (HIPAA compliance).
/// </summary>
public static class HipaaClipboard
{
    private static DispatcherTimer? _clearTimer;
    private static string? _copiedText;

    public static void CopyWithAutoClear(string text, int clearAfterSeconds = 60)
    {
        var dataPackage = new DataPackage();
        dataPackage.SetText(text);
        Clipboard.SetContent(dataPackage);
        _copiedText = text;

        // Cancel any existing timer
        _clearTimer?.Stop();

        // Auto-clear clipboard after timeout — only if content hasn't changed
        _clearTimer = new DispatcherTimer { Interval = TimeSpan.FromSeconds(clearAfterSeconds) };
        _clearTimer.Tick += async (_, _) =>
        {
            _clearTimer?.Stop();
            _clearTimer = null;

            try
            {
                var content = Clipboard.GetContent();
                if (content.Contains(StandardDataFormats.Text))
                {
                    var current = await content.GetTextAsync();
                    if (current == _copiedText)
                        Clipboard.Clear();
                }
            }
            catch
            {
                // Clipboard access can fail if another app holds it
            }
            _copiedText = null;
        };
        _clearTimer.Start();
    }
}
