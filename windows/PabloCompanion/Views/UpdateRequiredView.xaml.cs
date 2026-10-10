using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;
using PabloCompanion.Models;

namespace PabloCompanion.Views;

/// <summary>
/// The update-required screen. <see cref="MainWindow"/> makes it the whole window
/// content when <see cref="ViewModels.UpdateGateViewModel.Shown"/> is set; the copy
/// comes from <see cref="UpdateRequiredReason"/>.
/// </summary>
public sealed partial class UpdateRequiredView : UserControl
{
    /// <summary>This app's Microsoft Store listing.</summary>
    public const string StoreProductUri = "ms-windows-store://pdp/?productid=9N0260HFX1JC";

    public UpdateRequiredView(UpdateRequiredReason reason)
    {
        InitializeComponent();
        TitleText.Text = reason.Title;
        SubtitleText.Text = reason.Subtitle;
        InstructionText.Text = reason.Instruction;
        UpdateButton.Visibility = reason.ShowsUpdateButton ? Visibility.Visible : Visibility.Collapsed;
    }

    private async void Update_Click(object sender, RoutedEventArgs e)
    {
        try
        {
            await Windows.System.Launcher.LaunchUriAsync(new Uri(StoreProductUri));
        }
        catch (Exception ex)
        {
            App.LogException("UpdateRequiredView.Update", ex);
        }
    }
}
