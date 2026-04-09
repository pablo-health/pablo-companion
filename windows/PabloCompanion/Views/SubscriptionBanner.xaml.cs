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
        LapsedBanner.Visibility = kind is "past_due" or "canceled" ? Visibility.Visible : Visibility.Collapsed;
        GraceActiveBanner.Visibility = kind == "grace_active" ? Visibility.Visible : Visibility.Collapsed;

        // Background color based on state
        BannerPanel.Background = kind switch
        {
            "trial" => new SolidColorBrush(ColorHelper.FromArgb(30, 212, 146, 46)),       // Honey 12%
            "past_due" or "canceled" => new SolidColorBrush(ColorHelper.FromArgb(38, 232, 180, 162)), // Blush 15%
            "grace_active" => new SolidColorBrush(ColorHelper.FromArgb(25, 122, 158, 126)),  // Sage 10%
            _ => null,
        };

        // Trial text
        if (kind == "trial")
        {
            var parts = new List<string>();
            if (_vm.TrialSessionsRemaining is { } sessions)
                parts.Add($"{sessions} session{(sessions == 1 ? "" : "s")} remaining");
            if (_vm.TrialDaysRemaining is { } days)
                parts.Add($"{days} day{(days == 1 ? "" : "s")} left");
            TrialText.Text = parts.Count > 0
                ? $"Free trial \u2014 {string.Join(", ", parts)}"
                : "You're on a free trial";
        }

        // Lapsed heading
        if (kind is "past_due" or "canceled")
        {
            LapsedHeading.Text = kind == "past_due"
                ? "Your payment needs attention"
                : "Your subscription has ended";
            ExtensionButton.Visibility = _vm.Info?.GraceExtensionAvailable == true
                ? Visibility.Visible
                : Visibility.Collapsed;
        }

        // Extension state
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

        // Grace active text
        if (kind == "grace_active" && _vm.GraceExpiresAt is { } expires)
        {
            var remaining = expires - DateTimeOffset.Now;
            var hours = (int)remaining.TotalHours;
            GraceText.Text = hours > 0
                ? $"You're covered for the next {hours} hour{(hours == 1 ? "" : "s")} \u2014 take care of your sessions today"
                : "You're covered \u2014 take care of your sessions today";
        }
    }

    private async void ExtensionButton_Click(object sender, RoutedEventArgs e)
    {
        if (_vm != null)
            await _vm.RequestExtensionAsync();
    }
}
