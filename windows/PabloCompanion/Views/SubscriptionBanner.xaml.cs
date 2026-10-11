using Microsoft.Extensions.DependencyInjection;
using Microsoft.UI;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Xaml.Media;
using PabloCompanion.ViewModels;

namespace PabloCompanion.Views;

public sealed partial class SubscriptionBanner : UserControl
{
    private SubscriptionViewModel? _vm;

    public SubscriptionBanner()
    {
        InitializeComponent();
    }

    /// <summary>
    /// Binds the banner to the subscription ViewModel and refreshes the UI.
    /// Called by MainWindow after DI is available.
    /// </summary>
    public void Bind(SubscriptionViewModel vm)
    {
        _vm = vm;
        _vm.PropertyChanged += (_, _) => DispatcherQueue.TryEnqueue(UpdateUI);
        UpdateUI();
    }

    private void UpdateUI()
    {
        if (_vm == null) return;

        var kind = _vm.BannerKind;
        BannerPanel.Visibility = kind == "hidden" ? Visibility.Collapsed : Visibility.Visible;

        TrialBanner.Visibility = kind == "trial" ? Visibility.Visible : Visibility.Collapsed;
        LapsedBanner.Visibility = _vm.IsLapsed ? Visibility.Visible : Visibility.Collapsed;
        GraceActiveBanner.Visibility = kind == "grace_active" ? Visibility.Visible : Visibility.Collapsed;

        BannerPanel.Background = kind switch
        {
            "trial" => new SolidColorBrush(ColorHelper.FromArgb(30, 212, 146, 46)),       // Honey 12%
            "grace_active" => new SolidColorBrush(ColorHelper.FromArgb(25, 122, 158, 126)),  // Sage 10%
            _ when _vm.IsLapsed => new SolidColorBrush(ColorHelper.FromArgb(38, 232, 180, 162)), // Blush 15%
            _ => null,
        };

        if (kind == "trial")
            TrialText.Text = _vm.TrialText;

        if (_vm.IsLapsed)
        {
            LapsedHeading.Text = _vm.LapsedHeading;
            ExtensionButton.Visibility = _vm.Info?.GraceExtensionAvailable == true
                ? Visibility.Visible
                : Visibility.Collapsed;
        }

        ExtendingRing.IsActive = _vm.IsExtending;
        ExtendingRing.Visibility = _vm.IsExtending ? Visibility.Visible : Visibility.Collapsed;
        ExtensionButton.IsEnabled = !_vm.IsExtending;

        if (_vm.ExtensionError is { } error)
        {
            ExtensionErrorText.Text = error;
            ExtensionErrorText.Visibility = Visibility.Visible;
        }
        else
        {
            ExtensionErrorText.Visibility = Visibility.Collapsed;
        }

        if (kind == "grace_active" && _vm.GraceExpiresAt is { } expires)
        {
            var remaining = expires - DateTimeOffset.Now;
            var hours = (int)remaining.TotalHours;
            GraceText.Text = hours > 0
                ? $"You're covered for the next {hours} hour{(hours == 1 ? "" : "s")} \u2014 take care of your sessions today"
                : "You're covered \u2014 take care of your sessions today";
        }
    }

    private async void ManageSubscriptionButton_Click(object sender, RoutedEventArgs e)
    {
        if (_vm != null)
            await Windows.System.Launcher.LaunchUriAsync(_vm.ManageSubscriptionUrl);
    }

    private async void ExtensionButton_Click(object sender, RoutedEventArgs e)
    {
        if (_vm != null)
            await _vm.RequestExtensionAsync();
    }
}
