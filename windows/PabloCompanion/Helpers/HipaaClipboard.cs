using Microsoft.UI.Xaml;
using Windows.ApplicationModel.DataTransfer;

namespace PabloCompanion.Helpers;

/// <summary>
/// Copies text to clipboard and auto-clears after a timeout (HIPAA compliance).
/// </summary>
public static class HipaaClipboard
{
    private static DispatcherTimer? _clearTimer;

    public static void CopyWithAutoClear(string text, int clearAfterSeconds = 60)
    {
        var dataPackage = new DataPackage();
        dataPackage.SetText(text);
        Clipboard.SetContent(dataPackage);

        // Cancel any existing timer
        _clearTimer?.Stop();

        // Auto-clear clipboard after timeout
        _clearTimer = new DispatcherTimer { Interval = TimeSpan.FromSeconds(clearAfterSeconds) };
        _clearTimer.Tick += (_, _) =>
        {
            _clearTimer.Stop();
            _clearTimer = null;
            Clipboard.Clear();
        };
        _clearTimer.Start();
    }
}
