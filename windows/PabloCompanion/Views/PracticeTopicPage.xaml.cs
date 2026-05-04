using Microsoft.Extensions.DependencyInjection;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Xaml.Input;
using Microsoft.UI.Xaml.Navigation;
using PabloCompanion.Models;
using PabloCompanion.ViewModels;

namespace PabloCompanion.Views;

public sealed partial class PracticeTopicPage : Page
{
    private readonly PracticeViewModel _viewModel;
    private readonly RecordingViewModel _recordingVm;

    public PracticeTopicPage()
    {
        InitializeComponent();
        _viewModel = App.Services.GetRequiredService<PracticeViewModel>();
        _recordingVm = App.Services.GetRequiredService<RecordingViewModel>();
    }

    protected override async void OnNavigatedTo(NavigationEventArgs e)
    {
        base.OnNavigatedTo(e);
        _viewModel.PropertyChanged += ViewModel_PropertyChanged;
        await _viewModel.LoadTopicsCommand.ExecuteAsync(null);
        UpdateUI();
    }

    protected override void OnNavigatedFrom(NavigationEventArgs e)
    {
        base.OnNavigatedFrom(e);
        _viewModel.PropertyChanged -= ViewModel_PropertyChanged;
    }

    private void ViewModel_PropertyChanged(object? sender, System.ComponentModel.PropertyChangedEventArgs e)
    {
        DispatcherQueue.TryEnqueue(UpdateUI);
    }

    private void UpdateUI()
    {
        var phase = _viewModel.CurrentPhase;

        LoadingRing.IsActive = phase == PracticeViewModel.Phase.LoadingTopics;

        if (phase == PracticeViewModel.Phase.PickingTopic)
        {
            TopicList.ItemsSource = _viewModel.Topics;
            TopicList.Visibility = _viewModel.Topics.Length > 0 ? Visibility.Visible : Visibility.Collapsed;
            EmptyState.Visibility = _viewModel.Topics.Length == 0 ? Visibility.Visible : Visibility.Collapsed;
        }
        else
        {
            TopicList.Visibility = Visibility.Collapsed;
            EmptyState.Visibility = Visibility.Collapsed;
        }

        if (_viewModel.ErrorMessage != null)
        {
            ErrorBanner.Message = _viewModel.ErrorMessage;
            ErrorBanner.IsOpen = true;
        }
        else
        {
            ErrorBanner.IsOpen = false;
        }

        // Navigate to session page when connecting or active
        if (phase is PracticeViewModel.Phase.Connecting or PracticeViewModel.Phase.Active
            or PracticeViewModel.Phase.Ending or PracticeViewModel.Phase.Ended)
        {
            Frame.Navigate(typeof(PracticeSessionPage));
        }
    }

    private async void TopicItem_PointerPressed(object sender, PointerRoutedEventArgs e)
    {
        if (sender is FrameworkElement element && element.DataContext is PracticeTopic topic)
        {
            // Pass the selected mic device from recording settings
            _viewModel.SelectedMicId = _recordingVm.SelectedMicId;
            await _viewModel.StartSessionCommand.ExecuteAsync(topic);
        }
    }
}
