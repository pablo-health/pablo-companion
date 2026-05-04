using Microsoft.Extensions.DependencyInjection;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Xaml.Navigation;
using PabloCompanion.Services;
using PabloCompanion.ViewModels;

namespace PabloCompanion.Views;

public sealed partial class PracticeSessionPage : Page
{
    private readonly PracticeViewModel _viewModel;

    public PracticeSessionPage()
    {
        InitializeComponent();
        _viewModel = App.Services.GetRequiredService<PracticeViewModel>();
    }

    protected override void OnNavigatedTo(NavigationEventArgs e)
    {
        base.OnNavigatedTo(e);
        _viewModel.PropertyChanged += ViewModel_PropertyChanged;
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

        // Topic name
        TopicNameText.Text = _viewModel.SelectedTopic?.Name ?? "Practice Session";

        // Timer
        var minutes = _viewModel.DurationSeconds / 60;
        var seconds = _viewModel.DurationSeconds % 60;
        TimerText.Text = $"{minutes}:{seconds:D2}";

        // Pablo state
        switch (_viewModel.PabloState)
        {
            case PracticeWebSocketClient.PabloState.Listening:
                PabloStateText.Text = "Pablo is listening...";
                PabloIcon.Glyph = "\uE720"; // Microphone
                PabloIndicator.Background = (Microsoft.UI.Xaml.Media.Brush)Resources["PabloSage"]
                    ?? App.Current.Resources["PabloSage"] as Microsoft.UI.Xaml.Media.Brush;
                break;
            case PracticeWebSocketClient.PabloState.Processing:
                PabloStateText.Text = "Pablo is thinking...";
                PabloIcon.Glyph = "\uE945"; // Processing
                PabloIndicator.Background = (Microsoft.UI.Xaml.Media.Brush)Resources["PabloSky"]
                    ?? App.Current.Resources["PabloSky"] as Microsoft.UI.Xaml.Media.Brush;
                break;
            case PracticeWebSocketClient.PabloState.Speaking:
                PabloStateText.Text = "Pablo is speaking...";
                PabloIcon.Glyph = "\uE767"; // Volume
                PabloIndicator.Background = (Microsoft.UI.Xaml.Media.Brush)Resources["PabloHoney"]
                    ?? App.Current.Resources["PabloHoney"] as Microsoft.UI.Xaml.Media.Brush;
                break;
        }

        // Audio levels
        MicLevelBar.Value = _viewModel.MicLevel;
        PabloLevelBar.Value = _viewModel.PabloLevel;

        // Status text
        StatusText.Text = phase switch
        {
            PracticeViewModel.Phase.Connecting => "Connecting...",
            PracticeViewModel.Phase.Active => "Session active",
            PracticeViewModel.Phase.Ending => "Ending session...",
            _ => "",
        };

        // Panel visibility
        ConnectingPanel.Visibility = phase == PracticeViewModel.Phase.Connecting
            ? Visibility.Visible : Visibility.Collapsed;
        ActiveControlsPanel.Visibility = phase == PracticeViewModel.Phase.Active
            ? Visibility.Visible : Visibility.Collapsed;

        // Error
        if (_viewModel.ErrorMessage != null)
        {
            ErrorBanner.Message = _viewModel.ErrorMessage;
            ErrorBanner.IsOpen = true;
        }
        else
        {
            ErrorBanner.IsOpen = false;
        }

        // Navigate away on ended or error
        if (phase == PracticeViewModel.Phase.Ended)
        {
            ShowEndedDialog();
        }
        else if (phase == PracticeViewModel.Phase.Error)
        {
            // Navigate back to topic picker on fatal error
            if (Frame.CanGoBack)
            {
                Frame.GoBack();
            }
        }
    }

    private async void ShowEndedDialog()
    {
        var dialog = new ContentDialog
        {
            Title = "Practice Complete",
            Content = new PracticeEndedContent(_viewModel),
            PrimaryButtonText = "Done",
            XamlRoot = XamlRoot,
        };

        await dialog.ShowAsync();

        _viewModel.DismissCommand.Execute(null);

        if (Frame.CanGoBack)
        {
            Frame.GoBack();
        }
    }

    private void EndSession_Click(object sender, RoutedEventArgs e)
    {
        _viewModel.EndSessionCommand.Execute(null);
    }
}
