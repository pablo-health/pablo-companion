using Microsoft.Extensions.DependencyInjection;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Xaml.Navigation;
using PabloCompanion.Helpers;
using PabloCompanion.ViewModels;

namespace PabloCompanion.Views;

public sealed partial class DayPage : Page
{
    private readonly SessionViewModel _viewModel;

    public DayPage()
    {
        InitializeComponent();
        _viewModel = App.Services.GetRequiredService<SessionViewModel>();
        _viewModel.PropertyChanged += ViewModel_PropertyChanged;

        UpdateGreeting();
    }

    protected override async void OnNavigatedTo(NavigationEventArgs e)
    {
        base.OnNavigatedTo(e);
        await _viewModel.LoadTodaySessionsAsync();
        _viewModel.StartPolling();
        UpdateUI();
    }

    protected override void OnNavigatedFrom(NavigationEventArgs e)
    {
        base.OnNavigatedFrom(e);
        _viewModel.StopPolling();
    }

    private void ViewModel_PropertyChanged(object? sender, System.ComponentModel.PropertyChangedEventArgs e)
    {
        DispatcherQueue.TryEnqueue(UpdateUI);
    }

    private void UpdateUI()
    {
        LoadingRing.IsActive = _viewModel.IsLoading;
        SessionList.ItemsSource = _viewModel.TodaySessions;
        EmptyState.Visibility = !_viewModel.IsLoading && _viewModel.TodaySessions.Length == 0
            ? Visibility.Visible
            : Visibility.Collapsed;

        if (_viewModel.ErrorMessage != null)
        {
            ErrorBanner.Message = _viewModel.ErrorMessage;
            ErrorBanner.IsOpen = true;
        }
        else
        {
            ErrorBanner.IsOpen = false;
        }
    }

    private void UpdateGreeting()
    {
        var hour = DateTime.Now.Hour;
        var greeting = hour switch
        {
            < 12 => "Good morning",
            < 17 => "Good afternoon",
            _ => "Good evening",
        };
        GreetingText.Text = greeting;
        DateText.Text = DateTime.Today.ToString("dddd, MMMM d");
    }

    private async void QuickStart_Click(object sender, RoutedEventArgs e)
    {
        var dialog = new QuickStartDialog
        {
            XamlRoot = XamlRoot,
        };

        var result = await dialog.ShowAsync();
        if (result == ContentDialogResult.Primary && dialog.SelectedPatientId != null)
        {
            await _viewModel.CreateAdHocSessionAsync(dialog.SelectedPatientId);
        }
    }
}
