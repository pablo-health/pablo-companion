using Microsoft.Extensions.DependencyInjection;
using Microsoft.UI;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Xaml.Media;
using PabloCompanion.Models;
using PabloCompanion.ViewModels;

namespace PabloCompanion.Views;

public sealed partial class RecordingBanner : UserControl
{
    private readonly RecordingViewModel _vm;

    public RecordingBanner()
    {
        InitializeComponent();
        _vm = App.Services.GetRequiredService<RecordingViewModel>();
        _vm.PropertyChanged += Vm_PropertyChanged;
        UpdateUI();
    }

    private void Vm_PropertyChanged(object? sender, System.ComponentModel.PropertyChangedEventArgs e)
    {
        DispatcherQueue.TryEnqueue(UpdateUI);
    }

    private void UpdateUI()
    {
        // Visibility managed by parent (DayPage)
        var isPaused = _vm.State == RecordingUIState.Paused;

        StatusText.Text = isPaused ? "Paused" : "Recording";
        RecordingDot.Fill = isPaused
            ? new SolidColorBrush(Colors.Yellow)
            : new SolidColorBrush(Colors.White);

        BannerBorder.Background = isPaused
            ? new SolidColorBrush(Windows.UI.Color.FromArgb(255, 180, 160, 80))
            : (Brush)Application.Current.Resources["PabloSage"];

        // Duration
        var ts = TimeSpan.FromSeconds(_vm.Duration);
        DurationText.Text = ts.ToString(@"hh\:mm\:ss");

        // System audio indicator
        SystemAudioDot.Fill = _vm.SystemAudioActive
            ? new SolidColorBrush(Colors.LimeGreen)
            : new SolidColorBrush(Windows.UI.Color.FromArgb(128, 255, 255, 255));
    }

    private async void StopButton_Click(object sender, RoutedEventArgs e)
    {
        await _vm.StopRecordingAsync();
    }
}
