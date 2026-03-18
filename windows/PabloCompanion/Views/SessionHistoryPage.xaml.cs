using Microsoft.Extensions.DependencyInjection;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Xaml.Navigation;
using PabloCompanion.ViewModels;
using uniffi.pablo_core;

namespace PabloCompanion.Views;

public sealed partial class SessionHistoryPage : Page
{
    private readonly SessionViewModel _viewModel;
    private Button? _activeFilterButton;
    private readonly Button[] _filterButtons;

    public SessionHistoryPage()
    {
        InitializeComponent();
        _viewModel = App.Services.GetRequiredService<SessionViewModel>();
        _viewModel.PropertyChanged += ViewModel_PropertyChanged;
        _filterButtons = [FilterAll, FilterScheduled, FilterInProgress, FilterRecorded, FilterFinalized, FilterCancelled];
        _activeFilterButton = FilterAll;

        // Wire up SessionTapped on row controls
        SessionList.ContainerContentChanging += SessionList_ContainerContentChanging;
    }

    protected override async void OnNavigatedTo(NavigationEventArgs e)
    {
        base.OnNavigatedTo(e);
        await _viewModel.LoadSessionsAsync();
        UpdateUI();
    }

    private void ViewModel_PropertyChanged(object? sender, System.ComponentModel.PropertyChangedEventArgs e)
    {
        DispatcherQueue.TryEnqueue(UpdateUI);
    }

    private void UpdateUI()
    {
        LoadingRing.IsActive = _viewModel.IsLoadingHistory;
        SessionList.ItemsSource = _viewModel.Sessions;
        CountSubtitle.Text = _viewModel.TotalSessions > 0
            ? $"{_viewModel.TotalSessions} total sessions"
            : "";
        EmptyState.Visibility = !_viewModel.IsLoadingHistory && _viewModel.Sessions.Length == 0
            ? Visibility.Visible
            : Visibility.Collapsed;
        LoadMoreButton.Visibility = _viewModel.HasMoreSessions
            ? Visibility.Visible
            : Visibility.Collapsed;

        if (_viewModel.HistoryErrorMessage != null)
        {
            ErrorBanner.Message = _viewModel.HistoryErrorMessage;
            ErrorBanner.IsOpen = true;
        }
        else
        {
            ErrorBanner.IsOpen = false;
        }
    }

    private void Filter_Click(object sender, RoutedEventArgs e)
    {
        if (sender is not Button button) return;

        // Update active state visuals
        foreach (var btn in _filterButtons)
        {
            btn.Style = (Style)Application.Current.Resources["PabloFilterButton"];
        }
        button.Style = (Style)Application.Current.Resources["PabloFilterButtonActive"];
        _activeFilterButton = button;

        // Apply filter
        var tag = button.Tag?.ToString();
        _viewModel.StatusFilter = string.IsNullOrEmpty(tag) ? null : tag;
    }

    private async void LoadMore_Click(object sender, RoutedEventArgs e)
    {
        await _viewModel.LoadMoreSessionsAsync();
    }

    private void SessionList_ContainerContentChanging(ListViewBase sender, ContainerContentChangingEventArgs args)
    {
        if (args.ItemContainer?.ContentTemplateRoot is SessionRowControl row)
        {
            row.SessionTapped -= Row_SessionTapped;
            row.SessionTapped += Row_SessionTapped;
        }
    }

    private async void Row_SessionTapped(object? sender, Session session)
    {
        var dialog = new SessionDetailDialog(session)
        {
            XamlRoot = XamlRoot,
        };
        await dialog.ShowAsync();
    }
}
