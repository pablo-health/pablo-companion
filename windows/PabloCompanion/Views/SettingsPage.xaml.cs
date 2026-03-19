using Microsoft.Extensions.DependencyInjection;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Xaml.Navigation;
using PabloCompanion.Services;
using PabloCompanion.ViewModels;
using uniffi.pablo_core;

namespace PabloCompanion.Views;

public sealed partial class SettingsPage : Page
{
    private readonly AuthViewModel _authVm;
    private readonly APIClient _apiClient;

    public SettingsPage()
    {
        InitializeComponent();
        _authVm = App.Services.GetRequiredService<AuthViewModel>();
        _apiClient = App.Services.GetRequiredService<APIClient>();
    }

    protected override void OnNavigatedTo(NavigationEventArgs e)
    {
        base.OnNavigatedTo(e);

        EmailText.Text = _authVm.UserEmail ?? "Not signed in";
        BackendUrlText.Text = _apiClient.BaseUrl;

        try
        {
            var coreVersion = PabloCoreMethods.CoreVersion();
            VersionText.Text = $"Pablo Companion (Windows) — Core v{coreVersion}";
        }
        catch
        {
            VersionText.Text = "Pablo Companion (Windows)";
        }
    }

    private async void HealthCheck_Click(object sender, RoutedEventArgs e)
    {
        try
        {
            await _apiClient.HealthCheckAsync();
            HealthStatus.Severity = InfoBarSeverity.Success;
            HealthStatus.Title = "Connected";
            HealthStatus.Message = $"Backend at {_apiClient.BaseUrl} is healthy.";
        }
        catch (Exception ex)
        {
            HealthStatus.Severity = InfoBarSeverity.Error;
            HealthStatus.Title = "Connection Failed";
            HealthStatus.Message = ex.Message;
        }

        HealthStatus.IsOpen = true;
    }

    private void SignOut_Click(object sender, RoutedEventArgs e)
    {
        _authVm.SignOutCommand.Execute(null);
    }
}
