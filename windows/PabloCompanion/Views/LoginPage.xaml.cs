using Microsoft.Extensions.DependencyInjection;
using Microsoft.UI.Xaml.Controls;
using PabloCompanion.ViewModels;

namespace PabloCompanion.Views;

public sealed partial class LoginPage : UserControl
{
    public AuthViewModel ViewModel { get; }

    public LoginPage()
    {
        ViewModel = App.Services.GetRequiredService<AuthViewModel>();
        InitializeComponent();
    }
}
