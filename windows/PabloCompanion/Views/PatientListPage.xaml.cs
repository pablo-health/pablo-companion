using Microsoft.Extensions.DependencyInjection;
using Microsoft.UI;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Xaml.Media;
using Microsoft.UI.Xaml.Navigation;
using PabloCompanion.Helpers;
using PabloCompanion.ViewModels;
using uniffi.pablo_core;

namespace PabloCompanion.Views;

public sealed partial class PatientListPage : Page
{
    private readonly PatientViewModel _viewModel;

    public PatientListPage()
    {
        InitializeComponent();
        _viewModel = App.Services.GetRequiredService<PatientViewModel>();
    }

    protected override async void OnNavigatedTo(NavigationEventArgs e)
    {
        base.OnNavigatedTo(e);
        _viewModel.PropertyChanged += ViewModel_PropertyChanged;
        await _viewModel.LoadPatientsAsync();
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
        LoadingRing.IsActive = _viewModel.IsLoading;
        PatientList.ItemsSource = _viewModel.Patients;
        EmptyState.Visibility = !_viewModel.IsLoading && _viewModel.Patients.Length == 0
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

        // Populate enriched fields after ItemsSource is set
        PopulatePatientDetails();
    }

    private void PopulatePatientDetails()
    {
        for (int i = 0; i < PatientList.Items.Count; i++)
        {
            var container = PatientList.ContainerFromIndex(i) as ListViewItem;
            if (container == null || PatientList.Items[i] is not Patient patient) continue;

            PopulatePatientContainer(container, patient);
        }

        // Also register for ContainerContentChanging for virtualized items
        PatientList.ContainerContentChanging -= PatientList_ContainerContentChanging;
        PatientList.ContainerContentChanging += PatientList_ContainerContentChanging;
    }

    private void PatientList_ContainerContentChanging(ListViewBase sender,
        ContainerContentChangingEventArgs args)
    {
        if (args.Item is Patient patient)
        {
            // Defer to Phase 1 callback for smooth scrolling
            args.RegisterUpdateCallback((s, e) =>
            {
                PopulatePatientContainer(e.ItemContainer, (Patient)e.Item);
            });
        }
    }

    private static void PopulatePatientContainer(DependencyObject container, Patient patient)
    {
        var initialsText = FindChild<TextBlock>(container, "InitialsText");
        var sessionCountText = FindChild<TextBlock>(container, "SessionCountText");
        var lastSessionText = FindChild<TextBlock>(container, "LastSessionText");
        var statusBadge = FindChild<Border>(container, "StatusBadge");
        var statusText = FindChild<TextBlock>(container, "StatusText");

        if (initialsText != null)
            initialsText.Text = PatientFormatting.GetInitials(patient);
        if (sessionCountText != null)
            sessionCountText.Text = PatientFormatting.FormatSessionCount(patient);
        if (lastSessionText != null)
        {
            var last = PatientFormatting.FormatLastSession(patient);
            lastSessionText.Text = patient.SessionCount > 0 ? $"· Last: {last}" : "";
        }
        if (statusBadge != null && statusText != null)
        {
            statusText.Text = PatientFormatting.FormatStatusBadge(patient);
            statusBadge.Background = new SolidColorBrush(ColorFromHex(PatientFormatting.GetStatusColor(patient)));
            statusText.Foreground = new SolidColorBrush(ColorFromHex(PatientFormatting.GetStatusForeground(patient)));
        }
    }

    private static T? FindChild<T>(DependencyObject parent, string name) where T : FrameworkElement
    {
        var count = VisualTreeHelper.GetChildrenCount(parent);
        for (int i = 0; i < count; i++)
        {
            var child = VisualTreeHelper.GetChild(parent, i);
            if (child is T element && element.Name == name) return element;
            var found = FindChild<T>(child, name);
            if (found != null) return found;
        }
        return null;
    }

    private static Windows.UI.Color ColorFromHex(string hex)
    {
        hex = hex.TrimStart('#');
        return Windows.UI.Color.FromArgb(
            0xFF,
            Convert.ToByte(hex[..2], 16),
            Convert.ToByte(hex[2..4], 16),
            Convert.ToByte(hex[4..6], 16));
    }

    private void SearchBox_TextChanged(AutoSuggestBox sender, AutoSuggestBoxTextChangedEventArgs args)
    {
        if (args.Reason == AutoSuggestionBoxTextChangeReason.UserInput)
        {
            _viewModel.SearchText = sender.Text;
        }
    }
}
