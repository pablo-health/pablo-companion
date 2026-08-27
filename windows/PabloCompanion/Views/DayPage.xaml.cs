using Microsoft.Extensions.DependencyInjection;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Xaml.Navigation;
using PabloCompanion.Helpers;
using PabloCompanion.ViewModels;
using PabloCompanion.Models;

namespace PabloCompanion.Views;

public sealed partial class DayPage : Page
{
    /// <summary>
    /// Navigation parameter signalling that the page should kick off a recording
    /// for a specific appointment as soon as it loads. Used by deep-link handling
    /// in <see cref="MainWindow"/>.
    /// </summary>
    public sealed record StartFromAppointmentArgs(string AppointmentId);

    private readonly SessionViewModel _viewModel;
    private readonly PatientViewModel _patientVm;
    private readonly RecordingViewModel _recordingVm;

    public DayPage()
    {
        InitializeComponent();
        _viewModel = App.Services.GetRequiredService<SessionViewModel>();
        _patientVm = App.Services.GetRequiredService<PatientViewModel>();
        _recordingVm = App.Services.GetRequiredService<RecordingViewModel>();

        UpdateGreeting();

        // Wire up SessionTapped on row controls
        SessionList.ContainerContentChanging += SessionList_ContainerContentChanging;
    }

    protected override async void OnNavigatedTo(NavigationEventArgs e)
    {
        base.OnNavigatedTo(e);
        _viewModel.PropertyChanged += ViewModel_PropertyChanged;
        _recordingVm.PropertyChanged += ViewModel_PropertyChanged;
        await _viewModel.LoadTodaySessionsAsync();
        _viewModel.StartPolling();
        UpdateUI();

        if (e.Parameter is StartFromAppointmentArgs args)
        {
            await StartFromAppointmentAsync(args.AppointmentId);
        }
    }

    private async Task StartFromAppointmentAsync(string appointmentId)
    {
        // Don't clobber an in-flight recording. If the therapist clicks a deep
        // link mid-session, leave them alone.
        if (_recordingVm.State != Models.RecordingUIState.Idle) return;

        var session = await _viewModel.StartSessionFromAppointmentAsync(appointmentId);
        if (session is null) return;
        await _viewModel.StartSessionAsync(session.Id);
    }

    protected override void OnNavigatedFrom(NavigationEventArgs e)
    {
        base.OnNavigatedFrom(e);
        _viewModel.PropertyChanged -= ViewModel_PropertyChanged;
        _recordingVm.PropertyChanged -= ViewModel_PropertyChanged;
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

        // Recording banner visibility
        var isRecording = _recordingVm.State != Models.RecordingUIState.Idle;
        RecordingBannerControl.Visibility = isRecording
            ? Visibility.Visible
            : Visibility.Collapsed;

        // Stall warning only makes sense against a live recording.
        StallWarningBanner.IsOpen = isRecording && _recordingVm.RecordingStalled;
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
        var dialog = new SessionDetailDialog(session, _patientVm.Patients)
        {
            XamlRoot = XamlRoot,
        };
        await dialog.ShowAsync();
    }
}
