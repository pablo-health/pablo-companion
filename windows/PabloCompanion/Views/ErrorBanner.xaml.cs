using Microsoft.UI.Xaml.Controls;

namespace PabloCompanion.Views;

public sealed partial class ErrorBanner : UserControl
{
    public ErrorBanner()
    {
        InitializeComponent();
    }

    public void Show(string message)
    {
        Banner.Message = message;
        Banner.IsOpen = true;
    }

    public void Hide()
    {
        Banner.IsOpen = false;
    }
}
