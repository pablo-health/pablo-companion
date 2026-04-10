using Microsoft.Extensions.DependencyInjection;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Xaml.Navigation;
using PabloCompanion.Services;
using PabloCompanion.ViewModels;

namespace PabloCompanion.Views;

public sealed partial class SettingsPage : Page
{
    private readonly AuthViewModel _authVm;
    private readonly APIClient _apiClient;
    private readonly RecordingViewModel _recordingVm;
    private readonly TranscriptionViewModel _transcriptionVm;

    public SettingsPage()
    {
        InitializeComponent();
        _authVm = App.Services.GetRequiredService<AuthViewModel>();
        _apiClient = App.Services.GetRequiredService<APIClient>();
        _recordingVm = App.Services.GetRequiredService<RecordingViewModel>();
        _transcriptionVm = App.Services.GetRequiredService<TranscriptionViewModel>();
    }

    protected override async void OnNavigatedTo(NavigationEventArgs e)
    {
        base.OnNavigatedTo(e);

        EmailText.Text = _authVm.UserEmail ?? "Not signed in";
        BackendUrlText.Text = _apiClient.BaseUrl;

        // Load audio devices
        await _recordingVm.LoadAudioDevicesAsync();
        PopulateMicDropdown();

        // Transcription settings
        PopulateTranscriptionSettings();

        VersionText.Text = "Pablo Companion (Windows) v1.0.0";
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

    private void PopulateMicDropdown()
    {
        MicDropdown.Items.Clear();
        foreach (var mic in _recordingVm.AvailableMics)
        {
            MicDropdown.Items.Add(new ComboBoxItem
            {
                Content = mic.IsDefault ? $"{mic.Name} (Default)" : mic.Name,
                Tag = mic.Id,
            });
        }

        // Select the currently chosen mic
        for (int i = 0; i < MicDropdown.Items.Count; i++)
        {
            if (MicDropdown.Items[i] is ComboBoxItem item && item.Tag as string == _recordingVm.SelectedMicId)
            {
                MicDropdown.SelectedIndex = i;
                break;
            }
        }
    }

    private void MicDropdown_SelectionChanged(object sender, SelectionChangedEventArgs e)
    {
        if (MicDropdown.SelectedItem is ComboBoxItem item)
        {
            _recordingVm.SelectedMicId = item.Tag as string;
        }
    }

    private void PopulateTranscriptionSettings()
    {
        // Quality preset
        int presetIndex = (int)_transcriptionVm.QualityPreset;
        TranscriptionQualityDropdown.SelectedIndex = presetIndex;

        // Auto-transcribe toggle
        AutoTranscribeToggle.IsOn = _transcriptionVm.AutoTranscribe;

        UpdateModelStatus();
    }

    private void UpdateModelStatus()
    {
        bool available = _transcriptionVm.IsModelAvailable;
        ModelStatusText.Text = available ? "Model downloaded" : "Model not downloaded";
        ModelActionButton.Content = available ? "Delete Model" : "Download Model";
    }

    private void TranscriptionQuality_SelectionChanged(object sender, SelectionChangedEventArgs e)
    {
        if (TranscriptionQualityDropdown.SelectedItem is ComboBoxItem item && item.Tag is string presetStr)
        {
            if (Enum.TryParse<QualityPreset>(presetStr, out var preset))
            {
                _transcriptionVm.QualityPreset = preset;
                UpdateModelStatus();
            }
        }
    }

    private void AutoTranscribe_Toggled(object sender, RoutedEventArgs e)
    {
        _transcriptionVm.AutoTranscribe = AutoTranscribeToggle.IsOn;
    }

    private async void ModelAction_Click(object sender, RoutedEventArgs e)
    {
        if (_transcriptionVm.IsModelAvailable)
        {
            _transcriptionVm.DeleteModelCommand.Execute(null);
            UpdateModelStatus();
        }
        else
        {
            ModelDownloadProgress.Visibility = Visibility.Visible;
            ModelActionButton.IsEnabled = false;

            _transcriptionVm.PropertyChanged += (_, args) =>
            {
                if (args.PropertyName is nameof(TranscriptionViewModel.Progress) or
                    nameof(TranscriptionViewModel.ProgressMessage))
                {
                    DispatcherQueue.TryEnqueue(() =>
                    {
                        ModelDownloadProgress.Value = _transcriptionVm.Progress * 100;
                    });
                }
            };

            await _transcriptionVm.DownloadModelAsync();

            ModelDownloadProgress.Visibility = Visibility.Collapsed;
            ModelActionButton.IsEnabled = true;
            UpdateModelStatus();
        }
    }

    private void SignOut_Click(object sender, RoutedEventArgs e)
    {
        _authVm.SignOutCommand.Execute(null);
    }
}
