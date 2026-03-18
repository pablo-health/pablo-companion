using Microsoft.Extensions.DependencyInjection;
using Microsoft.UI.Xaml.Controls;
using PabloCompanion.Services;
using uniffi.pablo_core;

namespace PabloCompanion.Views;

public sealed partial class QuickStartDialog : ContentDialog
{
    private readonly APIClient _apiClient;
    private Patient[] _patients = [];

    public string? SelectedPatientId { get; private set; }

    public QuickStartDialog()
    {
        InitializeComponent();
        _apiClient = App.Services.GetRequiredService<APIClient>();
    }

    private async void PatientSearch_TextChanged(AutoSuggestBox sender, AutoSuggestBoxTextChangedEventArgs args)
    {
        if (args.Reason != AutoSuggestionBoxTextChangeReason.UserInput) return;

        SearchProgress.IsActive = true;

        try
        {
            var search = string.IsNullOrWhiteSpace(sender.Text) ? null : sender.Text;
            var response = await _apiClient.FetchPatientsAsync(search, 1, 10);
            _patients = response.Data;
            sender.ItemsSource = _patients.Select(p => $"{p.FirstName} {p.LastName}").ToList();
        }
        catch
        {
            sender.ItemsSource = new List<string> { "Error loading patients" };
        }
        finally
        {
            SearchProgress.IsActive = false;
        }
    }

    private void PatientSearch_SuggestionChosen(AutoSuggestBox sender, AutoSuggestBoxSuggestionChosenEventArgs args)
    {
        var selected = args.SelectedItem?.ToString();
        if (selected == null) return;

        var patient = _patients.FirstOrDefault(p => $"{p.FirstName} {p.LastName}" == selected);
        if (patient != null)
        {
            SelectedPatientId = patient.Id;
            IsPrimaryButtonEnabled = true;
        }
    }
}
