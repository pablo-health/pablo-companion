using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;

namespace PabloCompanion.Views;

/// <summary>
/// Shown when sign-in could not register this PC with the server. Until it is
/// registered the web dashboard offers the download instead of starting a
/// session here, which otherwise looks like the app was never installed.
/// Presentational: the host decides when to show it and handles Try Again
/// through <see cref="RetryRequested"/>.
/// </summary>
public sealed partial class DeviceLinkNote : UserControl
{
    public DeviceLinkNote()
    {
        InitializeComponent();
    }

    /// <summary>Raised when Try Again is clicked.</summary>
    public event EventHandler? RetryRequested;

    /// <summary>Swaps Try Again for a progress ring while a retry runs.</summary>
    public void SetRetrying(bool isRetrying)
    {
        TryAgainButton.Visibility = isRetrying ? Visibility.Collapsed : Visibility.Visible;
        RetryingRing.Visibility = isRetrying ? Visibility.Visible : Visibility.Collapsed;
        RetryingRing.IsActive = isRetrying;
    }

    private void TryAgainButton_Click(object sender, RoutedEventArgs e) => RetryRequested?.Invoke(this, EventArgs.Empty);
}
